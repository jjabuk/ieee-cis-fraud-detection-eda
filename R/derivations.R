# Columns the contract *defines* rather than merely admits.
#
# A derived column does not exist in the raw tables; the contract says how to
# compute it. This file is where "how" is stated -- three tools and a list of
# declarations naming which tool, over which inputs, with which parameters.
#
# **The declaration is the specification and it leaves with the contract.** The
# pipeline that trains the model does not carry its own copy of this list: it
# reads the `derivations` block out of the contract and renders each entry into
# the SQL or the dataframe operation it needs. That is what makes the boundary
# point one way -- the audits decide what a column *is*, the pipeline decides how
# to compute it at scale, and neither infers the other's half.
#
# **Row-local only.** Every tool here computes from one row and nothing else,
# which makes it trivially point-in-time and trivially servable. Two things that
# look similar and do not belong here:
#
#   * an *entity aggregate* (a mean over a client's past) needs a window over
#     earlier rows. Those are computed by the pipeline's BigQuery SQL under
#     `RANGE ... 1 PRECEDING` and are absent from a frame built here; see
#     `build_audit_frame()`.
#   * a *fitted transform* needs its parameters committed, because a mapping
#     refitted later is a different mapping. `frequency_encode` is one, and its
#     counts are fitted in `frequency_maps.R` and travel inside the contract.

SECONDS_PER_DAY <- 86400L

#: The columns frequency encoding is fitted for. Defined here rather than in
#: `frequency_maps.R` because `DERIVATIONS` below is built at source time and the
#: files are sourced in alphabetical order.
#:
#: High cardinality is the *precondition*, not the reason. One-hot on `DeviceInfo`
#: (1,786 levels) or `id_31` (130) would add that many mostly-zero columns where
#: this adds one integer -- but that only argues frequency encoding is *possible*
#: here, not that it is worth anything. The reason is measured; see `DERIVATIONS`.
FREQUENCY_COLUMNS <- c("addr1", "P_emaildomain", "R_emaildomain", "DeviceInfo", "id_31")

#' `floor(time / 86400) - days_since` -- the day the counter started.
#'
#' Each `D` column counts days since something began for this card; subtracting
#' it from the transaction's own day recovers the day it began. That value is
#' constant across a client's history, which is what makes it usable both as an
#' identity component and as a feature whose distribution does not drift with the
#' calendar.
#'
#' NA in, NA out. Filling the gap would invent a start day, and every row missing
#' the counter would share one fictitious value -- the same failure mode as
#' sentinel-filling an entity key, which measured *worse* than not reconstructing
#' at all.
#'
#' After Konstantin Yakovlev, "IEEE - uid detection" (Kaggle). See ATTRIBUTION.md.
derive_days_since_to_start_day <- function(dt, inputs, params = list()) {
  time_column <- params$time_column %||% "TransactionDT"
  unit <- params$unit_seconds %||% SECONDS_PER_DAY
  as.numeric(floor(dt[[time_column]] / unit) - dt[[inputs[[1]]]])
}

#' 1 when the column equals `level`, 0 for any other value, NA when the source is NA.
#'
#' **One indicator per declaration, with the level named in the parameters.** A
#' tool that expanded a column into whatever levels it found would infer a
#' different set here than at serving time, and the mismatch would be invisible:
#' the serving frame would simply carry different columns. Naming levels
#' explicitly also means a new category shows up as an indicator that is 0
#' everywhere rather than as a reshaped matrix.
#'
#' **NA stays NA.** Mapping it to 0 would assert "not M0" about a row where
#' nobody recorded M4, and M4 is missing on 47.7% of rows. A tree learner routes
#' missing values down whichever branch fits them, so keeping them distinct from
#' "not this level" costs nothing.
derive_one_hot <- function(dt, inputs, params = list()) {
  values <- as.character(dt[[inputs[[1]]]])
  out <- as.integer(values == params$level)
  out[is.na(values)] <- NA_integer_
  out
}

#' How often this value occurs, from counts fitted on the training split.
#'
#' A fitted transform, so its parameters travel with the contract. Counting the
#' frame in hand would give the audits and the pipeline two different mappings;
#' counting the whole table would be transductive, which the point-in-time rule
#' forbids.
#'
#' **An unseen value maps to NA, not 0.** Zero would claim the value occurs zero
#' times, which is false -- it occurs in the row being scored. NA says what is
#' true: the training window has nothing to say about it.
#'
#' The technique is from Yakovlev, "IEEE - Basic FE Part 1"; the
#' training-split-only fit, the evidence-based column choice and the
#' NA-for-unseen rule are not. See ATTRIBUTION.md.
derive_frequency_encode <- function(dt, inputs, params = list()) {
  column <- inputs[[1]]
  key <- params$map_key %||% column
  table <- params$maps[[key]]
  if (is.null(table)) {
    stop(
      "no frequency map for ", column, " (have: ",
      paste(utils::head(sort(names(params$maps)), 8), collapse = ", "),
      "). Fit them with fit_frequency_maps() before applying derivations.",
      call. = FALSE
    )
  }
  as.integer(unname(unlist(table, use.names = FALSE))[
    match(as.character(dt[[column]]), names(table))
  ])
}

#: The tool registry. A declaration names one of these; nothing else is callable.
DERIVATION_TOOLS <- list(
  days_since_to_start_day = derive_days_since_to_start_day,
  one_hot = derive_one_hot,
  frequency_encode = derive_frequency_encode
)

