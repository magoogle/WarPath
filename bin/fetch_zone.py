"""StaticPather zone-data fetcher.

Pulls a single merged zone JSON from a WarMap server and writes it to the
plugin's local cache directory (`<plugin>/cache/<key>.json`).  Designed to
be spawned non-blocking from Lua via:

    os.execute('start "" /B cmd /c python fetch_zone.py ...')

so it never blocks the game thread.

Behavior:
  * Sends `If-Modified-Since: <local file mtime>` if the cache file already
    exists; the server returns 304 (no body) when it has nothing newer.
  * Sends `X-WarMap-Key` so the server's auth gate accepts the request.
    Key is discovered from (in order): --api-key flag, $WARMAP_API_KEY env
    var, the canonical uploader .env file at
    %LOCALAPPDATA%/WarMap/uploader/.env (Windows) or
    ~/.local/share/warmap/uploader/.env (unix).  Without a key the server
    returns 401, which this script reports as a network failure (exit 1).
  * On 200, writes atomically (tmp + os.replace) and stamps local mtime to
    match the server's `Last-Modified` so future IMS checks are correct.
  * On 304 / 404, leaves the cache file alone.

Exit codes:
  0  cache is up-to-date (200 fresh write or 304 not-modified)
  2  server has no data for this zone yet (404)
  1  network error / http 5xx / 401 unauthenticated / unexpected failure

Stdlib only -- StaticPather doesn't pull in `requests`.
"""

import argparse
import email.utils
import os
import pathlib
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request


def _load_api_key(explicit: str | None) -> str | None:
    """Find the WarMap API key.  Priority: --api-key flag, env var,
    canonical .env file.  Returns None if nothing found -- the request
    proceeds without auth, and the server will 401."""
    if explicit:
        return explicit.strip() or None
    env_var = os.environ.get('WARMAP_API_KEY')
    if env_var and env_var.strip():
        return env_var.strip()
    candidates: list[pathlib.Path] = []
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


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--server',     required=True,
                    help='base URL of the WarMap server, e.g. http://1.2.3.4:30100')
    ap.add_argument('--key',        required=True, help='zone key to fetch')
    ap.add_argument('--cache-dir',  required=True, help='dir to write <key>.json into')
    ap.add_argument('--max-bytes',  type=int,   default=8 * 1024 * 1024)
    ap.add_argument('--timeout',    type=float, default=10.0)
    ap.add_argument('--api-key',    default=None,
                    help='WarMap API key.  Falls back to $WARMAP_API_KEY then '
                         'the uploader .env file under %%LOCALAPPDATA%%/WarMap/uploader/.')
    args = ap.parse_args()

    cache_dir = pathlib.Path(args.cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / f'{args.key}.json'

    url = '{}/zones/{}'.format(
        args.server.rstrip('/'),
        urllib.parse.quote(args.key, safe=''))

    req = urllib.request.Request(url, headers={'User-Agent': 'StaticPather/1.0'})
    api_key = _load_api_key(args.api_key)
    if api_key:
        req.add_header('X-WarMap-Key', api_key)
    if cache_path.exists():
        ims = email.utils.formatdate(cache_path.stat().st_mtime, usegmt=True)
        req.add_header('If-Modified-Since', ims)

    try:
        with urllib.request.urlopen(req, timeout=args.timeout) as resp:
            # 200 OK -- read body (capped) and atomic-write to cache.
            data = resp.read(args.max_bytes + 1)
            if len(data) > args.max_bytes:
                print(f'response too large (>{args.max_bytes} bytes)', file=sys.stderr)
                sys.exit(1)
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
                raise
            # Stamp local mtime to server's Last-Modified so future IMS
            # checks hit 304 reliably.
            lm = resp.headers.get('Last-Modified')
            if lm:
                try:
                    ts = email.utils.parsedate_to_datetime(lm).timestamp()
                    os.utime(cache_path, (ts, ts))
                except Exception:
                    pass
            print(f'updated {cache_path} ({len(data)} bytes)')
            sys.exit(0)
    except urllib.error.HTTPError as e:
        if e.code == 304:
            print(f'not-modified {cache_path}')
            sys.exit(0)
        if e.code == 404:
            print(f'no-data {args.key}')
            sys.exit(2)
        if e.code == 401:
            # Auth gate rejected us.  Tell the user where to look so they
            # can fix the key wiring without digging through fetcher logs.
            print('http 401: unauthenticated -- set WARMAP_API_KEY env or '
                  'put it in %LOCALAPPDATA%/WarMap/uploader/.env',
                  file=sys.stderr)
            sys.exit(1)
        if e.code == 429:
            # Rate limited.  Backing off here is the caller's job (StaticPather
            # already throttles its fetch cadence).  Surface for visibility.
            print(f'http 429: rate-limited; backoff and retry', file=sys.stderr)
            sys.exit(1)
        print(f'http {e.code}: {e.reason}', file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f'network: {e.reason}', file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f'error: {e}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
