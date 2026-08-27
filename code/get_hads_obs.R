# Catalog-driven incremental pull of decoded HADS DCP observations for all
# Hawaii stations, parsed into a long-format table:
#   station_id | datetime | variable | value | unit | nesdis_id | mode
#
# 'variable' is a SHEF physical-element code with an optional one-character
# sensor suffix (PC, PC2, HG, TA, ...); 'unit' comes from the shipped
# lookup code/hads_pe_units.csv. 'datetime' is UTC text
# ("2026-08-26 15:00:00"), the timezone HADS itself reports in.
#
# How it decides what to fetch (via the station catalog in dataCatalog/):
#   1. Loads the catalog with get_hads_stations() — reads
#      dataCatalog/hi_hads_stations.csv if present, otherwise builds and
#      writes it (first run).
#   2. One HADS request returns EVERY station, so the incremental unit is a
#      single window of hours, not per-station windows: it fetches from the
#      NEWEST latest_obs_data across stations to now, with a 12-hour
#      minimum and HADS's ~7-day retention as the cap. No latest_obs_data
#      at all (first run) -> the full 7 days.
#   3. After writing data_out/hads_obs_long.csv, refreshes the catalog
#      (refresh = TRUE) so the file reflects this fetch.
#
# Usage:
#   Rscript code/get_hads_obs.R        catalog-driven window (default)
#   Rscript code/get_hads_obs.R 168    manual override: newest 168 hours
#
# Output: data_out/hads_obs_long.csv, dataCatalog/hi_hads_stations.csv
#         (both are created at the project root -- the parent of code/ --
#         NOT in the working directory)
#
# Notes:
#  - Data comes from the HADS DecodedData servlet with a negative
#    `sinceday`, which the servlet reads as HOURS back from now (positive
#    values mean whole calendar days back to 00Z). See get_hads_stations_fn.R.
#  - Retention is ~8 days; asking for more returns the same rows. The cap
#    below is 7 days, so runs must happen at least weekly to avoid gaps.
#  - This is provisional, non-quality-controlled DCP data. Values are
#    passed through as transmitted, including out-of-range sensor
#    sentinels (e.g. HG = -927.00).

# code/ directory this script lives in (Rscript --file=...; falls back to
# the working directory if the script is sourced interactively). The
# project root -- where the data directories live -- is its parent. Source
# the catalog function from code/ so the pair stays linked no matter where
# the process was launched from.
codeDir <- local({
  fa <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(fa))
    dirname(normalizePath(sub("^--file=", "", fa[1]), winslash = "/"))
  else getwd()
})
mainDir <- dirname(codeDir)

# loads httr2/dplyr/tibble/readr, say(), hads_download(), hads_read()
# and get_hads_stations()
source(file.path(codeDir, "get_hads_stations_fn.R"))

# data lives at the project root, not in the working directory
out_dir  <- file.path(mainDir, "data_out")
obs_path <- file.path(out_dir, "hads_obs_long.csv")
pe_path  <- file.path(codeDir, "hads_pe_units.csv")

state <- "HI"

args       <- commandArgs(trailingOnly = TRUE)
n_override <- if (length(args) >= 1) suppressWarnings(as.numeric(args[1])) else NA
if (length(args) >= 1 && is.na(n_override))
  stop("Argument must be a number of hours, got: ", args[1])

min_fetch_h <- 12          # never fetch fewer hours than this
max_fetch_h <- 7 * 24      # HADS retention is ~8 days; stay inside it

end_time <- Sys.time()

# --- 1. Station catalog: read cache, or build + write on first run --------
# (lives in dataCatalog/ at the project root — the function's default)
#
# Unlike the companion NWS API workflow, a stale catalog cannot wedge this
# pipeline and so needs no age check: every station in the state comes back
# in every request and every line is parsed regardless of what the catalog
# holds, so the catalog only SIZES the window. See the README.
stns <- get_hads_stations(state)