# Helper for the declaration table below, so thirty entries do not become ninety lines.
derivation <- function(name, tool, inputs, params = list()) {
  list(name = name, tool = tool, inputs = as.list(inputs), params = params)
}

#: Every derived column, in the order it is computed.
#:
#: The `D` normalisations come first because the entity key is built from one of
#: them and the audits ask whether that reconstruction is real. The one-hot
#: indicators name their levels explicitly, for the reason in `derive_one_hot`.
#: The frequency encodings come last because they need maps fitted on a split of
#: the frame the earlier ones helped produce.
#:
#: Which columns get frequency-encoded is a measured decision, not a
#: cardinality rule: rarity has to predict fraud, and it does for these five
#: (`id_31` runs 6.77x -> 2.17x the base rate across frequency bands,
#: monotonically) and does not for `card1` (0.85 / 0.76 / 1.19 / 0.98) or
#: `card2`, which were in this list until the question was actually asked.
DERIVATIONS <- c(
  lapply(
    c("D1", "D2", "D3", "D5", "D10", "D11", "D15"),
    function(d) derivation(paste0(d, "n"), "days_since_to_start_day", d)
  ),
  list(
    derivation("ProductCD_is_W", "one_hot", "ProductCD", list(level = "W")),
    derivation("ProductCD_is_C", "one_hot", "ProductCD", list(level = "C")),
    derivation("ProductCD_is_R", "one_hot", "ProductCD", list(level = "R")),
    derivation("ProductCD_is_H", "one_hot", "ProductCD", list(level = "H")),
    derivation("ProductCD_is_S", "one_hot", "ProductCD", list(level = "S")),
    derivation("card4_is_visa", "one_hot", "card4", list(level = "visa")),
    derivation("card4_is_mastercard", "one_hot", "card4", list(level = "mastercard")),
    derivation("card4_is_american_express", "one_hot", "card4", list(level = "american express")),
    derivation("card4_is_discover", "one_hot", "card4", list(level = "discover")),
    derivation("card6_is_debit", "one_hot", "card6", list(level = "debit")),
    derivation("card6_is_credit", "one_hot", "card6", list(level = "credit")),
    derivation("card6_is_debit_or_credit", "one_hot", "card6", list(level = "debit or credit")),
    derivation("card6_is_charge_card", "one_hot", "card6", list(level = "charge card")),
    # M4 is a three-level string, so it gets indicators rather than the boolean
    # treatment M1-M9 get. It is also 47.7% missing, which is why NA stays NA.
    derivation("M4_is_M0", "one_hot", "M4", list(level = "M0")),
    derivation("M4_is_M1", "one_hot", "M4", list(level = "M1")),
    derivation("M4_is_M2", "one_hot", "M4", list(level = "M2")),
    derivation("DeviceType_is_desktop", "one_hot", "DeviceType", list(level = "desktop")),
    derivation("DeviceType_is_mobile", "one_hot", "DeviceType", list(level = "mobile"))
  ),
  lapply(
    FREQUENCY_COLUMNS,
    function(column) derivation(paste0(column, "_freq"), "frequency_encode", column)
  )
)

#' Add every declared derived column to `dt`, in place.
#'
#' Missing inputs stop the run rather than being skipped: a derivation that
#' silently does not happen produces an audit of fewer columns than the contract
#' will declare, and the verdicts would describe a table nobody built.
#'
#' @param maps Fitted frequency maps, as returned by `fit_frequency_maps()$maps`.
#'   Only the `frequency_encode` declarations read them.
apply_derivations <- function(dt, declared = DERIVATIONS, maps = list()) {
  for (spec in declared) {
    tool <- DERIVATION_TOOLS[[spec$tool]]
    if (is.null(tool)) {
      stop("unknown derivation tool: ", spec$tool, call. = FALSE)
    }
    inputs <- unlist(spec$inputs, use.names = FALSE)
    missing <- setdiff(c(inputs, if (spec$tool == "days_since_to_start_day") "TransactionDT"),
                       names(dt))
    if (length(missing)) {
      stop(
        "cannot compute ", spec$name, ": ", paste(missing, collapse = ", "),
        " not in the frame", call. = FALSE
      )
    }
    params <- spec$params
    params$maps <- maps
    data.table::set(dt, j = spec$name, value = tool(dt, inputs, params))
  }
  dt[]
}

#' Which columns the declared frequency encodings need a fitted map for.
#'
#' Read off the declarations rather than from `FREQUENCY_COLUMNS`, so the fit and
#' the encodings cannot drift: a declaration added without a matching fit stops
#' the build rather than the first row that needs the missing map.
frequency_encoded_columns <- function(declared = DERIVATIONS) {
  encodings <- Filter(function(spec) spec$tool == "frequency_encode", declared)
  unique(vapply(
    encodings,
    function(spec) spec$params$map_key %||% spec$inputs[[1]],
    character(1)
  ))
}

#' The declarations as they travel in the contract.
#'
#' Parameters are kept, `maps` is not: the fitted counts are a separate block, so
#' a reader diffing two contracts sees a threshold change without 48 kB of counts
#' moving next to it.
derivation_declarations <- function(declared = DERIVATIONS) {
  lapply(declared, function(spec) {
    params <- spec$params
    params$maps <- NULL
    list(
      name = spec$name,
      tool = spec$tool,
      inputs = spec$inputs,
      params = if (length(params)) params else NULL
    )
  })
}
