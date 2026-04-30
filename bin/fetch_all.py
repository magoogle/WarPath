"""WarPath bulk-zone fetcher.

Spawned once per Lua module load by core/loader.lua to download every
zone the server knows about into <plugin>/cache/.  Subsequent loads
re-run this and refresh only the zones whose Last-Modified is newer
than the local cache (via If-Modified-Since).

This replaces the old "fetch on every cache miss + refresh every 30
minutes per zone" strategy.  At normal play cadence (multiple zones
per minute) the old strategy was spawning Python processes
constantly; this one is one bulk spawn per /reload.

Stdlib only -- no requests dependency.

Exit codes:
  0   ok (some + skipped + failed = total; all attempted)
  1   fatal (no API key, network unreachable, list call failed)

Usage:
    pythonw fetch_all.py --server https://d4data.live --cache-dir /path/to/cache

API key auto-discovery (in priority order):
  1. --api-key <hex>
  2. $WARMAP_API_KEY
  3. %LOCALAPPDATA%/WarMap/uploader/.env
  4. ~/.local/share/warmap/uploader/.env  (unix)
"""

import argparse
import email.utils
import json
import os
import pathlib
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


def load_api_key(explicit):
    """Mirror fetch_zone.py's discovery so the bulk fetcher works on
    any install where the per-zone fetcher works."""
    if explicit:
        return explicit.strip() or None
    env_var = os.environ.get('WARMAP_API_KEY')
    if env_var and env_var.strip():
        return env_var.strip()
    candidates = []
    if os.name == 'nt':
        local = os.environ.get('LOCALAPPDATA')
        if local:
            candidates.append(pathlib.Path(local) / 'WarMap' / 'uploader' / '.env')
    else:
        candidates.append(pathlib.Path.home() / '.local' / 'share' / 'warmap' / 'uploader' / '.env')
    for c in candidates:
        try:
            if c.exists():
                for raw in c.read_text(encoding='utf-8').splitlines():
                    line = raw.strip()
                    if line.startswith('WARMAP_API_KEY='):
                        return line.split('=', 1)[1].strip().strip('"').strip("'") or None
        except OSError:
            continue
    return None


def fetch_zone(server, key, cache_dir, headers, max_bytes, timeout):
    """Pull one zone with If-Modified-Since.  Returns 'updated', 'unchanged',
    or 'failed'."""
    url = '{}/zones/{}'.format(server.rstrip('/'),
                               urllib.parse.quote(key, safe=''))
    cache_path = cache_dir / f'{key}.json'
    h = dict(headers)
    if cache_path.exists():
        try:
            ims = email.utils.formatdate(cache_path.stat().st_mtime, usegmt=True)
            h['If-Modified-Since'] = ims
        except OSError:
            pass
    req = urllib.request.Request(url, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read(max_bytes + 1)
            if len(data) > max_bytes:
                return 'failed'
            fd, tmp = tempfile.mkstemp(suffix='.tmp', dir=str(cache_dir))
            try:
                with os.fdopen(fd, 'wb') as f:
                    f.write(data)
                os.replace(tmp, str(cache_path))
            except Exception:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                return 'failed'
            # Stamp cache mtime to server's Last-Modified so future
            # If-Modified-Since requests reliably hit 304.
            lm = resp.headers.get('Last-Modified')
            if lm:
                try:
                    ts = email.utils.parsedate_to_datetime(lm).timestamp()
                    os.utime(cache_path, (ts, ts))
                except Exception:
                    pass
            return 'updated'
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return 'unchanged'
        return 'failed'
    except (urllib.error.URLError, OSError):
        return 'failed'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--server',     required=True,
                    help='base URL of the WarMap server')
    ap.add_argument('--cache-dir',  required=True,
                    help='dir to write <key>.json files into')
    ap.add_argument('--api-key',    default=None)
    ap.add_argument('--max-bytes',  type=int,   default=8 * 1024 * 1024)
    ap.add_argument('--timeout',    type=float, default=30.0)
    ap.add_argument('--list-only',  action='store_true',
                    help='just print what would be fetched; no writes')
    args = ap.parse_args()

    api_key = load_api_key(args.api_key)
    if not api_key:
        print('fetch_all: no API key found '
              '(set WARMAP_API_KEY or pass --api-key)', file=sys.stderr)
        sys.exit(1)

    cache_dir = pathlib.Path(args.cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)

    headers = {
        'User-Agent':    'WarPath/fetch_all',
        'X-WarMap-Key':  api_key,
    }

    # 1. Get the zone list
    list_url = args.server.rstrip('/') + '/zones'
    list_req = urllib.request.Request(list_url, headers=headers)
    try:
        with urllib.request.urlopen(list_req, timeout=args.timeout) as r:
            payload = json.loads(r.read())
            zones = payload.get('zones') or []
    except (urllib.error.URLError, urllib.error.HTTPError) as e:
        print(f'fetch_all: list call failed: {e}', file=sys.stderr)
        sys.exit(1)

    if not zones:
        print('fetch_all: server has no zones yet')
        sys.exit(0)

    if args.list_only:
        for k in zones:
            print(k)
        sys.exit(0)

    # 2. Fetch each
    t0 = time.time()
    updated = unchanged = failed = 0
    for key in zones:
        result = fetch_zone(args.server, key, cache_dir,
                            headers, args.max_bytes, args.timeout)
        if   result == 'updated':   updated   += 1
        elif result == 'unchanged': unchanged += 1
        else:                       failed    += 1

    elapsed = time.time() - t0
    print(f'fetch_all: {updated} updated, {unchanged} unchanged, '
          f'{failed} failed in {elapsed:.1f}s')


if __name__ == '__main__':
    main()
