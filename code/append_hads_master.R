# Append the latest code/get_hads_obs.R output (hads_obs_long.csv) into a
# growing master table (hads_master.csv), deduplicated on
# station_id + datetime + variable.
#
# Usage:
#   Rscript code/append_hads_master.R                     defaults below
#     (defaults are data_out/ at the project root, not the working dir)
#   Rscript code/append_hads_master.R new.csv master.csv  explicit paths
#
# Intended flow (hourly scheduled task):
#   Rscript code/get_hads_obs.R        # writes hads_obs_long.csv
#   Rscript code/append_hads_master.R  # folds it into hads_master.csv
#
# On overlapping keys the INCOMING row wins, so a value that HADS decoded
# late, or corrected, replaces what the master already had.

suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(readr))   # much faster than read.csv at master-file scale (millions of rows)

# progress goes to stdout via say(), not message()/stderr, so the cron job's
# .err log collects only real problems (warnings and errors). say() matches
# message() semantics: arguments pasted with no separator, newline appended.
say <- function(...) cat(..., "\n", sep = "")

# code/ directory this script lives in; its parent is the project root, so
# the default data_out/ matches get_hads_obs.R and the pair works from any
# working directory
codeDir <- local({
  fa <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(fa))
    dirname(normalizePath(sub("^--file=", "", fa[1]), winslash = "/"))
  else getwd()
})
mainDir <- dirname(codeDir)
out_dir <- file.path(mainDir, "data_out")

args        <- commandArgs(trailingOnly = TRUE)
new_file    <- if (length(args) >= 1) args[1] else file.path(out_dir, "hads_obs_long.csv")
master_file <- if (length(args) >= 2) args[2] else file.path(out_dir, "hads_master.csv")

if (!file.exists(new_file)) stop("Input not found: ", new_file)

cols <- c("station_id", "datetime", "variable", "value", "unit",
          "nesdis_id", "mode")
col_spec <- cols_only(
  station_id = col_character(), datetime  = col_character(),
  variable   = col_character(), value     = col_double(),
  unit       = col_character(), nesdis_id = col_character(),
  mode       = col_character()
)

incoming <- read_csv(new_file, col_types = col_spec, progress = FALSE)
if (!all(cols %in% names(incoming))) {
  stop(new_file, " is missing expected columns: ",
       paste(setdiff(cols, names(incoming)), collapse = ", "))
}
incoming <- incoming[cols]

if (file.exists(master_file)) {
  master <- read_csv(master_file, col_types = col_spec, progress = FALSE)[cols]
  n_before <- nrow(master)
} else {
  master <- incoming[0, ]
  n_before <- 0
  dir.create(dirname(master_file), recursive = TRUE, showWarnings = FALSE)
  say("No existing master — creating ", master_file)
}

# incoming first so it wins on duplicate keys
combined <- bind_rows(incoming, master) |>
  distinct(station_id, datetime, variable, .keep_all = TRUE) |>
  arrange(station_id, datetime, variable)

write_csv(combined, master_file, na = "", progress = FALSE)

say(sprintf(
  "master: %d rows before, %d incoming, %d after (%+d); %s to %s UTC; %.1f MB",
  n_before, nrow(incoming), nrow(combined), nrow(combined) - n_before,
  min(combined$datetime), max(combined$datetime),
  file.size(master_file) / 1024^2))
