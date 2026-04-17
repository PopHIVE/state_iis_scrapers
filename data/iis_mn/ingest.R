# =============================================================================
# Minnesota IIS Data Ingestion
# Source: Minnesota Department of Health - Immunization Gaps Analysis
# https://www.health.mn.gov/people/immunize/stats/gaps.html
# Data from Minnesota Immunization Information Connection (MIIC)
# =============================================================================

library(dplyr)

process <- dcf::dcf_process_record()

# -----------------------------------------------------------------------------
# 1. Download raw data (6 CSV files)
# -----------------------------------------------------------------------------
base_url <- "https://www.health.mn.gov/people/immunize/stats/gaps/"

files <- c(
  "childrates.csv",      # Early childhood (24 months) by county
  "childratesre.csv",    # Early childhood by race/ethnicity (statewide)
  "child2rates.csv",     # Middle childhood (6 years) by county
  "child2ratesre.csv",   # Middle childhood by race/ethnicity (statewide)
  "adolrates.csv",       # Adolescent (13 years) by county
  "adolratesre.csv"      # Adolescent by race/ethnicity (statewide)
)

for (f in files) {
  resp <- httr::GET(
    paste0(base_url, f),
    httr::user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
  )
  writeBin(httr::content(resp, "raw"), file.path("raw", f))
}

# Compute hash of all raw files for change detection
raw_hashes <- sapply(file.path("raw", files), tools::md5sum)
raw_state <- list(hashes = raw_hashes)

