# The three derivation tools, and the declaration table they are driven by.
#
# Synthetic throughout: these assert the *semantics* the contract promises, which
# is what the pipeline reads the declaration expecting. A tool that quietly maps
# an unseen category to 0 instead of NA would still pass every statistical audit
# downstream and would still be wrong.

test_that("the start day is the transaction day minus the counter", {
  dt <- data.table::data.table(
    TransactionDT = c(0, 86400, 86400 * 10 + 500),
    D1 = c(0, 1, 3)
  )
  expect_equal(derive_days_since_to_start_day(dt, "D1"), c(0, 0, 7))
})

test_that("a missing counter gives a missing start day rather than an invented one", {
  dt <- data.table::data.table(TransactionDT = c(86400, 86400), D1 = c(NA_real_, 1))
  out <- derive_days_since_to_start_day(dt, "D1")
  expect_true(is.na(out[[1]]))
  expect_equal(out[[2]], 0)
})

test_that("one-hot is 1 on the level, 0 off it, and NA when the source is NA", {
  dt <- data.table::data.table(ProductCD = c("W", "C", NA, "W"))
  out <- derive_one_hot(dt, "ProductCD", list(level = "W"))
  expect_equal(out, c(1L, 0L, NA_integer_, 1L))
})

test_that("one-hot on an unseen level is an indicator that is 0, not an error", {
  dt <- data.table::data.table(card4 = c("visa", "brand-new-scheme"))
  expect_equal(derive_one_hot(dt, "card4", list(level = "visa")), c(1L, 0L))
})

test_that("frequency encoding reads the fitted map, and an unseen value is NA not 0", {
  dt <- data.table::data.table(addr1 = c("315", "204", "never-seen", NA))
  maps <- list(addr1 = list("315" = 120L, "204" = 7L))
  out <- derive_frequency_encode(dt, "addr1", list(maps = maps))
  expect_equal(out, c(120L, 7L, NA_integer_, NA_integer_))
})

test_that("a frequency encoding with no fitted map stops instead of guessing", {
  dt <- data.table::data.table(addr1 = c("315"))
  expect_error(
    derive_frequency_encode(dt, "addr1", list(maps = list(id_31 = list(a = 2L)))),
    "no frequency map for addr1"
  )
})

test_that("every declaration names a tool that exists and inputs that are named", {
  for (spec in DERIVATIONS) {
    expect_true(spec$tool %in% names(DERIVATION_TOOLS), info = spec$name)
    expect_gt(length(spec$inputs), 0)
    expect_true(nzchar(spec$name))
  }
})

test_that("the declared set is the thirty columns the contract defines", {
  tools <- vapply(DERIVATIONS, function(s) s$tool, character(1))
  expect_equal(length(DERIVATIONS), 30L)
  expect_equal(sum(tools == "days_since_to_start_day"), 7L)
  expect_equal(sum(tools == "one_hot"), 18L)
  expect_equal(sum(tools == "frequency_encode"), 5L)
})

test_that("applying the declarations adds every declared column and nothing else", {
  dt <- data.table::data.table(
    TransactionDT = c(0, 86400),
    D1 = c(0, 1), D2 = c(0, 1), D3 = c(0, 1), D5 = c(0, 1),
    D10 = c(0, 1), D11 = c(0, 1), D15 = c(0, 1),
    ProductCD = c("W", "C"), card4 = c("visa", "discover"),
    card6 = c("debit", "credit"), M4 = c("M0", NA),
    DeviceType = c("desktop", "mobile"),
    addr1 = c(315L, 204L), P_emaildomain = c("gmail.com", "aol.com"),
    R_emaildomain = c("gmail.com", NA), DeviceInfo = c("Windows", "iOS"),
    id_31 = c("chrome", "safari")
  )
  # `copy`, because `set()` updates the names attribute by reference.
  before <- data.table::copy(names(dt))
  maps <- stats::setNames(
    lapply(FREQUENCY_COLUMNS, function(x) list("315" = 2L, "gmail.com" = 3L,
                                               "Windows" = 4L, "chrome" = 5L)),
    FREQUENCY_COLUMNS
  )
  apply_derivations(dt, DERIVATIONS, maps = maps)

  added <- setdiff(names(dt), before)
  expect_setequal(added, vapply(DERIVATIONS, function(s) s$name, character(1)))
})

test_that("a derivation whose input is absent stops the run", {
  dt <- data.table::data.table(TransactionDT = c(0, 86400))
  expect_error(
    apply_derivations(dt, list(derivation("D1n", "days_since_to_start_day", "D1"))),
    "cannot compute D1n"
  )
})

test_that("an unknown tool stops the run rather than being skipped", {
  dt <- data.table::data.table(x = 1:2)
  expect_error(
    apply_derivations(dt, list(derivation("y", "no_such_tool", "x"))),
    "unknown derivation tool"
  )
})

test_that("the declarations that travel in the contract carry no fitted counts", {
  declarations <- derivation_declarations()
  expect_equal(length(declarations), length(DERIVATIONS))
  for (spec in declarations) {
    expect_null(spec$params$maps)
    expect_true(all(c("name", "tool", "inputs") %in% names(spec)))
  }
})
