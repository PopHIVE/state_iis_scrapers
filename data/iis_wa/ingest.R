# =============================================================================
# Washington IIS Data Ingestion
# Source: Washington State DOH - County Public Health Measures
# https://doh.wa.gov/data-and-statistical-reports/
#   washington-tracking-network-wtn/immunization-data/
#   county-public-health-measures-dashboard
# =============================================================================

library(dplyr)

process <- dcf::dcf_process_record()

# -----------------------------------------------------------------------------
# 1. Download raw data (6 Excel files)
# -----------------------------------------------------------------------------
base_url <- paste0(
  "https://doh.wa.gov/sites/default/files/2025-09/",
  "Immunization-Dashboard-Coverage-"
)

files <- list(
  infant  = "19-35montholds.xlsx",
  child   = "4-6yearolds.xlsx",
  pread   = "9-10yearolds.xlsx",
  preteen = "11-12yearolds.xlsx",
  teen    = "13-17yearolds.xlsx",
  race    = "RaceEthnicity.xlsx"
)

for (f in files) {
  dest <- file.path("raw", f)
  resp <- httr::GET(
    paste0(base_url, f),
    httr::user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"),
    httr::timeout(120)
  )
  writeBin(httr::content(resp, "raw"), dest)
}

raw_hashes <- sapply(file.path("raw", unlist(files)), tools::md5sum)
raw_state  <- list(hashes = raw_hashes)

