# Fitting the frequency-encoding count tables.
#
# Frequency encoding replaces a category with how often it occurs. That count has
# to come from somewhere fixed: counting the frame being transformed gives one
# mapping for the audits and another for the scoring period, and counting the
# whole table together is transductive.
#
# So the counts are fitted **once, on the training split only**, and they leave
# with the contract rather than as a loose file beside it. That is the difference
# this repository owns: a fitted parameter is part of the specification the
# pipeline executes, so it belongs under the same fingerprint as the verdicts. A
# contract whose thresholds are pinned and whose fitted mappings are not is
# pinning the easy half.

#: Values seen this rarely in training are dropped from the map, so they encode
#: as NA ("training has nothing to say") rather than as a count fitted on a
#: handful of rows. A count of 1 is not a frequency, it is a fingerprint of one
#: transaction, and a model that splits on it has memorised a row.
FREQUENCY_MIN_COUNT <- 2L

#: The training split ends here on the time axis. The same fraction the pipeline
#: cuts its training split at, and it has to be: a map fitted over a wider window
#: than the model trains on has seen rows the model has not.
FREQUENCY_TRAIN_FRACTION <- 0.75

#' Fit the count tables on the training split.
#'
#' @param dt The joined frame, before derivations.
#' @param columns Which columns to fit. Defaults to the five the declarations use.
#' @param train_fraction Quantile of the time axis the training split ends at.
#' @param min_count Levels rarer than this are dropped.
#' @param time_column The time axis the split is cut on.
#'
#' @return A list with `maps` (column -> named integer vector of counts),
#'   `summary` (levels seen, kept and coverage) and `fitted_on` (what it was fitted
#'   on, so a stale map is visible rather than assumed).
#'
#' `quantile(type = 7)` is R's default and is linear interpolation, which is what
#' BigQuery's `PERCENTILE_CONT` computes. The boundary is inclusive on both sides
#' for the same reason it is in the pipeline's split SQL.
fit_frequency_maps <- function(dt,
                               columns = FREQUENCY_COLUMNS,
                               train_fraction = FREQUENCY_TRAIN_FRACTION,
                               min_count = FREQUENCY_MIN_COUNT,
                               time_column = "TransactionDT") {
  if (!length(columns)) {
    return(list(maps = list(), summary = list(),
                fitted_on = list(split = "train", train_fraction = train_fraction,
                                 time_column = time_column, rows = 0L, boundary = NA_real_),
                min_count = min_count))
  }
  missing <- setdiff(c(columns, time_column), names(dt))
  if (length(missing)) {
    stop("not in the frame: ", paste(missing, collapse = ", "), call. = FALSE)
  }

  boundary <- stats::quantile(dt[[time_column]], train_fraction, na.rm = TRUE, type = 7)
  train_rows <- which(dt[[time_column]] <= boundary)
  if (!length(train_rows)) {
    stop("the training split is empty at fraction ", train_fraction, call. = FALSE)
  }

  maps <- list()
  summary <- list()
  for (column in columns) {
    values <- as.character(dt[[column]][train_rows])
    values <- values[!is.na(values)]
    counts <- table(values)
    kept <- counts[counts >= min_count]

    maps[[column]] <- as.list(as.integer(kept))
    names(maps[[column]]) <- names(kept)
    summary[[column]] <- list(
      levels_seen = length(counts),
      levels_kept = length(kept),
      coverage = round(sum(kept) / length(train_rows), 4)
    )
  }

  list(
    maps = maps,
    summary = summary,
    fitted_on = list(
      split = "train",
      train_fraction = train_fraction,
      time_column = time_column,
      rows = length(train_rows),
      boundary = unname(boundary)
    ),
    min_count = min_count
  )
}

#' Print what was fitted, so a run says what it did.
report_frequency_maps <- function(fitted) {
  message(
    "frequency maps fitted on ", format(fitted$fitted_on$rows, big.mark = ","),
    " training rows (", fitted$fitted_on$train_fraction, " of the time axis)"
  )
  for (column in names(fitted$summary)) {
    s <- fitted$summary[[column]]
    message(sprintf(
      "  %-16s %6s / %6s levels kept   coverage %5.1f%%",
      column,
      format(s$levels_kept, big.mark = ","),
      format(s$levels_seen, big.mark = ","),
      100 * s$coverage
    ))
  }
  invisible(fitted)
}
