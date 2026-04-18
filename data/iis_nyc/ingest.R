# =============================================================================
# NYC Childhood Immunization Data Ingestion
# Source: NYC Health Department - Citywide Immunization Registry (CIR)
# https://github.com/nychealth/immunization-data
# Geography: NYC boroughs (county FIPS); MODZCTA (ZIP-area) aggregated to borough
# =============================================================================

library(dplyr)
library(tidyr)

process <- dcf::dcf_process_record()

# -----------------------------------------------------------------------------
# 1. Download raw data from GitHub
# -----------------------------------------------------------------------------
url_geo  <- "https://raw.githubusercontent.com/nychealth/immunization-data/main/geo/Main_Routine_Vaccine_Geo.csv"
url_demo <- "https://raw.githubusercontent.com/nychealth/immunization-data/main/demo/Main_Routine_Vaccine_Demo.csv"

download.file(url_geo,  "raw/Main_Routine_Vaccine_Geo.csv",  mode = "wb", quiet = TRUE)
download.file(url_demo, "raw/Main_Routine_Vaccine_Demo.csv", mode = "wb", quiet = TRUE)

raw_state <- list(
  hashes = c(
    geo  = tools::md5sum("raw/Main_Routine_Vaccine_Geo.csv"),
    demo = tools::md5sum("raw/Main_Routine_Vaccine_Demo.csv")
  )
)

if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 2. Load FIPS lookup
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz",
                           show_col_types = FALSE,
                           col_types = list(geography = "c"))

  # NYC borough → county FIPS mapping
  borough_fips <- tibble::tribble(
    ~BOROUGH,       ~geography,
    "Manhattan",    "36061",
    "Brooklyn",     "36047",
    "Bronx",        "36005",
    "Queens",       "36081",
    "Staten Island","36085"
  )

  # ---------------------------------------------------------------------------
  # 3. Read and parse geographic (MODZCTA-level) data
  # ---------------------------------------------------------------------------
  data_geo <- vroom::vroom("raw/Main_Routine_Vaccine_Geo.csv", show_col_types = FALSE) %>%
    # Parse YEAR_COVERAGE: handles "2025" and "2016 - 17" formats
    mutate(
      year_val = as.integer(stringr::str_extract(YEAR_COVERAGE, "\\d{4}")),
      time = case_when(
        QUARTER == "Q2" ~ paste0(year_val, "-06-30"),
        QUARTER == "Q4" ~ paste0(year_val, "-12-31"),
        TRUE ~ NA_character_
      )
    ) %>%
    filter(!is.na(time), !is.na(PERC_VAC), !is.na(POP_DENOMINATOR), POP_DENOMINATOR > 0)

  # ---------------------------------------------------------------------------
  # 4. Aggregate MODZCTA → borough (enrollment-weighted mean)
  # ---------------------------------------------------------------------------
  data_agg <- data_geo %>%
    group_by(BOROUGH, time, AGE_GROUP, VACCINE_GROUP) %>%
    summarize(
      rate = weighted.mean(PERC_VAC, POP_DENOMINATOR, na.rm = TRUE),
      pop  = sum(POP_DENOMINATOR, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    left_join(borough_fips, by = "BOROUGH")

  # ---------------------------------------------------------------------------
  # 5. Build routine vaccine output (wide format by vaccine)
  #    Infant cohort: 24-35 months; Teen cohort: 13-17 years (HPV)
  # ---------------------------------------------------------------------------
  vax_col_map <- c(
    "4313314"   = "iis_infant_series_rate",
    "DTaP"      = "iis_infant_dtap_rate",
    "HepB"      = "iis_infant_hepb_rate",
    "Hib"       = "iis_infant_hib_rate",
    "MMR"       = "iis_infant_mmr_rate",
    "PCV"       = "iis_infant_pcv_rate",
    "Polio"     = "iis_infant_ipv_rate",
    "Varicella" = "iis_infant_var_rate"
  )

  # Infant routine vaccines (24-35 months)
  infant_wide <- data_agg %>%
    filter(AGE_GROUP == "24 - 35 months", VACCINE_GROUP %in% names(vax_col_map)) %>%
    mutate(col_name = vax_col_map[VACCINE_GROUP]) %>%
    select(geography, time, col_name, rate) %>%
    pivot_wider(names_from = col_name, values_from = rate) %>%
    mutate(age = "infant")

  # Teen HPV (13-17 years)
  teen_hpv <- data_agg %>%
    filter(AGE_GROUP == "13 - 17 years", VACCINE_GROUP == "HPV") %>%
    select(geography, time, iis_teen_hpv_rate = rate) %>%
    mutate(age = "teen")

  data_routine <- bind_rows(infant_wide, teen_hpv) %>%
    select(geography, time, age, everything())

  # ---------------------------------------------------------------------------
  # 6. Build flu vaccination output (long by age group)
  # ---------------------------------------------------------------------------
  flu_age_map <- c(
    "6 months - 4 years" = "infant",
    "5 - 12 years"       = "child",
    "13 - 17 years"      = "teen"
  )

  data_flu <- data_agg %>%
    filter(VACCINE_GROUP == "Flu", AGE_GROUP %in% names(flu_age_map)) %>%
    mutate(age = flu_age_map[AGE_GROUP]) %>%
    select(geography, time, age, iis_flu_rate = rate) %>%
    arrange(geography, time, age)

  # ---------------------------------------------------------------------------
  # 7. Process race/ethnicity demographic data (statewide NYC)
  # ---------------------------------------------------------------------------
  # Race/ethnicity values in demo file include ", non-Hispanic" suffix
  re_map <- c(
    "American Indian, non-Hispanic" = "AIAN",
    "Asian, non-Hispanic"           = "Asian",
    "Black, non-Hispanic"           = "Black",
    "Hispanic/Latino"               = "Hispanic",
    "White, non-Hispanic"           = "White"
  )

  # Note: demo file AGE_GROUP uses no spaces around dash ("24-35 months")
  #       unlike the geo file ("24 - 35 months")
  data_demo <- vroom::vroom("raw/Main_Routine_Vaccine_Demo.csv", show_col_types = FALSE) %>%
    mutate(
      year_val = as.integer(stringr::str_extract(YEAR_COVERAGE, "\\d{4}")),
      time = case_when(
        QUARTER == "Q2" ~ paste0(year_val, "-06-30"),
        QUARTER == "Q4" ~ paste0(year_val, "-12-31"),
        TRUE ~ NA_character_
      ),
      race_ethnicity = re_map[RACE_ETHNICITY]
    ) %>%
    filter(
      !is.na(time), !is.na(PERC_VAC),
      !is.na(race_ethnicity),
      AGE_GROUP == "24-35 months",   # no spaces in demo file
      VACCINE_GROUP == "4313314"
    ) %>%
    mutate(geography = "36") %>%   # NYC-wide (using NY state FIPS as placeholder)
    select(geography, time, race_ethnicity,
           iis_infant_series_rate = PERC_VAC,
           iis_infant_pop = POP_DENOMINATOR)

  # ---------------------------------------------------------------------------
  # 8. Write standardized output
  # ---------------------------------------------------------------------------
  vroom::vroom_write(data_routine, "standard/data.csv.gz",      delim = ",")
  vroom::vroom_write(data_flu,     "standard/data_flu.csv.gz",  delim = ",")
  vroom::vroom_write(data_demo,    "standard/data_race.csv.gz", delim = ",")

  # ---------------------------------------------------------------------------
  # 9. Update process record
  # ---------------------------------------------------------------------------
  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
