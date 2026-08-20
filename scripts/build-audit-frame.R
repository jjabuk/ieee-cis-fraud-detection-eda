#!/usr/bin/env Rscript
# Build the frame the audits read, from the two competition CSVs.
#
#     Rscript scripts/build-audit-frame.R
#
# Joins transaction to identity, counts the V-block nulls, fits the frequency
# maps on the training split and applies all thirty declared derivations. Writes
# the frame to data/audit_frame.parquet and the fitted maps to
# out/frequency-maps.json, where build-contract.qmd picks them up.
#
# What this frame does *not* carry: the entity aggregates. Those are BigQuery
# window functions under `RANGE ... 1 PRECEDING` and belong to the pipeline
# repository, which asserts their point-in-time correctness against the SQL it
# generates. To audit those too, export a frame there and point
# FRAUDAUDIT_PARQUET at it instead of running this.

suppressPackageStartupMessages({
  library(data.table)
  library(arrow)
  library(jsonlite)
})
invisible(lapply(list.files("R", full.names = TRUE, pattern = "[.]R$"), source))

frame <- build_audit_frame()
write_audit_frame(frame)

provenance <- attr(frame, "provenance")
message(
  "\n", format(provenance$rows, big.mark = ","), " rows x ",
  provenance$columns, " columns, ", provenance$derivations, " derivations applied"
)
message("Next: Rscript -e 'targets::tar_make()'")
