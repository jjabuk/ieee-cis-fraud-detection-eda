# Building the audit frame from the two competition CSVs.
#
# What the audits must see is the table *as the model receives it*, which means
# with the declared derivations already applied. Auditing the raw export instead
# would leave thirty derived columns unexamined, and eight of them were rejected
# the last time the whole set was measured.
#
# **What this builds and what it does not.** Everything here is row-local: the
# join, the V-block null count, and the three derivation tools. The pipeline's
# frame also carries ~40 *entity aggregates* -- a card's transaction count in the
# last hour, a client's mean amount over its prior rows -- computed by BigQuery
# window functions under `RANGE ... 1 PRECEDING`. Those are deliberately not
# reimplemented here. They are the pipeline's point-in-time guarantee, asserted
# by its own tests against the generated SQL, and a second implementation of a
# guarantee is a second thing that can be wrong about it.
#
# So there are two input modes and the contract records which one produced it:
#
#   * `standalone` -- this file, from the CSVs. No cloud, no Python. Audits every
#     column of the dataset and every row-local derivation, which is the whole
#     question this repository exists to answer.
#   * `pipeline` -- a parquet exported from the warehouse by the other
#     repository, which additionally carries the entity aggregates. The only way
#     to put a verdict on those.

#: Where a standalone build writes its frame, and where `_targets.R` looks first.
AUDIT_FRAME_PATH <- "data/audit_frame.parquet"

#: Where it writes the fitted frequency maps. `build-contract.qmd` reads them back
#: from here into the contract's `fitted_parameters` block, so the counts and the
#: verdicts fall under one fingerprint.
FREQUENCY_MAPS_FILE <- "out/frequency-maps.json"

#: The V block, whose missingness pattern is signal in its own right on this
#: dataset -- it is what defines the natural groups within the block.
V_COLUMNS <- paste0("V", 1:339)
NULL_COUNT_COLUMN <- "null_count_V_block"

#' Column classes for `fread`, read off the pinned BigQuery schema.
#'
#' The schema is the same file the pipeline's Terraform reads, so the two sides
#' agree on what a column *is* without either inferring it. Inference is what this
#' avoids: `fread` guessing from the first rows would make `addr1` a double in one
#' run and an integer in another, and a frequency map keyed on `"315"` does not
#' match one keyed on `"315.0"`.
schema_classes <- function(schema_path) {
  fields <- jsonlite::fromJSON(schema_path, simplifyVector = FALSE)
  types <- vapply(fields, function(f) f$type, character(1))
  names(types) <- vapply(fields, function(f) f$name, character(1))

  list(
    integer = names(types)[types == "INTEGER"],
    numeric = names(types)[types == "FLOAT"],
    character = names(types)[types %in% c("STRING", "BOOLEAN")]
  )
}

#' Read one competition CSV under its pinned schema.
#'
#' `BOOLEAN` columns arrive as `T`/`F` and are converted after the read rather
#' than during it: `fread`'s logical parser does not recognise those, and a
#' column silently read as character would compare unequal to the same column on
#' the pipeline side.
read_pinned_csv <- function(csv_path, schema_path) {
  classes <- schema_classes(schema_path)
  fields <- jsonlite::fromJSON(schema_path, simplifyVector = FALSE)
  booleans <- vapply(fields, function(f) f$name, character(1))[
    vapply(fields, function(f) f$type, character(1)) == "BOOLEAN"
  ]

  dt <- data.table::fread(
    csv_path,
    colClasses = classes,
    na.strings = c("", "NA", "NaN"),
    showProgress = FALSE
  )

  for (column in intersect(booleans, names(dt))) {
    data.table::set(dt, j = column, value = c("T" = TRUE, "F" = FALSE)[dt[[column]]])
  }
  dt
}

#' Join the two tables and add the V-block null count.
#'
#' `LEFT`, because identity is present for only a subset of transactions and rows
#' without a match must survive it. The null count is computed on the raw nulls,
#' before anything imputes them, because that pattern is a feature.
join_raw <- function(transaction, identity) {
  joined <- merge(transaction, identity, by = "TransactionID", all.x = TRUE, sort = FALSE)
  present <- intersect(V_COLUMNS, names(joined))
  if (!length(present)) {
    stop("no V columns in the joined frame; the schema or the CSV is wrong", call. = FALSE)
  }
  data.table::set(
    joined,
    j = NULL_COUNT_COLUMN,
    value = as.integer(rowSums(is.na(joined[, present, with = FALSE])))
  )
  data.table::setorderv(joined, "TransactionDT")
  joined[]
}

#' Build the audit frame from the two CSVs.
#'
#' The order is load-bearing. Frequency maps are fitted on the *joined* frame
#' before derivations are applied, because the split they are fitted on is cut on
#' the time axis and every derived column is a function of columns that already
#' exist. Fitting after would let a derived column feed its own encoding.
#'
#' @return A `data.table` with the fitted maps and provenance attached as
#'   attributes, for `write_audit_frame()` and the contract to carry.
build_audit_frame <- function(transaction_csv = "data/train_transaction.csv",
                              identity_csv = "data/train_identity.csv",
                              transaction_schema = "schemas/bq_schema_train_transaction.json",
                              identity_schema = "schemas/bq_schema_train_identity.json",
                              declared = DERIVATIONS) {
  for (path in c(transaction_csv, identity_csv, transaction_schema, identity_schema)) {
    if (!file.exists(path)) {
      stop(
        "missing ", path, ".\n",
        "  Fetch the data first: Rscript scripts/fetch-kaggle-data.R",
        call. = FALSE
      )
    }
  }

  message("reading ", transaction_csv)
  transaction <- read_pinned_csv(transaction_csv, transaction_schema)
  message("reading ", identity_csv)
  identity <- read_pinned_csv(identity_csv, identity_schema)

  message("joining (", nrow(transaction), " transactions, ", nrow(identity), " with identity)")
  frame <- join_raw(transaction, identity)

  # Which columns get a map is read off the declarations rather than taken from
  # FREQUENCY_COLUMNS directly. The two agree today; deriving it means they cannot
  # stop agreeing, and a declaration added without a fit would fail loudly here
  # instead of at the first row that needed the missing map.
  fitted <- fit_frequency_maps(frame, columns = frequency_encoded_columns(declared))
  report_frequency_maps(fitted)

  message("applying ", length(declared), " derivations")
  apply_derivations(frame, declared, maps = fitted$maps)

  data.table::setattr(frame, "frequency_maps", fitted)
  data.table::setattr(frame, "provenance", list(
    source = "standalone",
    built_from = c(basename(transaction_csv), basename(identity_csv)),
    built_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    rows = nrow(frame),
    columns = ncol(frame),
    derivations = length(declared),
    entity_aggregates = FALSE
  ))
  frame
}

#' Write the frame, and the fitted maps beside it.
#'
#' The maps go to their own file as well as into the contract: `_targets.R` reads
#' them back without re-reading a 1.5 GB parquet, and a reader can diff two fits
#' without diffing two frames.
write_audit_frame <- function(frame,
                              path = AUDIT_FRAME_PATH,
                              maps_path = FREQUENCY_MAPS_FILE) {
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  dir.create(dirname(maps_path), showWarnings = FALSE, recursive = TRUE)

  arrow::write_parquet(frame, path)
  message("wrote ", path)

  fitted <- attr(frame, "frequency_maps")
  if (!is.null(fitted)) {
    jsonlite::write_json(fitted, maps_path, auto_unbox = TRUE, digits = NA, pretty = TRUE)
    message("wrote ", maps_path)
  }
  invisible(path)
}
