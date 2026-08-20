#!/usr/bin/env Rscript
# Fetch the two competition CSVs the audits read.
#
# The dataset is not committed -- the competition terms do not allow
# redistributing it -- so this is the first command after a clone.
#
#     Rscript scripts/fetch-kaggle-data.R
#
# Needs a Kaggle API token (~/.kaggle/kaggle.json, or KAGGLE_USERNAME and
# KAGGLE_KEY) belonging to an account that has accepted the competition rules.
# Already-downloaded files are left alone; pass --force to replace them.

suppressPackageStartupMessages(library(jsonlite))
invisible(lapply(list.files("R", full.names = TRUE, pattern = "[.]R$"), source))

args <- commandArgs(trailingOnly = TRUE)
fetch_kaggle_data(overwrite = "--force" %in% args)

message("\nNext: Rscript scripts/build-audit-frame.R")
