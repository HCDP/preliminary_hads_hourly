# Cache-aware, sourceable station catalog for the HADS DCP network —
# same interface as get_rr5_stations() / get_station_catalog() in the
# companion workflows. Returns a data frame:
#   station_id | nesdis_id | name | latitude | longitude | owner | state |
#   hsa | xmit_slot | xmit_interval_min | variables |
#   latest_obs_api | latest_obs_data
#
#   latest_obs_api  — newest observation time HADS is currently serving for
#                     the station (NA = it reported nothing in the probe
#                     window)
#   latest_obs_data — newest datetime with a non-NA value per station in
#                     YOUR collected long data (from obs_file; NA = none)
# Both are HST text ("YYYY-MM-DD HH:MM:SS HST"), matching the companion
# catalogs — note the OBSERVATION files themselves are UTC (see README).
#
# This file also carries the two low-level helpers the fetcher reuses, so
# get_hads_obs.R needs exactly one local file besides itself:
#   hads_download(hours, state, ua)  — pull a rolling window to a temp file
#   hads_read(path)                  — parse the pipe-delimited page
#
# As a library:
#   source("code/get_hads_stations_fn.R")
#   stns <- get_hads_stations()                 # read cache, or build if absent
#   stns <- get_hads_stations(refresh = TRUE)   # rebuild + overwrite
#
# Arguments:
#   state       state code for the HADS query (default "HI")
#   latest      add the two latest_obs columns when building (default TRUE)
#   obs_file    long-format HADS data file for latest_obs_data (default
#               data_out/hads_obs_long.csv at the PROJECT ROOT, i.e. the
#               parent of code/ — not the working directory; point at
#               data_out/hads_master.csv for the full record)
#   dir         directory holding the CSV (default: dataCatalog/ at the
#               project root — NOT the working directory — created if
#               missing; file is <state>_hads_stations.csv inside it)
#   write_csv   when building, save the catalog there (default TRUE)
#   refresh     TRUE = ignore any existing CSV, rebuild and overwrite
#               (default FALSE: an existing CSV is read and returned as-is,
#               no network calls)
#   probe_hours window fetched from HADS to derive latest_obs_api
#               (default 12 h, ~1.3 MB). Ignored when probe_obs is given.
#   probe_obs   already-fetched observations to derive latest_obs_api from
#               instead of probing (data frame with station_id + datetime
#               as POSIXct UTC). The fetcher passes the data it just
#               pulled, so the end-of-run refresh costs no extra request.
#
# As a script (always refreshes):
#   Rscript code/get_hads_stations_fn.R [state]   (default HI)
#   -> dataCatalog/<state>_hads_stations.csv (at the project root)

suppressPackageStartupMessages(library(httr2))
suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(tibble))
suppressPackageStartupMessages(library(readr))

# progress goes to stdout via say(), not message()/stderr, so the cron job's
# .err log collects only real problems (warnings and errors). say() matches
# message() semantics: arguments pasted with no separator, newline appended.
say <- function(...) cat(..., "\n", sep = "")

# directory this code file lives in (sourced -> the sourced file's dir;
# run via Rscript -> the script's dir; fallback -> working directory).
# The code lives in code/, so the project root -- holding data_out/ and
# dataCatalog/ -- is its parent.
.code_dir <- local({
  of <- NULL
  for (i in seq_len(sys.nframe())) {
    e <- sys.frame(i)
    if (!is.null(e$ofile)) of <- e$ofile
  }
  if (!is.null(of)) return(dirname(normalizePath(of, winslash = "/")))
  fa <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(fa)) return(dirname(normalizePath(sub("^--file=", "", fa[1]),
                                               winslash = "/")))
  getwd()
})
.data_dir <- dirname(.code_dir)   # project root (parent of code/)

.hads_ua   <- "R script (hcdp@hawaii.edu)"
.defs_url  <- "https://hads.ncep.noaa.gov/compressed_defs/all_dcp_defs.txt"
.data_url  <- "https://hads.ncep.noaa.gov/nexhads2/servlet/DecodedData"

# catalog timestamps are HST text; the observation files are UTC (README)
.parse_hst <- function(x) as.POSIXct(sub(" HST$", "", x),
                                     tz = "Pacific/Honolulu")
.fmt_hst   <- function(t) format(t, "%Y-%m-%d %H:%M:%S HST",
                                 tz = "Pacific/Honolulu")

# --- low-level HADS access -------------------------------------------------

