# =============================================================================
# Illinois IIS Data Ingestion
# Source: Illinois DPH - I-CARE Immunization Registry
# Tableau dashboards: https://public.data.illinois.gov/t/Public/views/
# Data: County-level influenza vaccination coverage (current season)
# Note: The Tableau CSV export provides a snapshot of the current season;
#       the `time` column reflects the end of the current flu season.
# =============================================================================

library(dplyr)

process <- dcf::dcf_process_record()

# -----------------------------------------------------------------------------
# 1. Download county flu vaccination data from IL Tableau Server
# -----------------------------------------------------------------------------
flu_url <- paste0(
  "https://public.data.illinois.gov/t/Public/views/",
  "InfluenzaVaccinationCoverage_Public/Home.csv"
)

resp <- httr::GET(
  flu_url,
  httr::user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"),
  httr::add_headers(
    "Referer" = "https://public.data.illinois.gov/",
    "Accept"  = "text/csv,*/*"
  ),
  httr::timeout(60)
)
writeBin(httr::content(resp, "raw"), "raw/flu_county.csv")

raw_state <- list(hash = tools::md5sum("raw/flu_county.csv"))

if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 2. Load FIPS lookup
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz",
                           show_col_types = FALSE,
                           col_types = list(geography = "c"))

  # Illinois county FIPS: strip " County" suffix, uppercase for matching
  il_county_fips <- all_fips %>%
    filter(nchar(geography) == 5, substr(geography, 1, 2) == "17") %>%
    select(geography, geography_name) %>%
    mutate(county_upper = toupper(sub(" County$", "", geography_name)))

  # ---------------------------------------------------------------------------
  # 3. Compute season end date (dashboard shows current flu season)
  #    Flu season: Aug-May. If current month >= 8, season ends next year.
  # ---------------------------------------------------------------------------
  current_month <- as.integer(format(Sys.Date(), "%m"))
  current_year  <- as.integer(format(Sys.Date(), "%Y"))
  season_end_year <- if (current_month >= 8) current_year + 1 else current_year
  time_val <- paste0(season_end_year, "-05-31")

  # ---------------------------------------------------------------------------
  # 4. Read and parse county flu data
  # ---------------------------------------------------------------------------
  # Tableau CSV columns (from export):
  #   "Count Value", "ILCounty", "State",
  #   "Flu Vaccination Coverage (%) (County)",
  #   "Number of influenza vaccines administered",
  #   "Suppression label (if applicable)",
  #   "Latitude (generated)", "Longitude (generated)",
  #   "Population (Dem Counts POP) (GT POP DEC County1)"

  data_raw <- vroom::vroom(
    "raw/flu_county.csv",
    show_col_types = FALSE,
    col_types = vroom::cols(.default = "c")
  )

  # Rename to workable names (column positions are stable in Tableau CSV export)
  names(data_raw) <- c(
    "count_value", "county_name", "state",
    "flu_pct", "flu_count", "suppression",
    "latitude", "longitude", "population"
  )

  data_standard <- data_raw %>%
    # Exclude rows without county name (totals/headers)
    filter(!is.na(county_name), nchar(trimws(county_name)) > 0) %>%
    mutate(
      county_upper = toupper(trimws(county_name)),
      # Clean percentage: "24.0%" → 24.0
      iis_flu_rate = as.numeric(gsub("%", "", flu_pct)),
      # Clean count: "15,456" → 15456
      iis_flu_count = as.numeric(gsub(",", "", flu_count)),
      # Clean population: "64,441" → 64441
      iis_flu_pop   = as.numeric(gsub(",", "", population)),
      suppressed_flag = if_else(!is.na(suppression) & nchar(trimws(suppression)) > 0, 1L, 0L)
    ) %>%
    left_join(il_county_fips, by = "county_upper") %>%
    filter(!is.na(geography)) %>%
    mutate(time = time_val) %>%
    select(geography, time,
           iis_flu_rate, iis_flu_count, iis_flu_pop, suppressed_flag)

  # Add statewide row (population-weighted mean)
  state_row <- data_standard %>%
    summarize(
      iis_flu_rate  = weighted.mean(iis_flu_rate, iis_flu_pop, na.rm = TRUE),
      iis_flu_count = sum(iis_flu_count, na.rm = TRUE),
      iis_flu_pop   = sum(iis_flu_pop, na.rm = TRUE),
      suppressed_flag = 0L
    ) %>%
    mutate(geography = "17", time = time_val)

  data_final <- bind_rows(data_standard, state_row) %>%
    select(geography, time, iis_flu_rate, iis_flu_count, iis_flu_pop, suppressed_flag)

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
