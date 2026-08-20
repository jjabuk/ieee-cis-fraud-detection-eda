# Fetching the competition data.
#
# The dataset is not committed -- the competition terms do not allow
# redistributing it -- so every reader fetches their own copy. This is the only
# code here that reaches outside the process, and it is deliberately the only
# thing standing between a fresh clone and a full audit run.
#
# Credentials come from the same place the Kaggle CLI reads them, so anyone who
# has ever used that tool already has them: `~/.kaggle/kaggle.json`, or the
# `KAGGLE_USERNAME` / `KAGGLE_KEY` environment variables, which win when set.

KAGGLE_COMPETITION <- "ieee-fraud-detection"

#: The two files the audits need. The competition ships four; `test_*` carries no
#: label, and an audit whose every verdict is a statement about `isFraud` has
#: nothing to say about rows that do not have one.
KAGGLE_FILES <- c("train_transaction.csv", "train_identity.csv")

#' Read the Kaggle API credentials.
#'
#' Environment first, then `~/.kaggle/kaggle.json`. Returns `username:key` in the
#' form `curl` wants for HTTP basic auth.
#'
#' The error is long on purpose. Downloading competition data fails for two
#' unrelated reasons -- no credentials, and credentials belonging to an account
#' that never accepted the competition rules -- and they need different fixes.
kaggle_credentials <- function(config_path = "~/.kaggle/kaggle.json") {
  user <- Sys.getenv("KAGGLE_USERNAME")
  key <- Sys.getenv("KAGGLE_KEY")

  if (!nzchar(user) || !nzchar(key)) {
    path <- path.expand(config_path)
    if (!file.exists(path)) {
      stop(
        "no Kaggle credentials.\n",
        "  Set KAGGLE_USERNAME and KAGGLE_KEY, or put a token at ", config_path, ".\n",
        "  The token comes from https://www.kaggle.com/settings -> API -> Create New Token.\n",
        "  You must also accept the rules at\n",
        "  https://www.kaggle.com/c/", KAGGLE_COMPETITION, "/rules ",
        "or every download returns 403.",
        call. = FALSE
      )
    }
    config <- jsonlite::fromJSON(path)
    user <- config$username
    key <- config$key
  }

  paste0(user, ":", key)
}

#' Download one competition file into `dest_dir`.
#'
#' Kaggle serves competition files zipped, and serves a bare file when it is
#' small enough not to be. Both happen for this competition depending on the
#' file, so the response is sniffed for the ZIP magic bytes rather than assumed
#' from the extension.
#'
#' Skips a file that is already there. Re-downloading 600 MB because a later
#' target failed is a bad default.
fetch_kaggle_file <- function(file,
                              dest_dir = "data",
                              competition = KAGGLE_COMPETITION,
                              overwrite = FALSE) {
  dir.create(dest_dir, showWarnings = FALSE, recursive = TRUE)
  destination <- file.path(dest_dir, file)

  if (file.exists(destination) && !overwrite) {
    message("  ", file, " is already here (", format_size(destination), "), skipping")
    return(invisible(destination))
  }

  url <- paste0(
    "https://www.kaggle.com/api/v1/competitions/data/download/",
    competition, "/", file
  )
  handle <- curl::new_handle(
    userpwd = kaggle_credentials(),
    httpauth = 1L, # HTTP basic
    followlocation = TRUE
  )

  temp <- tempfile(fileext = ".download")
  on.exit(unlink(temp), add = TRUE)

  message("  fetching ", file, " ...")
  response <- curl::curl_fetch_disk(url, temp, handle)
  if (response$status_code != 200L) {
    stop(
      "Kaggle returned HTTP ", response$status_code, " for ", file, ".\n",
      if (response$status_code == 403L) {
        paste0(
          "  403 usually means the account has not accepted the competition rules.\n",
          "  Accept them at https://www.kaggle.com/c/", competition, "/rules and retry."
        )
      } else {
        "  Check the credentials and the competition name."
      },
      call. = FALSE
    )
  }

  if (is_zip(temp)) {
    extracted <- utils::unzip(temp, exdir = dest_dir)
    if (!file.exists(destination) && length(extracted) == 1L) {
      file.rename(extracted, destination)
    }
  } else {
    file.copy(temp, destination, overwrite = TRUE)
  }

  message("  wrote ", destination, " (", format_size(destination), ")")
  invisible(destination)
}

#' Fetch every file the audits need.
fetch_kaggle_data <- function(dest_dir = "data",
                              files = KAGGLE_FILES,
                              competition = KAGGLE_COMPETITION,
                              overwrite = FALSE) {
  message("Kaggle competition: ", competition)
  paths <- vapply(
    files,
    fetch_kaggle_file,
    character(1),
    dest_dir = dest_dir, competition = competition, overwrite = overwrite
  )
  invisible(unname(paths))
}

#' The first four bytes of a ZIP archive.
is_zip <- function(path) {
  con <- file(path, "rb")
  on.exit(close(con), add = TRUE)
  identical(readBin(con, "raw", 2L), as.raw(c(0x50, 0x4b)))
}

format_size <- function(path) {
  format(structure(file.size(path), class = "object_size"), units = "auto")
}
