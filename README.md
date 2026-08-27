# HADS hourly workflow

Hourly, catalog-driven collection of decoded GOES DCP observations for the
**243 Hawaii platforms** in NOAA's Hydrometeorological Automated Data System
(HADS) — county hydronet and stream gauges, RAWS, USGS, reservoir and tide
sensors, water-quality sondes. Roughly **221 report in any given day**,
across **36 SHEF variables** (river stage, precipitation accumulators, air
and water temperature, wind, humidity, solar radiation, battery voltage…) at
5- to 15-minute resolution. Each run fetches only the hours that are missing
and folds them into a permanent, deduplicated master table.

This replaces `hads_24hr_webscape.R` (in `HCDP/Data_Acquisition_HADS`), which
re-scraped a fixed 48-hour window once a day, suppressed all warnings, kept
no permanent record, and had no error handling. It writes to its own
`data_out/` and does not touch the legacy `data_aqs/data_outputs/hads/`
directories, so the old cron can keep running until you retire it.

## How it works

The pipeline is driven by a **station catalog**
(`dataCatalog/hi_hads_stations.csv`) built from NOAA's DCP definition file,
carrying each platform's location, owner, GOES transmission slot, declared
variables, and two freshness timestamps:

| Column | Meaning |
|---|---|
| `latest_obs_api` | newest observation HADS is currently serving for the station (NA = it reported nothing in the window) |
| `latest_obs_data` | newest non-NA value per station already collected into our data |

Each run:

1. **Load the catalog** — `get_hads_stations()` (from
   `code/get_hads_stations_fn.R`, sourced) reads the cached catalog, or
   builds and writes it on the first run. The `dataCatalog/` folder is
   created at the project root automatically.
2. **Size the fetch window** — one HADS request returns *every* station in
   the state, so the incremental unit is a single window of hours rather
   than per-station windows: the script fetches from the **newest**
   `latest_obs_data` across stations to now, with a 12-hour minimum and
   HADS's ~7-day retention as the cap. No collected data at all (first run)
   fetches the full 7 days. A manual override is available
   (`Rscript code/get_hads_obs.R 24` = newest 24 hours).
