# =============================================================================
# Wisconsin IIS Data Ingestion
# Source: Wisconsin DHS - Adult Immunization Data
# https://www.dhs.wisconsin.gov/immunization/adult-vaccine-data.htm
# Data from Wisconsin Immunization Registry (WIR)
# =============================================================================

library(dplyr)
library(tidyr)

process <- dcf::dcf_process_record()

# -----------------------------------------------------------------------------
# 1. Download raw data (4 CSV files)
# -----------------------------------------------------------------------------
base_url <- paste0(
  "https://www.dhs.wisconsin.gov/immunization/"
)

files <- c(
  "statewide-adult-immunization-data.csv",
  "county-adult-immunization-data.csv",
  "region-adult-immunization-data.csv",
  "demographic-adult-immunization-data.csv"
)

for (f in files) {
  resp <- httr::GET(
    paste0(base_url, f),
    httr::user_agent(
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    ),
    httr::timeout(60)
  )
  writeBin(httr::content(resp, "raw"), file.path("raw", f))
}

raw_hashes <- sapply(
  file.path("raw", files), tools::md5sum
)
raw_state <- list(hashes = raw_hashes)

if (!identical(process$raw_state, raw_state)) {

  # -----------------------------------------------------------
  # 2. Load FIPS lookup
  # -----------------------------------------------------------
  all_fips <- vroom::vroom(
    "../../resources/all_fips.csv.gz",
    show_col_types = FALSE,
    col_types = list(geography = "c")
  )

  wi_county_fips <- all_fips %>%
    filter(
      nchar(geography) == 5,
      substr(geography, 1, 2) == "55"
    ) %>%
    select(geography, geography_name) %>%
    mutate(
      county_name = sub(" County$", "", geography_name)
    )

  # -----------------------------------------------------------
  # 3. Process county-level data
  # -----------------------------------------------------------
  county_raw <- vroom::vroom(
    "raw/county-adult-immunization-data.csv",
    show_col_types = FALSE
  )

  county_data <- county_raw %>%
    mutate(
      pct = as.numeric(sub("%", "", Percent)),
      # Clean vaccine+age into column name
      vaccine_clean = tolower(
        gsub("[^a-zA-Z0-9]", "_", Vaccine)
      ),
      vaccine_clean = gsub("_+", "_", vaccine_clean),
      vaccine_clean = gsub("^_|_$", "", vaccine_clean),
      # Remap to canonical vaccine names
      vaccine_clean = dplyr::recode(
        vaccine_clean,
        "hpv_complete" = "hpv",
        "hepa_complete" = "hepa",
        "hepb_1" = "hepb_initiated",
        "hepb_complete" = "hepb",
        "pneumo_complete" = "pneumo",
        "td_or_tdap" = "tdap_any",
        "zoster_shingles_complete" = "zoster"
      ),
      age_clean = tolower(
        gsub("[^a-zA-Z0-9]", "_", Age)
      ),
      age_clean = gsub("_+", "_", age_clean),
      age_clean = gsub("^_|_$", "", age_clean),
      col_name = paste0(
        "iis_", vaccine_clean, "_rate"
      ),
      time = paste0(Year, "-12-31")
    ) %>%
    left_join(
      wi_county_fips,
      by = c("County" = "county_name")
    ) %>%
    filter(!is.na(geography)) %>%
    select(geography, time, age_clean, col_name, pct) %>%
    pivot_wider(
      names_from = col_name,
      values_from = pct
    ) %>%
    rename(age = age_clean)

  # -----------------------------------------------------------
  # 4. Process statewide data
  # -----------------------------------------------------------
  state_raw <- vroom::vroom(
    "raw/statewide-adult-immunization-data.csv",
    show_col_types = FALSE
  )

  state_data <- state_raw %>%
    mutate(
      pct = as.numeric(sub("%", "", Percent)),
      vaccine_clean = tolower(
        gsub("[^a-zA-Z0-9]", "_", Vaccine)
      ),
      vaccine_clean = gsub("_+", "_", vaccine_clean),
      vaccine_clean = gsub("^_|_$", "", vaccine_clean),
      vaccine_clean = dplyr::recode(
        vaccine_clean,
        "hpv_complete" = "hpv",
        "hepa_complete" = "hepa",
        "hepb_1" = "hepb_initiated",
        "hepb_complete" = "hepb",
        "pneumo_complete" = "pneumo",
        "td_or_tdap" = "tdap_any",
        "zoster_shingles_complete" = "zoster"
      ),
      age_clean = tolower(
        gsub("[^a-zA-Z0-9]", "_", Age)
      ),
      age_clean = gsub("_+", "_", age_clean),
      age_clean = gsub("^_|_$", "", age_clean),
      col_name = paste0(
        "iis_", vaccine_clean, "_rate"
      ),
      time = paste0(Year, "-12-31"),
      geography = "55"
    ) %>%
    select(
      geography, time, age_clean, col_name, pct
    ) %>%
    pivot_wider(
      names_from = col_name,
      values_from = pct
    ) %>%
    rename(age = age_clean)

  # -----------------------------------------------------------
  # 5. Combine and write
  # -----------------------------------------------------------
  data_standard <- bind_rows(state_data, county_data) %>%
    select(geography, time, age, everything())

  vroom::vroom_write(
    data_standard,
    "standard/data.csv.gz",
    delim = ","
  )

  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
