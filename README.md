# WarPath

QQT plugin that drives in-zone navigation for D4 automation, fed by
crowd-sourced map data from the [WarMap server](https://github.com/magoogle/warmap-server).

> **Renamed from StaticPather.**  The plugin still exports
> `StaticPatherPlugin` as a backward-compat alias so existing consumers
> (WarMachine activities, etc.) keep working through the transition.
> New code should reference `WarPathPlugin`.

## What it does

- Loads merged zone data (walkable cells + actor catalog) from the
  WarMap server's `/zones/<key>` endpoint.
- Bulk-pulls every available zone once per Lua `/reload` into
  `cache/`, with `If-Modified-Since` on subsequent reloads (only
  changed zones get re-pulled).  No more per-zone polling during play.
- Exposes a clean API for sister plugins:
  - `WarPathPlugin.find_path(start, goal)` — A* via the host pathfinder.
  - `WarPathPlugin.get_actors(kind?)` — every actor the merger has
    aggregated for the current zone.
  - `WarPathPlugin.nearest_actor(kind, pos, skin?)` — closest match.
  - `WarPathPlugin.plan_to_kind(kind)` / `plan_to_skin(skin)` — cross-zone
    travel planning (teleport-to-town legs + waypoint graph).
  - `WarPathPlugin.bulk_fetch()` — manual refresh trigger.
- Falls through to Batmobile when a zone has no merged data.

## How it connects

```
WarMap recorder dumps  --merger-->   data/zones/<key>.json   --WarPath-->   consumer plugins
                                                                 (WarMachine activities)
                                                                                  |
                                                                       falls through to Batmobile
                                                                       when WarPath has no data
```

## Repo layout

```
core/
  pather.lua         -- main API surface; A* + actor lookups
  loader.lua         -- zone-cache management, bulk fetcher spawn
  travel.lua         -- cross-zone travel planning
  world_graph.lua    -- waypoint adjacency
  host_pather.lua    -- bridge to host's world:calculate_path
  visualizer.lua     -- in-game line drawing for debug
  json_parser.lua    -- pure-Lua JSON parser
  settings.lua
bin/
  fetch_zone.py      -- per-zone fetcher (cache-miss fallback)
  fetch_all.py       -- bulk fetcher (Lua reload)
gui.lua
main.lua             -- plugin global + on_update wiring
```

## v0.2 changes (this initial release as WarPath)

* Bulk zone fetch on Lua reload via `bin/fetch_all.py`.  Replaces the
  per-cache-miss + per-30-min-per-zone fetcher that was popping a
  Python window every couple minutes during play.
* Per-zone fetch is a fallback only -- spawned only when a zone's
  cache file is missing entirely.
* Fetcher uses `pythonw.exe` (Windows GUI subsystem) so no CMD flash.
* `WarPathPlugin.bulk_fetch()` exposed for manual refresh from a GUI
  button or sister plugin.

## Install

The user's QQT scripts folder gets a `WarPath/` directory containing
this repo's checkout (minus `cache/`, which is created at runtime).
The installer pattern lives in
[`magoogle/warmap-recorder`](https://github.com/magoogle/warmap-recorder)'s
player-bundle build script -- WarPath will get folded into the bundle
in a follow-up.

## Auth

WarPath's fetcher reuses the WarMap uploader's API key
(`%LOCALAPPDATA%\WarMap\uploader\.env` → `WARMAP_API_KEY`) so a single
key gates both upload and read.  Keys are minted server-side via the
viewer's admin panel; reader-tier keys work fine for WarPath since it
only reads.
