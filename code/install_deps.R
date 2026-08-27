# One-time dependency installer for this workflow. Run once at deployment:
#   Rscript code/install_deps.R
#
# Checks every package the workflow needs, installs whatever is missing
# from CRAN, and reports a readiness summary. Safe to re-run (already-
# installed packages are skipped).

# progress goes to stdout via say(), not message()/stderr, so the cron job's
# .err log collects only real problems (warnings and errors). say() matches
# message() semantics: arguments pasted with no separator, newline appended.
say <- function(...) cat(..., "\n", sep = "")

workflow_deps <- list(
  "HADS hourly (code/get_hads_obs.R / code/append_hads_master.R)" =
    c("httr2", "dplyr", "tibble", "readr")
)

needed    <- sort(unique(unlist(workflow_deps)))
installed <- rownames(installed.packages())
missing   <- setdiff(needed, installed)

if (length(missing) == 0) {
  say("All ", length(needed), " required packages already installed: ",
      paste(needed, collapse = ", "))
} else {
  say("Installing ", length(missing), " missing package(s): ",
      paste(missing, collapse = ", "))
  install.packages(missing, repos = "https://cloud.r-project.org")
}

# --- readiness report ------------------------------------------------------
installed <- rownames(installed.packages())   # refresh after install
say("\nWorkflow readiness:")
ok_all <- TRUE
for (wf in names(workflow_deps)) {
  still_missing <- setdiff(workflow_deps[[wf]], installed)
  if (length(still_missing) == 0) {
    say("  [OK]      ", wf)
  } else {
    ok_all <- FALSE
    say("  [MISSING] ", wf, " — needs: ",
        paste(still_missing, collapse = ", "))
  }
}
if (!ok_all) stop("Some packages failed to install — see above.")
say("\nWorkflow ready. R ", R.version$major, ".", R.version$minor,
    " at ", R.home())