if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 2. FIPS lookup for Washington counties
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom(
    "../../resources/all_fips.csv.gz",
    show_col_types = FALSE,
    col_types = list(geography = "c")
  )

  wa_county_fips <- all_fips %>%
    filter(nchar(geography) == 5, substr(geography, 1, 2) == "53") %>%
    select(geography, geography_name) %>%
    mutate(county_upper = toupper(sub(" County$", "", geography_name)))

  # ---------------------------------------------------------------------------
  # 3. Helper: parse tab name to ISO date string (last day of month)
  #    Handles both "Dec2016" and "Jun 2025" (with/without space)
  # ---------------------------------------------------------------------------
  parse_wa_date <- function(sheet_name) {
    sn     <- gsub(" ", "", sheet_name)
    mo_str <- substr(sn, 1, 3)
    yr_str <- substr(sn, 4, 7)
    mo_num <- match(mo_str, month.abb)
    format(as.Date(paste0(yr_str, "-", sprintf("%02d", mo_num), "-01")), "%Y-%m-%d")
  }

  # ---------------------------------------------------------------------------
  # 4. Parser for one age-group sheet
  #
  #    Sheet structure:
  #      Row 1: vaccine names (col 1 empty = County; then vaccine name every 3 cols)
  #      Row 2: sub-headers (County, Count, Population, Rate, ...)
  #      Rows 3+: county data
  #
  #    Strategy: read row 1 with col_names=FALSE to locate vaccine positions,
  #    then read data rows with skip=2 / col_names=FALSE to avoid name collisions.
  # ---------------------------------------------------------------------------
  parse_wa_sheet <- function(filepath, age_label, sheet) {
    # --- vaccine name row ---
    hdr_row <- as.character(
      readxl::read_excel(
        filepath, sheet = sheet,
        n_max = 1, col_names = FALSE, col_types = "text"
      )[1, ]
    )

    # Non-empty cells beyond col 1 mark the start of each vaccine group
    vac_pos <- which(!is.na(hdr_row) & nchar(trimws(hdr_row)) > 0 & seq_along(hdr_row) > 1)
    # Rate column is 2 positions after the vaccine name column (Count, Pop, Rate)
    rate_pos  <- vac_pos + 2
    vac_names <- trimws(hdr_row[vac_pos])

    # Clean to snake_case
    clean <- tolower(gsub("[^a-zA-Z0-9]+", "_", vac_names))
    clean <- gsub("^_|_$", "", clean)
    # Strip dose-number prefixes (e.g., "3_hep_b" -> "hep_b")
    clean <- gsub("^[0-9]+_", "", clean)
    # Strip "utd_" prefix (e.g., "utd_hpv" -> "hpv")
    clean <- gsub("^utd_", "", clean)
    # Map series patterns to "series"
    clean[grepl("^series", clean)] <- "series"
    # Remap to canonical vaccine names
    clean <- dplyr::recode(clean,
      "poliovirus" = "ipv",
      "varicella"  = "var",
      "hep_b"      = "hepb",
      "hep_a"      = "hepa",
      "mcv"        = "mcv4"
    )
    col_out <- paste0("iis_", age_label, "_", clean, "_rate")

    # --- data rows (skip both header rows) ---
    raw <- readxl::read_excel(
      filepath, sheet = sheet,
      skip = 2, col_names = FALSE, col_types = "text"
    )

    result <- data.frame(
      county_upper = toupper(trimws(as.character(raw[[1]]))),
      stringsAsFactors = FALSE
    )

    for (i in seq_along(rate_pos)) {
      pos <- rate_pos[i]
      if (pos <= ncol(raw)) {
        vals <- suppressWarnings(as.numeric(as.character(raw[[pos]])))
        result[[col_out[i]]] <- round(vals * 100, 1)
      }
    }

    result %>% filter(!is.na(county_upper), nchar(county_upper) > 0)
  }

  # ---------------------------------------------------------------------------
  # 5. Process each age-group file across all sheets (time periods)
  # ---------------------------------------------------------------------------
  age_files  <- files[names(files) != "race"]
  age_labels <- c(
    infant  = "infant",
    child   = "child",
    pread   = "pread",
    preteen = "preteen",
    teen    = "teen"
  )

  all_age_data <- list()
  for (key in names(age_files)) {
    fpath  <- file.path("raw", age_files[[key]])
    sheets <- readxl::excel_sheets(fpath)

    time_dfs <- lapply(sheets, function(sht) {
      df      <- parse_wa_sheet(fpath, age_labels[[key]], sheet = sht)
      df$time <- parse_wa_date(sht)
      df
    })
    all_age_data[[key]] <- dplyr::bind_rows(time_dfs)
  }

  # ---------------------------------------------------------------------------
  # 6. Merge all age groups by county + time
  # ---------------------------------------------------------------------------
  data_merged <- all_age_data[[1]]
  for (i in 2:length(all_age_data)) {
    data_merged <- dplyr::full_join(
      data_merged, all_age_data[[i]], by = c("county_upper", "time")
    )
  }

  # ---------------------------------------------------------------------------
  # 7. Convert county names to FIPS codes and add state row
  # ---------------------------------------------------------------------------
  data_standard <- data_merged %>%
    left_join(wa_county_fips, by = "county_upper") %>%
    mutate(
      geography = case_when(
        county_upper == "WASHINGTON STATE" ~ "53",
        !is.na(geography)                  ~ geography,
        TRUE                               ~ NA_character_
      )
    ) %>%
    filter(!is.na(geography)) %>%
    select(-county_upper, -geography_name) %>%
    select(geography, time, everything())

  # ---------------------------------------------------------------------------
  # 8. Parse race/ethnicity file
  #
  #    Each sheet = one age group ("19 to 35m", "4 to 6y", etc.)
  #    Within each sheet, time blocks are stacked:
  #      Block header row: col 1 = "Dec 2016" / "Jun 2017", cols 2+ = vaccine names
  #      Sub-header row:   "Race/Ethnicity", Count, Population, Rate, ...
  #      Data rows:        race category rows (9 categories)
  #    Repeat for each time period.
  # ---------------------------------------------------------------------------
  race_age_map <- c(
    "19 to 35m" = "infant",
    "4 to 6y"   = "child",
    "9 to 10y"  = "pread",
    "11 to 12y" = "preteen",
    "13 to 17y" = "teen"
  )

  parse_wa_race_sheet <- function(filepath, sheet, age_label) {
    raw  <- readxl::read_excel(
      filepath, sheet = sheet, col_names = FALSE, col_types = "text"
    )
    col1 <- trimws(as.character(raw[[1]]))

    # Detect block-header rows: "Dec 2016", "Jun 2017", etc.
    is_hdr  <- grepl(
      "^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\\s*\\d{4}$",
      col1
    )
    hdr_idx <- which(is_hdr)

    blocks <- lapply(seq_along(hdr_idx), function(hi) {
      h <- hdr_idx[hi]

      # Time from col 1, vaccine names from cols 2+
      hdr_row   <- as.character(raw[h, ])
      time_val  <- parse_wa_date(hdr_row[1])
      vac_pos   <- which(!is.na(hdr_row) & nchar(trimws(hdr_row)) > 0 & seq_along(hdr_row) > 1)
      rate_pos  <- vac_pos + 2
      vac_names <- trimws(hdr_row[vac_pos])
      clean     <- tolower(gsub("[^a-zA-Z0-9]+", "_", vac_names))
      clean     <- gsub("^_|_$", "", clean)
      clean     <- gsub("^[0-9]+_", "", clean)
      clean     <- gsub("^utd_", "", clean)
      clean     <- ifelse(grepl("^series", clean), "series", clean)
      clean <- dplyr::recode(clean,
        "poliovirus" = "ipv",
        "varicella"  = "var",
        "hep_b"      = "hepb",
        "hep_a"      = "hepa",
        "mcv"        = "mcv4"
      )
      col_out   <- paste0("iis_", age_label, "_", clean, "_rate")

      # Data rows: skip block header + sub-header (2 rows)
      data_start <- h + 2
      data_end   <- if (hi < length(hdr_idx)) hdr_idx[hi + 1] - 1 else nrow(raw)
      if (data_start > nrow(raw)) return(NULL)

      block <- raw[data_start:data_end, ]
      res   <- data.frame(
        race_ethnicity = trimws(as.character(block[[1]])),
        stringsAsFactors = FALSE
      )
      res$time <- time_val
      res$age  <- age_label

      for (i in seq_along(rate_pos)) {
        pos <- rate_pos[i]
        if (pos <= ncol(block)) {
          vals <- suppressWarnings(as.numeric(as.character(block[[pos]])))
          res[[col_out[i]]] <- round(vals * 100, 1)
        }
      }

      res %>% filter(!is.na(race_ethnicity), nchar(race_ethnicity) > 0)
    })

    dplyr::bind_rows(blocks)
  }

  race_sheets <- readxl::excel_sheets(file.path("raw", files$race))
  race_data <- dplyr::bind_rows(lapply(race_sheets, function(sht) {
    lbl <- race_age_map[sht]
    if (is.na(lbl)) return(NULL)
    parse_wa_race_sheet(file.path("raw", files$race), sheet = sht, age_label = lbl)
  }))

  race_standard <- race_data %>%
    mutate(geography = "53") %>%
    select(geography, time, age, race_ethnicity, everything())

  # ---------------------------------------------------------------------------
  # 9. Write standardized outputs
  # ---------------------------------------------------------------------------
  vroom::vroom_write(data_standard,  "standard/data.csv.gz",      delim = ",")
  vroom::vroom_write(race_standard,  "standard/data_race.csv.gz", delim = ",")

  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
