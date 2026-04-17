# =============================================================================
# New York State IIS Data Ingestion
# Source: NYSIIS via health.data.ny.gov (Socrata)
# https://coronavirus.health.ny.gov/
#   covid-19-and-influenza-vaccination-data
# Note: Excludes NYC (separate IIS)
# =============================================================================

library(dplyr)

process <- dcf::dcf_process_record()

# -----------------------------------------------------------------------------
# 1. Download raw data via Socrata API
# -----------------------------------------------------------------------------
# Dataset xrhr-cy84: current season COVID + Flu doses
api_url <- paste0(
  "https://health.data.ny.gov/resource/xrhr-cy84.csv",
  "?$limit=50000"
)

resp <- httr::GET(
  api_url,
  httr::user_agent(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
  ),
  httr::timeout(120)
)
writeBin(
  httr::content(resp, "raw"),
  "raw/xrhr-cy84.csv"
)

raw_state <- list(
  hash = tools::md5sum("raw/xrhr-cy84.csv")
)

if (!identical(process$raw_state, raw_state)) {

  # -----------------------------------------------------------
  # 2. Load FIPS lookup for NY counties
  # -----------------------------------------------------------
  all_fips <- vroom::vroom(
    "../../resources/all_fips.csv.gz",
    show_col_types = FALSE,
    col_types = list(geography = "c")
  )

  ny_county_fips <- all_fips %>%
    filter(
      nchar(geography) == 5,
      substr(geography, 1, 2) == "36"
    ) %>%
    select(geography, geography_name) %>%
    mutate(
      county_name = sub(" County$", "", geography_name)
    )

  # -----------------------------------------------------------
  # 3. Read and transform
  # -----------------------------------------------------------
  data_raw <- vroom::vroom(
    "raw/xrhr-cy84.csv",
    show_col_types = FALSE
  )

  data_standard <- data_raw %>%
    mutate(
      # Parse week_ending (ISO timestamp)
      time = format(
        as.Date(
          substr(week_ending, 1, 10),
          "%Y-%m-%d"
        ),
        "%Y-%m-%d"
      ),
      county_name = geography_description,
      iis_covid_dose_count = as.numeric(
        covid_19_dose_count
      ),
      iis_flu_dose_count = as.numeric(
        influenza_dose_count
      )
    ) %>%
    left_join(
      ny_county_fips,
      by = "county_name"
    ) %>%
    mutate(
      geography = case_when(
        toupper(county_name) == "NEW YORK STATE" |
          geography_level == "State" ~ "36",
        !is.na(geography) ~ geography,
        TRUE ~ NA_character_
      )
    ) %>%
    filter(!is.na(geography)) %>%
    select(
      geography, time,
      iis_covid_dose_count, iis_flu_dose_count
    )

  # -----------------------------------------------------------
  # 4. Write standardized output
  # -----------------------------------------------------------
  vroom::vroom_write(
    data_standard,
    "standard/data.csv.gz",
    delim = ","
  )

  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
