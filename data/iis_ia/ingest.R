# =============================================================================
# Iowa IIS Data Ingestion
# Source: Iowa HHS / Iowa IDPH - IRIS (Immunization Registry Information System)
# Dashboard: https://data.idph.state.ia.us/t/IDPH-DataViz/views/Immunization2yearold/Map
# Data: County-level immunization rates for 2-year-old children
# Vaccines: DTaP (4 doses), Polio (3), MMR (1), Hib (3), HepB (3), Varicella (1),
#           PCV (4), and the 4:3:1:3:3:1:4 combined series
# Note: The Tableau server uses a self-signed SSL certificate (ssl_verifypeer = FALSE).
#       An initial GET to the viz page is required to establish a session cookie;
#       the CSV export endpoint returns empty content without a valid session.
# =============================================================================

library(dplyr)

process <- dcf::dcf_process_record()

tableau_base  <- "https://data.idph.state.ia.us/t/IDPH-DataViz/views"
viz_url       <- paste0(tableau_base, "/Immunization2yearold/Map")
csv_url       <- paste0(tableau_base, "/Immunization2yearold/Map.csv")

# -----------------------------------------------------------------------------
# 1. Bootstrap Tableau session, then download CSV
# -----------------------------------------------------------------------------
# Step 1: GET the viz page to get session cookie (SSL bypass required)
sess_resp <- httr::GET(
  viz_url,
  httr::user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"),
  httr::config(ssl_verifypeer = FALSE),
  httr::timeout(60)
)

# Extract all cookies set by the server
all_cookies <- httr::cookies(sess_resp)
session_cookies <- setNames(all_cookies$value, all_cookies$name)

# Extract XSRF token for header (may be absent on anonymous servers)
xsrf_token <- session_cookies["XSRF-TOKEN"]  # single bracket returns NA if missing
extra_headers <- if (!is.na(xsrf_token) && nchar(xsrf_token) > 0) {
  httr::add_headers("X-XSRF-TOKEN" = xsrf_token)
} else {
  NULL
}

# Step 2: Fetch CSV with session cookies
resp <- httr::GET(
  csv_url,
  httr::user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"),
  httr::config(ssl_verifypeer = FALSE),
  httr::set_cookies(.cookies = session_cookies),
  extra_headers,
  httr::add_headers(
    "Referer" = viz_url,
    "Accept"  = "text/csv,*/*"
  ),
  httr::timeout(60)
)

if (httr::status_code(resp) != 200) {
  stop("Iowa Tableau CSV returned status: ", httr::status_code(resp))
}

raw_bytes <- httr::content(resp, "raw")
if (length(raw_bytes) == 0) {
  stop("Iowa Tableau CSV returned empty response — session auth may have changed.")
}

writeBin(raw_bytes, "raw/immunization_2yr_county.csv")

raw_state <- list(hash = tools::md5sum("raw/immunization_2yr_county.csv"))