# Pull a rolling window of decoded DCP data to a temp file and return its
# path. The servlet's `sinceday` parameter is overloaded: POSITIVE values
# mean whole calendar days back to 00Z, NEGATIVE values mean HOURS back
# from now. We always use the negative (rolling-hours) form, which is what
# makes an incremental hourly pull possible at all. of=1 selects the
# pipe-delimited output the legacy scraper also used.
hads_download <- function(hours, state = "HI", ua = .hads_ua) {
  stopifnot(hours > 0)
  tmp <- tempfile(fileext = ".txt")
  request(.data_url) |>
    req_url_query(sinceday = -round(hours), hsa = "nil", state = toupper(state),
                  nesdis_ids = "nil", of = 1) |>
    req_headers(`User-Agent` = ua) |>
    req_timeout(600) |>
    req_retry(max_tries = 3) |>
    req_perform(path = tmp)
  tmp
}

# Parse the pipe-delimited page:
#   nesdis_id|nwsli|var|obs_time|value|mode|
# (a trailing empty 7th field comes from the line-ending delimiter).
# obs_time is UTC, "YYYY-MM-DD HH:MM"; value may be blank; var is a SHEF
# physical-element code with an optional one-character sensor suffix
# (e.g. "PC", "PC2", "VJA"); mode is the transmission flag (blank =
# routine/self-timed, "R" = random/alert, "P"/"Q" also occur).
hads_read <- function(path) {
  head_lines <- readLines(path, n = 5, warn = FALSE)
  head_lines <- head_lines[nzchar(head_lines)]
  if (!length(head_lines))
    stop("HADS returned an empty page (", path, ")")
  # A server error page or a maintenance notice parses into convincing
  # garbage otherwise -- the legacy scraper had no such check.
  ok <- grepl("^[^|]+\\|[^|]+\\|[^|]+\\|\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}\\|",
              head_lines)
  if (!any(ok))
    stop("HADS did not return pipe-delimited data. First line was:\n  ",
         substr(head_lines[1], 1, 200))

  raw <- read_delim(
    path, delim = "|", col_names = c("nesdis_id", "station_id", "variable",
                                     "obs_time", "value", "mode", "x7"),
    col_types = cols(.default = col_character()),
    # quote = "" disables quote handling: the feed is raw pipe-delimited
    # text and a stray double quote in a value would otherwise swallow
    # every line up to the next one
    trim_ws = TRUE, quote = "", progress = FALSE, na = character())

  n_bad <- sum(is.na(raw$obs_time) | !nzchar(raw$obs_time))
  if (n_bad) warning(n_bad, " unparseable line(s) dropped from the HADS page",
                     call. = FALSE, immediate. = TRUE)

  raw |>
    filter(nzchar(obs_time)) |>
    transmute(
      station_id,
      # HADS serves UTC; seconds are always :00 and are not transmitted
      datetime = as.POSIXct(obs_time, format = "%Y-%m-%d %H:%M", tz = "UTC"),
      variable,
      value    = suppressWarnings(as.numeric(value)),
      nesdis_id,
      mode     = ifelse(is.na(mode), "", mode))
}

# --- station catalog -------------------------------------------------------

# "21 54 46" / "-159 29 35" -> decimal degrees (seconds may be fractional)
.dms_to_dd <- function(x) {
  vapply(strsplit(trimws(x), "[[:space:]]+"), function(v) {
    v <- suppressWarnings(as.numeric(v))
    if (!length(v) || is.na(v[1])) return(NA_real_)
    m <- if (length(v) > 1 && !is.na(v[2])) v[2] else 0
    s <- if (length(v) > 2 && !is.na(v[3])) v[3] else 0
    (if (v[1] < 0) -1 else 1) * (abs(v[1]) + m / 60 + s / 3600)
  }, numeric(1))
}

# Station definitions for one state, from the all-states DCP definition
# file. It is 23 MB of text but gzips to ~1.3 MB on the wire, so this is a
# sub-second download; there is no per-state version published.
.hads_defs <- function(state, ua) {
  tmp <- tempfile(fileext = ".txt")
  request(.defs_url) |>
    req_headers(`User-Agent` = ua) |>
    req_timeout(300) |>
    req_retry(max_tries = 3) |>
    req_perform(path = tmp)
  lines <- readLines(tmp, warn = FALSE)
  unlink(tmp)

  # fields: nesdis|nwsli|owner|state|hsa|lat|lon|slot|interval|name|S|<PE blocks>
  keep <- grepl(sprintf("^([^|]*\\|){3} *%s\\|", toupper(state)), lines)
  if (!any(keep))
    stop("No stations for state ", state, " in ", .defs_url)
  f <- strsplit(lines[keep], "|", fixed = TRUE)

  fld <- function(i) trimws(vapply(f, function(v)
    if (length(v) >= i) v[i] else NA_character_, character(1)))
  # each PE block is 5 fields (PE|interval|offset|coefficient|constant)
  # starting at field 12, right after the "S" marker at field 11
  pe_of <- function(v) {
    idx <- seq(12, length(v), by = 5)
    pe  <- trimws(v[idx])
    paste(unique(pe[nzchar(pe)]), collapse = ",")
  }

  tibble(
    station_id        = fld(2),
    nesdis_id         = fld(1),
    name              = fld(10),
    latitude          = .dms_to_dd(fld(6)),
    longitude         = .dms_to_dd(fld(7)),
    owner             = fld(3),
    state             = fld(4),
    hsa               = fld(5),
    xmit_slot         = fld(8),
    xmit_interval_min = suppressWarnings(as.integer(fld(9))),
    variables         = vapply(f, pe_of, character(1))
  ) |>
    filter(nzchar(station_id)) |>
    distinct(station_id, .keep_all = TRUE)
}

