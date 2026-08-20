# Building the audit frame from CSVs.
#
# Synthetic CSVs written to a temporary directory, so this runs on a pull request
# without the competition data. What it asserts is the shape of the handover: the
# join keeps every transaction, the V-block null count is computed before
# anything could impute it, and the frame records which mode built it — because a
# standalone build carries no entity aggregates and a contract that did not say so
# would claim verdicts it does not have.

write_fixture <- function(dir) {
  transaction_schema <- list(
    list(name = "TransactionID", type = "INTEGER", mode = "NULLABLE"),
    list(name = "isFraud", type = "INTEGER", mode = "NULLABLE"),
    list(name = "TransactionDT", type = "INTEGER", mode = "NULLABLE"),
    list(name = "TransactionAmt", type = "FLOAT", mode = "NULLABLE"),
    list(name = "ProductCD", type = "STRING", mode = "NULLABLE"),
    list(name = "addr1", type = "INTEGER", mode = "NULLABLE"),
    list(name = "D1", type = "FLOAT", mode = "NULLABLE"),
    list(name = "M1", type = "BOOLEAN", mode = "NULLABLE"),
    list(name = "V1", type = "FLOAT", mode = "NULLABLE"),
    list(name = "V2", type = "FLOAT", mode = "NULLABLE")
  )
  identity_schema <- list(
    list(name = "TransactionID", type = "INTEGER", mode = "NULLABLE"),
    list(name = "DeviceInfo", type = "STRING", mode = "NULLABLE")
  )

  transaction <- data.table::data.table(
    TransactionID = 1:6,
    isFraud = c(0L, 1L, 0L, 0L, 1L, 0L),
    TransactionDT = c(0L, 86400L, 172800L, 259200L, 345600L, 432000L),
    TransactionAmt = c(10.5, 20, 30, 40, 50, 60),
    ProductCD = c("W", "W", "C", "W", "C", "W"),
    addr1 = c(315L, 315L, 204L, 315L, NA, 204L),
    D1 = c(0, 1, NA, 3, 0, 5),
    M1 = c("T", "F", NA, "T", "T", "F"),
    V1 = c(1, NA, 3, NA, 5, 6),
    V2 = c(NA, NA, 3, 4, 5, 6)
  )
  # Only three of the six transactions have identity, which is the point of the LEFT join.
  identity <- data.table::data.table(
    TransactionID = c(1L, 3L, 5L),
    DeviceInfo = c("Windows", "iOS", "Windows")
  )

  paths <- list(
    transaction_csv = file.path(dir, "train_transaction.csv"),
    identity_csv = file.path(dir, "train_identity.csv"),
    transaction_schema = file.path(dir, "tx_schema.json"),
    identity_schema = file.path(dir, "id_schema.json")
  )
  data.table::fwrite(transaction, paths$transaction_csv)
  data.table::fwrite(identity, paths$identity_csv)
  jsonlite::write_json(transaction_schema, paths$transaction_schema, auto_unbox = TRUE)
  jsonlite::write_json(identity_schema, paths$identity_schema, auto_unbox = TRUE)
  paths
}

test_that("the schema decides the column types rather than the reader guessing", {
  dir <- withr::local_tempdir()
  paths <- write_fixture(dir)
  dt <- read_pinned_csv(paths$transaction_csv, paths$transaction_schema)

  # An integer addr1 stringifies to "315"; a double would give "315.0" and would
  # not match a frequency map fitted on the other side.
  expect_true(is.integer(dt$addr1))
  expect_equal(as.character(dt$addr1[[1]]), "315")
  expect_true(is.character(dt$ProductCD))
  expect_true(is.numeric(dt$TransactionAmt))
})

test_that("T and F become logicals, not the strings the CSV holds", {
  dir <- withr::local_tempdir()
  paths <- write_fixture(dir)
  dt <- read_pinned_csv(paths$transaction_csv, paths$transaction_schema)
  expect_true(is.logical(dt$M1))
  expect_equal(dt$M1, c(TRUE, FALSE, NA, TRUE, TRUE, FALSE))
})

test_that("the join keeps every transaction, matched or not", {
  dir <- withr::local_tempdir()
  paths <- write_fixture(dir)
  joined <- join_raw(
    read_pinned_csv(paths$transaction_csv, paths$transaction_schema),
    read_pinned_csv(paths$identity_csv, paths$identity_schema)
  )
  expect_equal(nrow(joined), 6L)
  expect_equal(sum(!is.na(joined$DeviceInfo)), 3L)
})

test_that("the V-block null count is computed on the raw nulls", {
  dir <- withr::local_tempdir()
  paths <- write_fixture(dir)
  joined <- join_raw(
    read_pinned_csv(paths$transaction_csv, paths$transaction_schema),
    read_pinned_csv(paths$identity_csv, paths$identity_schema)
  )
  data.table::setorderv(joined, "TransactionID")
  # V1/V2 per row: (1,NA) (NA,NA) (3,3) (NA,4) (5,5) (6,6)
  expect_equal(joined[[NULL_COUNT_COLUMN]], c(1L, 2L, 0L, 1L, 0L, 0L))
})

test_that("the frame comes back sorted on the time axis", {
  dir <- withr::local_tempdir()
  paths <- write_fixture(dir)
  joined <- join_raw(
    read_pinned_csv(paths$transaction_csv, paths$transaction_schema),
    read_pinned_csv(paths$identity_csv, paths$identity_schema)
  )
  expect_false(is.unsorted(joined$TransactionDT))
})

test_that("a standalone build says it carries no entity aggregates", {
  dir <- withr::local_tempdir()
  paths <- write_fixture(dir)
  declared <- list(
    derivation("D1n", "days_since_to_start_day", "D1"),
    derivation("ProductCD_is_W", "one_hot", "ProductCD", list(level = "W")),
    derivation("addr1_freq", "frequency_encode", "addr1")
  )
  frame <- build_audit_frame(
    paths$transaction_csv, paths$identity_csv,
    paths$transaction_schema, paths$identity_schema,
    declared = declared
  )

  provenance <- attr(frame, "provenance")
  expect_equal(provenance$source, "standalone")
  expect_false(provenance$entity_aggregates)
  expect_equal(provenance$derivations, 3L)
  expect_true(all(c("D1n", "ProductCD_is_W", "addr1_freq") %in% names(frame)))
  expect_false(is.null(attr(frame, "frequency_maps")))
})

test_that("a missing CSV names the command that fetches it", {
  dir <- withr::local_tempdir()
  paths <- write_fixture(dir)
  expect_error(
    build_audit_frame(file.path(dir, "absent.csv"), paths$identity_csv,
                      paths$transaction_schema, paths$identity_schema),
    "fetch-kaggle-data"
  )
})
