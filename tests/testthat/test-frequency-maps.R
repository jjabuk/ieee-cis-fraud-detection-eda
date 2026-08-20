# Fitting the frequency-encoding count tables.
#
# The properties asserted here are the ones the contract promises about a fitted
# parameter: it is fitted on the training split only, rare levels are dropped
# rather than kept as a fingerprint of one row, and the fit records what it was
# fitted on. Each of the three is a way of being quietly wrong that no downstream
# statistic would catch.

synthetic_frame <- function(n = 1000L, seed = 1L) {
  set.seed(seed)
  data.table::data.table(
    TransactionDT = seq_len(n) * 100L,
    addr1 = c(rep("early-only", 200L), rep("common", 600L), rep("late-only", 200L)),
    P_emaildomain = rep(c("gmail.com", "aol.com"), length.out = n),
    R_emaildomain = rep(c("gmail.com", NA), length.out = n),
    DeviceInfo = rep(c("Windows", "iOS", "singleton-a"), length.out = n),
    id_31 = rep(c("chrome", "safari"), length.out = n)
  )
}

test_that("the fit sees the training split and not a row beyond it", {
  dt <- synthetic_frame()
  fitted <- fit_frequency_maps(dt, train_fraction = 0.75)

  # `late-only` occupies the last 200 of 1000 rows, so a 0.75 cut cannot see it.
  expect_false("late-only" %in% names(fitted$maps$addr1))
  expect_true("common" %in% names(fitted$maps$addr1))
  expect_equal(fitted$fitted_on$rows, 750L)
})

test_that("a level seen once is dropped, so it encodes as NA rather than as a count of 1", {
  dt <- synthetic_frame()
  dt[1L, addr1 := "seen-exactly-once"]
  fitted <- fit_frequency_maps(dt, min_count = 2L)
  expect_false("seen-exactly-once" %in% names(fitted$maps$addr1))
})

test_that("min_count is honoured rather than hard-coded", {
  dt <- synthetic_frame()
  loose <- fit_frequency_maps(dt, min_count = 1L)
  strict <- fit_frequency_maps(dt, min_count = 500L)
  expect_gt(length(loose$maps$addr1), length(strict$maps$addr1))
})

test_that("missing values are not a level", {
  dt <- synthetic_frame()
  fitted <- fit_frequency_maps(dt)
  expect_false(any(is.na(names(fitted$maps$R_emaildomain))))
  expect_false("NA" %in% names(fitted$maps$R_emaildomain))
})

test_that("the fit records what it was fitted on, so a stale map is visible", {
  fitted <- fit_frequency_maps(synthetic_frame())
  expect_equal(fitted$fitted_on$split, "train")
  expect_equal(fitted$fitted_on$train_fraction, 0.75)
  expect_true(is.finite(fitted$fitted_on$boundary))
  expect_equal(fitted$min_count, FREQUENCY_MIN_COUNT)
})

test_that("coverage is the share of training rows the kept levels account for", {
  fitted <- fit_frequency_maps(synthetic_frame())
  for (column in names(fitted$summary)) {
    coverage <- fitted$summary[[column]]$coverage
    expect_gte(coverage, 0)
    expect_lte(coverage, 1)
  }
})

test_that("a column that is not in the frame stops the fit", {
  expect_error(
    fit_frequency_maps(synthetic_frame(), columns = c("addr1", "not_a_column")),
    "not in the frame"
  )
})

test_that("what is fitted here is what the encoder reads back", {
  dt <- synthetic_frame()
  fitted <- fit_frequency_maps(dt)
  encoded <- derive_frequency_encode(dt, "addr1", list(maps = fitted$maps))

  # `common` is in the map with its training count; `late-only` never entered it.
  expect_equal(unique(encoded[dt$addr1 == "common"]), fitted$maps$addr1[["common"]])
  expect_true(all(is.na(encoded[dt$addr1 == "late-only"])))
})