get_hads_stations <- function(state = "HI", latest = TRUE,
                              obs_file = file.path(.data_dir, "data_out",
                                                   "hads_obs_long.csv"),
                              dir = file.path(.data_dir, "dataCatalog"),
                              write_csv = TRUE, refresh = FALSE,
                              probe_hours = 12, probe_obs = NULL,
                              ua = .hads_ua) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  csv_path <- file.path(dir, sprintf("%s_hads_stations.csv", tolower(state)))

  # --- cached copy? -------------------------------------------------------
  if (!refresh && file.exists(csv_path)) {
    say("Reading existing HADS station catalog: ", csv_path,
        " (last modified ", format(file.mtime(csv_path)), ")")
    return(read.csv(csv_path, colClasses = c(station_id = "character",
                                             nesdis_id  = "character",
                                             xmit_slot  = "character")))
  }

  # --- station definitions -------------------------------------------------
  say("Fetching HADS DCP definitions for ", toupper(state), "...")
  catalog <- .hads_defs(state, ua)
  say(nrow(catalog), " ", toupper(state), " stations defined")

  if (latest) {
    # --- latest_obs_api: newest observation HADS is serving right now -----
    if (is.null(probe_obs)) {
      say("Probing the newest ", probe_hours, " h of HADS data...")
      p <- hads_download(probe_hours, state, ua)
      probe_obs <- hads_read(p)
      unlink(p)
    } else {
      say("Deriving latest_obs_api from the observations just fetched")
    }
    api_tbl <- probe_obs |>
      filter(!is.na(value), !is.na(datetime)) |>
      group_by(station_id) |>
      summarise(latest_obs_api = .fmt_hst(max(datetime)), .groups = "drop")

    # A station can transmit without being in the definition file (and the
    # reverse). Keep the union so the catalog never silently loses a
    # reporting gauge; definition columns stay NA for the newcomers.
    extra <- setdiff(api_tbl$station_id, catalog$station_id)
    if (length(extra)) {
      say(length(extra), " reporting station(s) absent from the definition ",
          "file, added with NA metadata: ", paste(extra, collapse = ", "))
      catalog <- bind_rows(catalog, tibble(station_id = extra))
    }
    catalog <- left_join(catalog, api_tbl, by = "station_id")
    say(sum(!is.na(catalog$latest_obs_api)), " of ", nrow(catalog),
        " stations reported in the probe window")

    # --- latest_obs_data: newest non-NA value in collected long data ------
    if (file.exists(obs_file)) {
      say("Deriving latest_obs_data from ", obs_file)
      obs <- read_csv(obs_file, col_types = cols_only(
        station_id = col_character(), datetime = col_character(),
        value = col_double()), progress = FALSE)
      data_tbl <- obs |>
        filter(!is.na(value)) |>
        mutate(ts = as.POSIXct(datetime, tz = "UTC")) |>
        group_by(station_id) |>
        summarise(latest_obs_data = .fmt_hst(max(ts, na.rm = TRUE)),
                  .groups = "drop")
      catalog <- left_join(catalog, data_tbl, by = "station_id")
      say(sum(!is.na(catalog$latest_obs_data)), " of ", nrow(catalog),
          " stations have data in ", obs_file)
    } else {
      warning("obs file not found (", obs_file,
              ") — latest_obs_data set to NA", call. = FALSE, immediate. = TRUE)
      catalog$latest_obs_data <- NA_character_
    }
  }

  catalog <- arrange(catalog, station_id)

  # --- save ---------------------------------------------------------------
  if (write_csv) {
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    write.csv(catalog, csv_path, row.names = FALSE)
    say("Written to ", csv_path)
  }

  catalog
}

# --- run as a script -------------------------------------------------------
if (sys.nframe() == 0) {
  args  <- commandArgs(trailingOnly = TRUE)
  state <- if (length(args) >= 1) toupper(args[1]) else "HI"
  invisible(get_hads_stations(state, latest = TRUE, refresh = TRUE))
}
