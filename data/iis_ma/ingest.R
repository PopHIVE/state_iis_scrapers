# =============================================================================
# Massachusetts IIS Data Ingestion
# Source: MA DPH - Respiratory Diseases Immunizations Dashboard (Tableau Server)
# https://datavisualization.dph.mass.gov/views/MDPHRespiratoryDiseasesImmunizationsDashboard/
# Data: County-level influenza (and potentially COVID/RSV) vaccination rates
#       for the current respiratory season; updated weekly
# =============================================================================

library(dplyr)

process <- dcf::dcf_process_record()

# -----------------------------------------------------------------------------
# 1. Download county-level CSV from MA Tableau Server
# -----------------------------------------------------------------------------
county_url <- paste0(
  "https://datavisualization.dph.mass.gov/views/",
  "MDPHRespiratoryDiseasesImmunizationsDashboard/County.csv"
)

resp <- httr::GET(
  county_url,
  httr::user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"),
  httr::add_headers(
    "Referer" = "https://datavisualization.dph.mass.gov/",
    "Accept"  = "text/csv,*/*"
  ),
  httr::timeout(60)
)
writeBin(httr::content(resp, "raw"), "raw/county.csv")

raw_state <- list(hash = tools::md5sum("raw/county.csv"))

if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 2. Load FIPS lookup
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz",
                           show_col_types = FALSE,
                           col_types = list(geography = "c"))

  # Massachusetts county FIPS: strip " County" suffix for matching
  ma_county_fips <- all_fips %>%
    filter(nchar(geography) == 5, substr(geography, 1, 2) == "25") %>%
    select(geography, geography_name) %>%
    mutate(county_name = sub(" County$", "", geography_name))

  # ---------------------------------------------------------------------------
  # 3. Read and parse county data
  # ---------------------------------------------------------------------------
  # Column names from Tableau export (non-standard names):
  #   "% suffix", "County", "End Date (Extract1)", "Season (Extract1)",
  #   "Start Date (Extract1)", "Type of vaccine lower case (extract 1)",
  #   "Vax vs Immunized", "Geometry", "Latitude (generated)",
  #   "Longitude (generated)", "Percent or number by town (n)"

  data_raw <- vroom::vroom("raw/county.csv", show_col_types = FALSE)

  # Rename columns to workable names
  names(data_raw) <- c(
    "pct_suffix", "county_name", "end_date", "season",
    "start_date", "vaccine_type", "vax_category",
    "geometry", "latitude", "longitude", "rate"
  )

  data_standard <- data_raw %>%
    # Join to get FIPS codes
    left_join(ma_county_fips, by = "county_name") %>%
    # Add statewide row
    bind_rows(
      data_raw %>%
        group_by(end_date, season, vaccine_type, vax_category) %>%
        summarize(rate = mean(rate, na.rm = TRUE), .groups = "drop") %>%
        mutate(geography = "25", county_name = "Massachusetts")
    ) %>%
    mutate(
      time = format(as.Date(end_date, "%m/%d/%Y"), "%Y-%m-%d"),
      # Map vaccine type to standard column name
      col_name = case_when(
        tolower(vaccine_type) == "influenza" ~ "iis_flu_rate",
        tolower(vaccine_type) == "covid"     ~ "iis_covid_rate",
        tolower(vaccine_type) == "rsv"       ~ "iis_rsv_rate",
        TRUE ~ paste0("iis_", tolower(gsub(" ", "_", vaccine_type)), "_rate")
      )
    ) %>%
    filter(!is.na(geography), !is.na(time)) %>%
    select(geography, time, season, col_name, rate) %>%
    tidyr::pivot_wider(names_from = col_name, values_from = rate) %>%
    select(geography, time, season, everything())

  # ---------------------------------------------------------------------------
  # 4. Write standardized output
  # ---------------------------------------------------------------------------
  vroom::vroom_write(data_standard, "standard/data.csv.gz", delim = ",")

  # ---------------------------------------------------------------------------
  # 5. Update process record
  # ---------------------------------------------------------------------------
  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