3. **Fetch and parse** — the pipe-delimited page
   (`nesdis_id|nwsli|var|obs_time|value|mode|`) is parsed into long format.
   Blank values become `NA`. Where the same station/hour/variable arrives
   twice — once routinely and once as a random/alert transmission — the
   routine copy wins (see [Duplicate transmissions](#duplicate-transmissions)).
4. **Write the snapshot** — `data_out/hads_obs_long.csv`, long format:
   `station_id | datetime | variable | value | unit | nesdis_id | mode`
   (UTC datetimes).
5. **Refresh the catalog** — the run ends by rebuilding the catalog and
   re-deriving both freshness columns, so the next run knows exactly what is
   missing. `latest_obs_api` is derived from the data just fetched, so this
   costs no extra request to the HADS servlet.
6. **Append to the master** — `code/append_hads_master.R` folds the snapshot
   into `data_out/hads_master.csv`, deduplicating on
   `station_id + datetime + variable` (incoming rows win, so a value HADS
   decoded late or corrected replaces what the master had). The master is
   the permanent record and the only file that needs backing up.

Catch-up after downtime is automatic: the window stretches to match whatever
gap the catalog reveals, up to the ~7-day retention — so **runs must happen
at least weekly** to avoid gaps in the master.

### Why the window is sized off the *newest* timestamp

The companion RR5 workflow sizes its window off the **oldest**
`latest_obs_data` across gauges, deliberately over-fetching. This workflow
takes the **newest**, and the difference is not an oversight.

Because one request returns all stations, every hour we fetch is complete for
every station that transmitted in it — there is no per-station catch-up to
do, and the only quantity that matters is how far behind the *pipeline* is.
Sizing off the oldest would peg the window at the 7-day cap permanently the
first time any one of the 243 platforms goes offline, turning every hourly
run into an 18 MB download. Values that land late (a delayed or retransmitted
DCP message decoded after we already passed its hour) are covered instead by
the 12-hour minimum window plus the append step's dedupe.

## Files

All R code lives in `code/`; data directories sit beside it at the project
root, so the scripts run correctly from any working directory.

```
<project root>/          <- data_out/ and dataCatalog/ are created here
`-- code/                <- all four .R files and the PE lookup live here
```

Each script resolves its own location and takes the **parent** as the data
root, so this nesting matters: put the code at the project root instead and
the data directories would land one level above it.

| File | Role |
|---|---|
| `code/get_hads_stations_fn.R` | cache-aware catalog function + the shared HADS download/parse helpers (sourced; also runs standalone) |
| `code/get_hads_obs.R` | the fetcher — steps 1–5 above |
| `code/append_hads_master.R` | snapshot → master accumulator |
| `code/install_deps.R` | one-time CRAN dependency installer |
| `code/hads_pe_units.csv` | SHEF physical-element → unit lookup (260 codes) |
| `cron_hads.txt` | ready-to-install hourly crontab entry |
| `dataCatalog/hi_hads_stations.csv` | station catalog with freshness timestamps |
| `data_out/hads_obs_long.csv` | latest fetch window (overwritten each run) |
| `data_out/hads_master.csv` | permanent deduplicated record |
| `runlogs/` | cron stdout/stderr logs (gitignored) |

## Usage

```bash
Rscript code/get_hads_obs.R         # fetch (catalog-driven window)
Rscript code/append_hads_master.R   # fold into the master
```

Run both, in that order, on a schedule (hourly works well). Because the
scripts anchor their own paths, cron can call them by absolute path with no
`cd`. Chain them so a failed fetch does not re-fold a stale snapshot:

```bash
Rscript /path/to/code/get_hads_obs.R && \
  Rscript /path/to/code/append_hads_master.R
```

A steady-state hourly run is quick — a 12-hour window is ~1.2 MB and about
3 s to fetch, plus ~1.5 s to fold into the master. The first run, which
backfills the full 7 days, downloads ~17.5 MB and takes about 17 s for
roughly 400,000 rows.

### Scheduling

`cron_hads.txt` holds the ready-to-install crontab entry — copy its second
line into `crontab -e`:

```
20 * * * * /bin/sh -c '<abs>/code/get_hads_obs.R && <abs>/code/append_hads_master.R' \
             >> <abs>/runlogs/hads_hrly.out 2>> <abs>/runlogs/hads_hrly.err
```

**:20 past the hour.** Unlike the RR5 product there is no single issuance to
wait on — each DCP transmits in its own assigned GOES slot (the `xmit_slot`
column in the catalog, spread across the hour) and HADS decodes continuously
with a few minutes' lag. Any minute would collect a complete previous hour,
so the choice is really about staggering: the NWS API workflow runs at :07
and takes about 5 minutes, and the RR5 workflow runs at :45. **:20** sits
clear of both.

The `/bin/sh -c '...'` wrapper is required, not cosmetic: written bare, the
redirects would attach only to the second command and the fetcher's output
would go to cron's mail instead of the log.

Output lands in `runlogs/` (gitignored, created on demand):

| File | Holds |
|---|---|
| `runlogs/hads_hrly.out` | the full run transcript — every progress line |
| `runlogs/hads_hrly.err` | **only** warnings and errors; empty after a clean run |

That split is why the scripts report progress with `say()` (a thin `cat()`
wrapper) rather than `message()`, and wrap `library()` in
`suppressPackageStartupMessages()` — both of those write to stderr in R,
which would otherwise fill `.err` with routine chatter on every run. Note the
logs append, so they grow without bound; rotate or truncate them if that
matters.

### What a run needs locally

The fetcher needs exactly **one** other local file, plus an optional lookup.

| Needed | Why |
|---|---|
| `code/get_hads_stations_fn.R` | sourced by the fetcher; must sit in the same directory. Missing it is fatal at startup. |
| R ≥ 4.1 plus `httr2`, `dplyr`, `tibble`, `readr` | run `Rscript code/install_deps.R` once. |
| network access to `hads.ncep.noaa.gov` | no API key and no `User-Agent` requirement, though one is set anyway |

Everything else is optional, and is created or rebuilt automatically:

- `code/hads_pe_units.csv` — if absent, the run continues with `unit` set to
  `NA` and one warning. Nothing else depends on it.
- `dataCatalog/hi_hads_stations.csv` — built on first run. Having it just
  tells the run how far behind it is.
- `data_out/hads_obs_long.csv` — an output, not an input. It is read only at
  the end of a run, to derive `latest_obs_data`; if absent you get a warning
  and `NA` timestamps, nothing worse.
- `data_out/` and `dataCatalog/` — created on demand.

So a minimal deployment is **two `.R` files plus the packages**
(`get_hads_obs.R` and `get_hads_stations_fn.R`); add the PE lookup for units,
and the other two files for the master accumulator and dependency installer.

### Catalog staleness

Like the RR5 workflow and unlike the NWS API one, a stale catalog cannot
wedge this pipeline, so no age check is needed. The catalog only *sizes* the
fetch window: an out-of-date `latest_obs_data` makes the window longer, and
it is clamped to the ~7-day retention either way. Station coverage does not
depend on it — every request carries all Hawaii platforms and every line is
parsed regardless of what the catalog contains, so a platform added to HADS
shows up in the data on its first run and in the catalog at the end of that
same run. A missing catalog is simply rebuilt.

A station that transmits without appearing in the DCP definition file (or the
reverse) is kept either way: the catalog is the union of both, with `NA`
metadata for a platform HADS is serving but has not yet defined.

## Data notes

- Data comes from the HADS `DecodedData` servlet, the same source the legacy
  scraper used:
  `https://hads.ncep.noaa.gov/nexhads2/servlet/DecodedData?sinceday=-12&hsa=nil&state=HI&nesdis_ids=nil&of=1`
- **`sinceday` is overloaded.** Positive values mean whole calendar days back
  to 00Z (`sinceday=2` is what the legacy scraper used). **Negative values
  mean hours back from now** — `sinceday=-12` is a rolling 12-hour window.
  This workflow always uses the negative form; it is what makes an
  incremental hourly pull possible at all.
- **Retention is ~8 days**, rolling. `sinceday=-192` and `sinceday=-240`
  return identical rows. The 7-day cap here stays safely inside that.
- Station metadata comes from `compressed_defs/all_dcp_defs.txt` — 23 MB of
  text for all states, but ~1.3 MB gzipped on the wire, so a sub-second
  download. There is no per-state version published. Latitude and longitude
  are published as degrees/minutes/seconds and converted to decimal degrees.
- **Datetimes in both output files are UTC text** (`YYYY-MM-DD HH:MM:SS`) —
  the timezone HADS itself reports in. Note the legacy scraper's *filenames*
  were HST-dated while the data inside them was UTC. This matches the RR5
  workflow; the NWS API workflow writes HST instead, so those two masters are
  not directly joinable on `datetime` without converting. Timestamps *inside
  the catalog* are HST text, matching both companion catalogs.
- `variable` is a SHEF physical-element code, occasionally with a
  one-character sensor suffix — `PC2` is a second precipitation gauge at the
  same site, still inches. `code/hads_pe_units.csv` is keyed on the
  two-character PE code; the fetcher warns if a code shows up that the lookup
  does not cover, so it self-reports when it needs extending.
- **Pressure units are station-dependent.** Most Hawaii platforms transmit
  `PA`/`PL` in millibars, a few in inches of mercury, and HADS does not say
  which. Those two codes therefore carry a blank `unit`. If you need them,
  pin the unit per station after checking the magnitude (values near 1010 are
  mb; values near 29.9 are in-Hg).
- **This is provisional, non-quality-controlled DCP data.** Values are passed
  through exactly as transmitted, including out-of-range sensor sentinels
  (`HG = -927.00`, `VB = -11799.00`, `TA = -59.60` all occur). Filter
  downstream.

### Duplicate transmissions

The `mode` column is HADS's transmission flag: blank for a routine
self-timed transmission, `R` for a random/alert transmission, with `P`, `Q`,
`RQ` and `RP` also occurring. About 225 station/hour/variable keys a day
arrive twice, once blank and once flagged.

The values usually agree to the last digit, but roughly 20 a day disagree —
and when they do, the flagged copy is the unreliable one. It is where the
sensor sentinels show up: at `WAAH1|HG|2026-08-26 08:15` the `R` copy read
`-927.00` while the blank copy read `1.03`, consistent with its neighbours.
So the fetcher sorts blank-mode rows first and keeps those. Keys that arrive
*only* as a flagged transmission are kept as-is, flag included, so nothing is
silently dropped.

### Master file growth

At ~61,000 rows a day the master grows about 2.8 MB/day — roughly 22 million
rows and 1 GB after a year, an order of magnitude faster than the RR5 master.
The append step reads, dedupes, and rewrites the whole file every hour, so
expect that step to slow from ~1.5 s today to a couple of minutes (and
several GB of RAM) by the end of the first year. If that becomes a problem
the cheapest fix is to partition the master by year — `hads_master_2026.csv`
— since the incoming window never spans more than 7 days.

See `HCDP/preliminary_nws_api_hourly` and `HCDP/preliminary_nws_rr5_hourly`
for the companion workflows this one is modelled on.