if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 2. Load FIPS lookup (Iowa counties)
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz",
                           show_col_types = FALSE,
                           col_types = list(geography = "c"))

  ia_county_fips <- all_fips %>%
    filter(nchar(geography) == 5, substr(geography, 1, 2) == "19") %>%
    select(geography, geography_name) %>%
    mutate(county_name = sub(" County$", "", geography_name))

  # ---------------------------------------------------------------------------
  # 3. Read and inspect the CSV
  # ---------------------------------------------------------------------------
  data_raw <- vroom::vroom(
    "raw/immunization_2yr_county.csv",
    show_col_types = FALSE,
    col_types = vroom::cols(.default = "c")
  )

  # Log column names to assist with future maintenance
  message("Iowa Tableau CSV columns: ", paste(names(data_raw), collapse = ", "))

  # ---------------------------------------------------------------------------
  # 4. Map column names to standard outputs
  #
  # The Tableau Map view CSV column names are determined by the dashboard
  # configuration. Common patterns observed in Iowa's IRIS dashboards:
  #   County name:         "County Name", "COUNTY", "County"
  #   Series completion:   "4:3:1:3:3:1:4 Series", "Combo Series", "Series Rate"
  #   Individual vaccines: "DTaP Rate", "Polio Rate", etc.
  #
  # This section uses flexible name matching. Verify column names on first run
  # by checking the message logged above.
  # ---------------------------------------------------------------------------
  col_map <- list()

  # County name column (try several patterns)
  county_col <- intersect(
    c("County Name", "County", "COUNTY", "county_name", "GeoName"),
    names(data_raw)
  )[1]
  if (is.na(county_col)) {
    # Fall back to first column if no match
    county_col <- names(data_raw)[1]
    message("County column not found by name; using first column: ", county_col)
  }

  # Series completion rate
  series_col <- grep("(?i)4:3:1|series|combo", names(data_raw), value = TRUE,
                     perl = TRUE)[1]
  if (!is.na(series_col)) col_map[[series_col]] <- "iis_infant_series_rate"

  # Individual vaccines (flexible matching)
  vax_patterns <- list(
    "(?i)dtap|dtp"      = "iis_infant_dtap_rate",
    "(?i)polio|ipv"     = "iis_infant_ipv_rate",
    "(?i)mmr"           = "iis_infant_mmr_rate",
    "(?i)hib"           = "iis_infant_hib_rate",
    "(?i)hep.*b|hepat.*b" = "iis_infant_hepb_rate",
    "(?i)varicella|var" = "iis_infant_var_rate",
    "(?i)pcv|pneumo"    = "iis_infant_pcv_rate"
  )
  for (pat in names(vax_patterns)) {
    matched <- grep(pat, names(data_raw), value = TRUE, perl = TRUE)
    # Skip if already mapped (e.g. "series" matching "dtap series")
    matched <- matched[!matched %in% names(col_map)]
    if (length(matched) > 0 && !vax_patterns[[pat]] %in% unlist(col_map)) {
      col_map[[matched[1]]] <- vax_patterns[[pat]]
    }
  }

  if (length(col_map) == 0) {
    stop("Could not identify any vaccine rate columns. ",
         "Check CSV columns: ", paste(names(data_raw), collapse = ", "))
  }

  # ---------------------------------------------------------------------------
  # 5. Compute time value
  #    Iowa reports by birth year cohort (children turning 2 in year X).
  #    If a "Year" column exists use it; otherwise use current year.
  # ---------------------------------------------------------------------------
  year_col <- grep("(?i)^year$|survey.*year|birth.*year", names(data_raw),
                   value = TRUE, perl = TRUE)[1]
  if (!is.na(year_col) && !all(is.na(data_raw[[year_col]]))) {
    survey_year <- as.integer(max(data_raw[[year_col]], na.rm = TRUE))
  } else {
    survey_year <- as.integer(format(Sys.Date(), "%Y"))
  }
  time_val <- paste0(survey_year, "-12-31")

  # ---------------------------------------------------------------------------
  # 6. Transform data
  # ---------------------------------------------------------------------------
  data_standard <- data_raw %>%
    rename(county_raw = !!county_col) %>%
    mutate(county_name = trimws(county_raw)) %>%
    filter(!is.na(county_name), nchar(county_name) > 0) %>%
    left_join(ia_county_fips, by = "county_name") %>%
    mutate(
      geography = case_when(
        grepl("(?i)statewide|overall|iowa", county_name, perl = TRUE) ~ "19",
        !is.na(geography) ~ geography,
        TRUE ~ NA_character_
      ),
      time = time_val
    ) %>%
    filter(!is.na(geography))

  # Rename vaccine rate columns and convert to numeric
  for (src_col in names(col_map)) {
    out_col <- col_map[[src_col]]
    data_standard[[out_col]] <- as.numeric(
      gsub("[%,]", "", data_standard[[src_col]])
    )
  }

  output_cols <- c("geography", "time", unname(unlist(col_map)))
  data_final <- data_standard %>%
    select(any_of(output_cols))

  # Add statewide row if not present
  if (!"19" %in% data_final$geography) {
    # Use data if available; otherwise skip
    message("No statewide row found in Iowa CSV; skipping statewide aggregate.")
  }

  # ---------------------------------------------------------------------------
  # 7. Write standardized output
  # ---------------------------------------------------------------------------
  vroom::vroom_write(data_final, "standard/data.csv.gz", delim = ",")

  # ---------------------------------------------------------------------------
  # 8. Update process record
  # ---------------------------------------------------------------------------
  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
