# =============================================================================
# California School Immunization Data Ingestion
# Source: CA Dept of Public Health (CDPH) via CHHS Open Data Portal
# https://data.chhs.ca.gov/dataset/school-immunizations-in-kindergarten-by-academic-year
# Data: School-level kindergarten immunization coverage, aggregated to county
# Geography: California counties (FIPS state 06)
# Time: School year end (June 30 of graduation year)
# =============================================================================

library(dplyr)

process <- dcf::dcf_process_record()

# -----------------------------------------------------------------------------
# 1. Define source files (one per multi-year bundle)
# -----------------------------------------------------------------------------
# All available files as of 2026-04; check CKAN for newer releases periodically
source_files <- list(
  list(
    url  = paste0(
      "https://data.chhs.ca.gov/dataset/bc38e725-9180-49e7-97e5-e16cb413a40c/",
      "resource/a269c0af-3fa7-4b27-8f5b-0bb0dcedfdd2/download/",
      "kindergarten_immunizations_academic_year_2019-20-to-2022-23.csv"
    ),
    dest = "raw/kinder_2019_2023.csv"
  ),
  list(
    url  = paste0(
      "https://data.chhs.ca.gov/dataset/bc38e725-9180-49e7-97e5-e16cb413a40c/",
      "resource/4319a7e8-5c63-460c-b412-c7474fd7da2a/download/",
      "iz_kindergarten2016-17_to_2018-19_school_year.csv"
    ),
    dest = "raw/kinder_2016_2019.csv"
  ),
  list(
    url  = paste0(
      "https://data.chhs.ca.gov/dataset/bc38e725-9180-49e7-97e5-e16cb413a40c/",
      "resource/b17f85b5-0cb3-4e33-971d-e9029203c08e/download/",
      "school-immunizations-in-kindergarten-by-academic-year-2013-2014-to-2015-16.csv"
    ),
    dest = "raw/kinder_2013_2016.csv"
  )
)

# Download all files
for (sf in source_files) {
  resp <- httr::GET(
    sf$url,
    httr::user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"),
    httr::timeout(300)
  )
  writeBin(httr::content(resp, "raw"), sf$dest)
}

raw_state <- list(
  hashes = sapply(sapply(source_files, `[[`, "dest"), tools::md5sum)
)

if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 2. Load FIPS lookup
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz",
                           show_col_types = FALSE,
                           col_types = list(geography = "c"))

  # California county FIPS: strip " County" suffix for matching
  ca_county_fips <- all_fips %>%
    filter(nchar(geography) == 5, substr(geography, 1, 2) == "06") %>%
    select(geography, geography_name) %>%
    mutate(county_name = sub(" County$", "", geography_name))

  # ---------------------------------------------------------------------------
  # 3. Load and stack all source files
  # ---------------------------------------------------------------------------
  data_raw <- lapply(source_files, function(sf) {
    vroom::vroom(sf$dest, show_col_types = FALSE,
                 col_types = vroom::cols(.default = "c"))
  }) %>%
    dplyr::bind_rows()

  # ---------------------------------------------------------------------------
  # 4. Transform: aggregate to county level by school year and vaccine
  # ---------------------------------------------------------------------------
  # Vaccine categories to retain
  vax_categories <- c("DTP", "HEPB", "MMR2", "POLIO", "VARI", "UP-TO-DATE")

  # Column name mapping
  vax_col_map <- c(
    "DTP"       = "iis_child_dtap_rate",
    "HEPB"      = "iis_child_hepb_rate",
    "MMR2"      = "iis_child_mmr_rate",
    "POLIO"     = "iis_child_ipv_rate",
    "VARI"      = "iis_child_var_rate",
    "UP-TO-DATE"= "iis_child_utd_rate"
  )

  data_county <- data_raw %>%
    filter(
      CATEGORY %in% vax_categories,
      REPORTED == "Y",
      !is.na(ENROLLMENT), ENROLLMENT != "",
      !is.na(COUNT),      COUNT != ""
    ) %>%
    mutate(
      enrollment = as.numeric(gsub(",", "", ENROLLMENT)),
      count_vac  = as.numeric(gsub(",", "", COUNT))
    ) %>%
    filter(!is.na(enrollment), !is.na(count_vac), enrollment > 0) %>%
    group_by(SCHOOL_YEAR, COUNTY, CATEGORY) %>%
    summarize(
      enrollment = sum(enrollment, na.rm = TRUE),
      count_vac  = sum(count_vac,  na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      rate = 100 * count_vac / enrollment,
      col_name = vax_col_map[CATEGORY]
    ) %>%
    filter(!is.na(col_name)) %>%
    # Map school year "2022-23" → time "2023-06-30"
    mutate(
      year_end = as.integer(paste0("20", sub(".*-", "", SCHOOL_YEAR))),
      time = paste0(year_end, "-06-30")
    ) %>%
    left_join(ca_county_fips, by = c("COUNTY" = "county_name")) %>%
    filter(!is.na(geography)) %>%
    select(geography, time, col_name, rate, enrollment) %>%
    tidyr::pivot_wider(
      names_from  = col_name,
      values_from = rate
    )

  # Add statewide aggregate (enrollment-weighted mean)
  state_agg <- data_raw %>%
    filter(
      CATEGORY %in% vax_categories,
      REPORTED == "Y",
      !is.na(ENROLLMENT), ENROLLMENT != "",
      !is.na(COUNT),      COUNT != ""
    ) %>%
    mutate(
      enrollment = as.numeric(gsub(",", "", ENROLLMENT)),
      count_vac  = as.numeric(gsub(",", "", COUNT))
    ) %>%
    filter(!is.na(enrollment), !is.na(count_vac), enrollment > 0) %>%
    group_by(SCHOOL_YEAR, CATEGORY) %>%
    summarize(
      enrollment = sum(enrollment, na.rm = TRUE),
      count_vac  = sum(count_vac,  na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      rate = 100 * count_vac / enrollment,
      col_name = vax_col_map[CATEGORY],
      year_end = as.integer(paste0("20", sub(".*-", "", SCHOOL_YEAR))),
      time = paste0(year_end, "-06-30"),
      geography = "06"
    ) %>%
    filter(!is.na(col_name)) %>%
    select(geography, time, col_name, rate, enrollment) %>%
    tidyr::pivot_wider(names_from = col_name, values_from = rate)

  data_final <- bind_rows(data_county, state_agg) %>%
    select(geography, time, enrollment, everything()) %>%
    arrange(geography, time)

  # ---------------------------------------------------------------------------
  # 5. Write standardized output
  # ---------------------------------------------------------------------------
  vroom::vroom_write(data_final, "standard/data.csv.gz", delim = ",")

  # ---------------------------------------------------------------------------
  # 6. Update process record
  # ---------------------------------------------------------------------------
  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