# --- 2. How many hours to fetch -------------------------------------------
if (!is.na(n_override)) {
  fetch_h <- n_override
  say("Manual override: newest ", fetch_h, " hours")
} else {
  data_ts <- .parse_hst(stns$latest_obs_data)
  if (all(is.na(data_ts))) {
    say("No collected data yet — fetching the full ", max_fetch_h / 24,
        "-day retention")
    fetch_h <- max_fetch_h
  } else {
    # NEWEST, not oldest: because one request returns all stations, every
    # hour we fetch is complete for every station, so the quantity that
    # matters is how far behind the PIPELINE is -- not how long some dead
    # gauge has been silent. (The RR5 workflow takes the oldest because it
    # deliberately over-fetches; here that would peg the window at the
    # 7-day cap forever the first time a gauge goes offline.) Late and
    # retransmitted values that land after we already passed their hour are
    # covered by the 12-hour floor plus the append step's dedupe.
    lag_h   <- as.numeric(difftime(end_time, max(data_ts, na.rm = TRUE),
                                   units = "hours"))
    fetch_h <- ceiling(lag_h) + 1   # +1 so the boundary hour is included
    say(sprintf("Collected data is %.1f hrs behind -> fetching newest %.0f hours",
                lag_h, max(min_fetch_h, min(fetch_h, max_fetch_h))))
  }
}
fetch_h <- max(min_fetch_h, min(fetch_h, max_fetch_h))

# --- 3. Fetch and parse ----------------------------------------------------
say("Requesting ", fetch_h, " h of ", state, " HADS data...")
page <- hads_download(fetch_h, state)
say(sprintf("Downloaded %.1f MB", file.size(page) / 1024^2))
obs_long <- hads_read(page)
unlink(page)

if (nrow(obs_long) == 0) stop("No observations parsed.")

# --- 4. Finalize -----------------------------------------------------------
# Attach units from the shipped SHEF physical-element lookup, matching on
# the two-character PE code (the third character, when present, is a sensor
# suffix: PC2 is the second precipitation gauge, still inches).
if (file.exists(pe_path)) {
  pe_units <- read_csv(pe_path, col_types = cols(.default = col_character()),
                       progress = FALSE)
  obs_long <- obs_long |>
    mutate(pe = substr(variable, 1, 2)) |>
    left_join(select(pe_units, pe, unit), by = "pe")
  unknown <- sort(unique(obs_long$pe[!obs_long$pe %in% pe_units$pe]))
  if (length(unknown))
    warning("PE code(s) not in ", basename(pe_path), ", unit left blank: ",
            paste(unknown, collapse = ", "), call. = FALSE, immediate. = TRUE)
  obs_long$pe <- NULL
} else {
  warning("PE unit lookup not found (", pe_path, ") — unit set to NA",
          call. = FALSE, immediate. = TRUE)
  obs_long$unit <- NA_character_
}

# The same station/hour/variable can arrive twice: once routinely and once
# as a random/alert transmission ("R", sometimes "RQ"/"RP"/"P"). The values
# usually agree, but when they disagree the flagged copy is the unreliable
# one -- it is where the out-of-range sensor sentinels show up -- so sort
# blank-mode rows first and keep those.
obs_long <- obs_long |>
  arrange(station_id, datetime, variable, nzchar(mode), mode) |>
  distinct(station_id, datetime, variable, .keep_all = TRUE) |>
  arrange(station_id, datetime, variable) |>
  select(station_id, datetime, variable, value, unit, nesdis_id, mode)

sum_by_var <- obs_long |>
  group_by(variable) |>
  summarise(stations = n_distinct(station_id), rows = n()) |>
  arrange(desc(rows))
say(paste(capture.output(print(as.data.frame(head(sum_by_var, 12)))),
          collapse = "\n"))
say(sprintf(
  "TOTAL: %d rows, %d stations, %d variables, %s to %s UTC",
  nrow(obs_long), n_distinct(obs_long$station_id),
  n_distinct(obs_long$variable),
  format(min(obs_long$datetime), "%Y-%m-%d %H:%M"),
  format(max(obs_long$datetime), "%Y-%m-%d %H:%M")))

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
# format as text so midnight keeps its "00:00:00" -- write.csv on a POSIXct
# would drop it, and the bare date would not match the rest of the keys
write_csv(mutate(obs_long,
                 datetime = format(datetime, "%Y-%m-%d %H:%M:%S", tz = "UTC")),
          obs_path, na = "", progress = FALSE)
say("Written to ", obs_path)

# --- 5. Refresh the catalog so it reflects this fetch ----------------------
# probe_obs reuses what we just downloaded, so the refresh costs no extra
# request to HADS (only the definition file).
invisible(get_hads_stations(state, refresh = TRUE,
                            probe_obs = select(obs_long, station_id,
                                               datetime, value)))