# Only process if data has changed
if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 2. Load FIPS lookup
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz", show_col_types = FALSE,
                           col_types = list(geography = "c"))

  # Minnesota county FIPS lookup: strip " County" suffix, uppercase for matching
  mn_county_fips <- all_fips %>%
    filter(nchar(geography) == 5, substr(geography, 1, 2) == "27") %>%
    select(geography, geography_name) %>%
    mutate(
      county_upper = toupper(sub(" County$", "", geography_name)),
      # Handle "St. Louis" -> "ST LOUIS" mismatch
      county_upper = gsub("\\.", "", county_upper)
    )

  # ---------------------------------------------------------------------------
  # 3. Read and transform county-level data
  # ---------------------------------------------------------------------------

  # --- Early childhood (24 months) ---
  ec <- vroom::vroom("raw/childrates.csv", show_col_types = FALSE) %>%
    rename(
      birth_year = BIRTH_YEAR,
      county_name = COUNTY_NAME,
      iis_infant_pop = POP,
      iis_infant_dtap_rate = DTAP4_RATE,
      iis_infant_mmr_rate = MMR1_RATE,
      iis_infant_hepb_rate = HEPBCOMP_RATE,
      iis_infant_hib_rate = HIBCOMP_RATE,
      iis_infant_ipv_rate = POLIO3_RATE,
      iis_infant_var_rate = VARICELLA1_RATE,
      iis_infant_pcv_rate = PCVCOMP_RATE,
      iis_infant_series_rate = CHILDSERIES_RATE
    ) %>%
    mutate(age = "infant")

  # --- Middle childhood (6 years) ---
  mc <- vroom::vroom("raw/child2rates.csv", show_col_types = FALSE) %>%
    rename(
      birth_year = BIRTH_YEAR,
      county_name = COUNTY_NAME,
      iis_child_pop = POP,
      iis_child_dtap_rate = DTAPCOMP_RATE,
      iis_child_mmr_rate = MMR2_RATE,
      iis_child_hepb_rate = HEPBCOMP_RATE,
      iis_child_ipv_rate = POLIOCOMP_RATE,
      iis_child_var_rate = VARICELLA2_RATE,
      iis_child_series_rate = CHILD2SERIES_RATE
    ) %>%
    mutate(age = "child")

  # --- Adolescent (13 years) ---
  ad <- vroom::vroom("raw/adolrates.csv", show_col_types = FALSE) %>%
    rename(
      birth_year = BIRTH_YEAR,
      county_name = COUNTY_NAME,
      iis_teen_pop = POP,
      iis_teen_hpv_initiated_rate = HPV1_RATE,
      iis_teen_hpv_rate = HPVCOMP_RATE,
      iis_teen_mcv4_rate = MENACWY1_RATE,
      iis_teen_tdap_rate = TDAP_RATE,
      iis_teen_series_rate = ADOLSERIES_RATE
    ) %>%
    mutate(age = "teen")

  # ---------------------------------------------------------------------------
  # 4. Convert geography: county names to FIPS codes
  # ---------------------------------------------------------------------------
  convert_geo <- function(df) {
    df %>%
      filter(toupper(county_name) != "NO ADDRESS") %>%
      mutate(county_upper = toupper(county_name)) %>%
      left_join(mn_county_fips, by = "county_upper") %>%
      mutate(
        geography = case_when(
          county_name == "Statewide" ~ "27",
          !is.na(geography) ~ as.character(geography),
          TRUE ~ NA_character_
        ),
        time = paste0(birth_year, "-12-31")
      ) %>%
      select(-county_name, -county_upper,
             -geography_name, -birth_year)
  }

  ec <- convert_geo(ec)
  mc <- convert_geo(mc)
  ad <- convert_geo(ad)

  # Combine all age groups (long by age, wide by vaccine)
  data_county <- bind_rows(ec, mc, ad) %>%
    select(geography, time, age, everything())

  # ---------------------------------------------------------------------------
  # 5. Read and transform race/ethnicity data (statewide only)
  # ---------------------------------------------------------------------------
  re_map <- c(
    "white" = "White",
    "black" = "Black",
    "hisp" = "Hispanic",
    "api" = "Asian",
    "aian" = "AIAN"
  )

  ec_re <- vroom::vroom("raw/childratesre.csv", show_col_types = FALSE) %>%
    rename(
      birth_year = BIRTH_YEAR,
      county_name = COUNTY_NAME,
      iis_infant_pop = POP,
      iis_infant_dtap_rate = DTAP4_RATE,
      iis_infant_mmr_rate = MMR1_RATE,
      iis_infant_hepb_rate = HEPBCOMP_RATE,
      iis_infant_hib_rate = HIBCOMP_RATE,
      iis_infant_ipv_rate = POLIO3_RATE,
      iis_infant_var_rate = VARICELLA1_RATE,
      iis_infant_pcv_rate = PCVCOMP_RATE,
      iis_infant_series_rate = CHILDSERIES_RATE,
      race_ethnicity = RE
    ) %>%
    mutate(age = "infant")

  mc_re <- vroom::vroom("raw/child2ratesre.csv", show_col_types = FALSE) %>%
    rename(
      birth_year = BIRTH_YEAR,
      county_name = COUNTY_NAME,
      iis_child_pop = POP,
      iis_child_dtap_rate = DTAPCOMP_RATE,
      iis_child_mmr_rate = MMR2_RATE,
      iis_child_hepb_rate = HEPBCOMP_RATE,
      iis_child_ipv_rate = POLIOCOMP_RATE,
      iis_child_var_rate = VARICELLA2_RATE,
      iis_child_series_rate = CHILD2SERIES_RATE,
      race_ethnicity = RE
    ) %>%
    mutate(age = "child")

  ad_re <- vroom::vroom("raw/adolratesre.csv", show_col_types = FALSE) %>%
    rename(
      birth_year = BIRTH_YEAR,
      county_name = COUNTY_NAME,
      iis_teen_pop = POP,
      iis_teen_hpv_initiated_rate = HPV1_RATE,
      iis_teen_hpv_rate = HPVCOMP_RATE,
      iis_teen_mcv4_rate = MENACWY1_RATE,
      iis_teen_tdap_rate = TDAP_RATE,
      iis_teen_series_rate = ADOLSERIES_RATE,
      race_ethnicity = RE
    ) %>%
    mutate(age = "teen")

  convert_geo_re <- function(df) {
    df %>%
      mutate(
        geography = "27",  # All race/ethnicity data is statewide
        time = paste0(birth_year, "-12-31"),
        race_ethnicity = recode(race_ethnicity, !!!re_map, .default = NA_character_)
      ) %>%
      filter(!is.na(race_ethnicity)) %>%
      select(-county_name, -birth_year)
  }

  ec_re <- convert_geo_re(ec_re)
  mc_re <- convert_geo_re(mc_re)
  ad_re <- convert_geo_re(ad_re)

  data_re <- bind_rows(ec_re, mc_re, ad_re) %>%
    select(geography, time, age, race_ethnicity, everything())

  # ---------------------------------------------------------------------------
  # 6. Write standardized output
  # ---------------------------------------------------------------------------
  vroom::vroom_write(data_county, "standard/data.csv.gz", delim = ",")
  vroom::vroom_write(data_re, "standard/data_race_ethnicity.csv.gz", delim = ",")

  # ---------------------------------------------------------------------------
  # 7. Update process record
  # ---------------------------------------------------------------------------
  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
