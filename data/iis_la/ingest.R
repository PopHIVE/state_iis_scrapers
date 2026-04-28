# =============================================================================
# Louisiana IIS Data Ingestion
# Source: Louisiana Dept of Health (LDH) — LINKS Immunization Registry
# Dashboard: https://analytics.la.gov/t/LDH/views/SchoolImmunizationDashboard/Kindergarten
# Data: Parish-level kindergarten immunization compliance data
# Note: analytics.la.gov is a Tableau Server. CSV export requires establishing
#       a session via an initial page load. Try multiple view name patterns if
#       one returns 404. Server may have temporary outages.
# =============================================================================

library(dplyr)

process <- dcf::dcf_process_record()

tableau_server <- "https://analytics.la.gov"
site           <- "LDH"
workbook       <- "SchoolImmunizationDashboard"

# Try multiple view names — the correct one depends on the workbook configuration
candidate_views <- c("Kindergarten", "Parish", "Home", "Summary", "County",
                     "Map", "Coverage", "KindergartenParish")

# -----------------------------------------------------------------------------
# 1. Bootstrap Tableau session via initial page load
# -----------------------------------------------------------------------------
viz_url <- sprintf("%s/t/%s/views/%s/%s",
                   tableau_server, site, workbook, candidate_views[1])

sess_resp <- httr::GET(
  viz_url,
  httr::user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"),
  httr::add_headers("Accept" = "text/html,*/*"),
  httr::timeout(60)
)

all_cookies  <- httr::cookies(sess_resp)
session_cookies <- setNames(all_cookies$value, all_cookies$name)
xsrf_token   <- session_cookies[["XSRF-TOKEN"]]
xsrf_header  <- if (!is.null(xsrf_token) && nchar(xsrf_token) > 0) {
  httr::add_headers("X-XSRF-TOKEN" = xsrf_token)
} else {
  NULL
}

# -----------------------------------------------------------------------------
# 2. Try each view name until one returns CSV data
# -----------------------------------------------------------------------------
raw_bytes <- NULL
used_view <- NULL

for (view_name in candidate_views) {
  csv_url <- sprintf("%s/t/%s/views/%s/%s.csv",
                     tableau_server, site, workbook, view_name)

  resp <- httr::GET(
    csv_url,
    httr::user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"),
    httr::set_cookies(.cookies = session_cookies),
    xsrf_header,
    httr::add_headers("Referer" = viz_url, "Accept" = "text/csv,*/*"),
    httr::timeout(60)
  )

  if (httr::status_code(resp) == 200) {
    candidate_bytes <- httr::content(resp, "raw")
    if (length(candidate_bytes) > 100) {  # non-empty
      raw_bytes  <- candidate_bytes
      used_view  <- view_name
      message("Louisiana: found data with view name '", view_name, "'")
      break
    }
  }
}

if (is.null(raw_bytes)) {
  stop(
    "Louisiana: no view returned CSV data. Tried: ",
    paste(candidate_views, collapse = ", "),
    ". The Tableau server may require re-authentication, the workbook/view names ",
    "may have changed, or CSV export may be disabled. ",
    "Check the dashboard at: ", viz_url
  )
}

writeBin(raw_bytes, "raw/kindergarten_parish.csv")
raw_state <- list(hash = tools::md5sum("raw/kindergarten_parish.csv"))

if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 3. Load FIPS lookup (Louisiana parishes)
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz",
                           show_col_types = FALSE,
                           col_types = list(geography = "c"))

  la_parish_fips <- all_fips %>%
    filter(nchar(geography) == 5, substr(geography, 1, 2) == "22") %>%
    select(geography, geography_name) %>%
    mutate(
      # Strip " Parish" suffix for matching (LA equivalents of counties)
      parish_name = sub(" Parish$", "", geography_name)
    )

  # ---------------------------------------------------------------------------
  # 4. Read and inspect the CSV
  # ---------------------------------------------------------------------------
  data_raw <- vroom::vroom(
    "raw/kindergarten_parish.csv",
    show_col_types = FALSE,
    col_types = vroom::cols(.default = "c")
  )

  message("Louisiana CSV columns (view '", used_view, "'): ",
          paste(names(data_raw), collapse = ", "))

  # ---------------------------------------------------------------------------
  # 5. Map columns to standard outputs
  #    Column names depend on dashboard configuration. Common patterns:
  #      Parish name: "Parish", "PARISH", "parish_name"
  #      School year: "School Year", "Year"
  #      Vaccination rate: "% Vaccinated", "Coverage", "Rate"
  #      Vaccine type:     "Vaccine", "Antigen"
  # ---------------------------------------------------------------------------

  parish_col <- intersect(
    c("Parish", "PARISH", "parish_name", "Parish Name",
      "Geography", "Location"),
    names(data_raw)
  )[1]
  if (is.na(parish_col)) parish_col <- names(data_raw)[1]

  year_col <- intersect(
    c("School Year", "Year", "YEAR", "School_Year", "survey_year"),
    names(data_raw)
  )[1]

  rate_col <- grep("(?i)percent|coverage|rate|vaccin|pct",
                   names(data_raw), value = TRUE, perl = TRUE)[1]

  vaccine_col <- grep("(?i)vaccine|antigen|type|measure",
                      names(data_raw), value = TRUE, perl = TRUE)[1]

  if (is.na(rate_col)) {
    stop("Louisiana: could not identify vaccination rate column. ",
         "Columns: ", paste(names(data_raw), collapse = ", "))
  }

  # Determine time value
  if (!is.na(year_col) && !all(is.na(data_raw[[year_col]]))) {
    raw_year <- max(data_raw[[year_col]], na.rm = TRUE)
    # School year like "2024-25" → end date 2025-06-30
    year_end <- regmatches(raw_year, regexpr("[0-9]{4}$", raw_year))
    if (length(year_end) == 0 || nchar(year_end) != 4) {
      year_end <- regmatches(raw_year, regexpr("^[0-9]{4}", raw_year))
    }
    time_val <- if (length(year_end) == 1 && nchar(year_end) == 4) {
      paste0(year_end, "-06-30")
    } else {
      paste0(format(Sys.Date(), "%Y"), "-06-30")
    }
  } else {
    time_val <- paste0(format(Sys.Date(), "%Y"), "-06-30")
  }

  # ---------------------------------------------------------------------------
  # 6. Pivot or select rate data by vaccine if multi-vaccine layout
  # ---------------------------------------------------------------------------
  data_work <- data_raw %>%
    rename(parish_raw = !!parish_col) %>%
    mutate(
      parish_name = trimws(parish_raw),
      rate_val    = as.numeric(gsub("[%,]", "", .data[[rate_col]]))
    ) %>%
    filter(!is.na(parish_name), nchar(parish_name) > 0)

  if (!is.na(vaccine_col)) {
    # Multi-vaccine tall layout — pivot to wide
    data_wide <- data_work %>%
      mutate(
        col_name = case_when(
          grepl("(?i)dtap|dtp|diphther", .data[[vaccine_col]], perl = TRUE) ~ "iis_child_dtap_rate",
          grepl("(?i)mmr|measles",       .data[[vaccine_col]], perl = TRUE) ~ "iis_child_mmr_rate",
          grepl("(?i)polio|ipv",         .data[[vaccine_col]], perl = TRUE) ~ "iis_child_ipv_rate",
          grepl("(?i)varicella|var",     .data[[vaccine_col]], perl = TRUE) ~ "iis_child_var_rate",
          grepl("(?i)hep.*b|hepat.*b",   .data[[vaccine_col]], perl = TRUE) ~ "iis_child_hepb_rate",
          grepl("(?i)hep.*a|hepat.*a",   .data[[vaccine_col]], perl = TRUE) ~ "iis_child_hepa_rate",
          grepl("(?i)hib",               .data[[vaccine_col]], perl = TRUE) ~ "iis_child_hib_rate",
          grepl("(?i)series|utd|up.*to.*date|complete",
                                         .data[[vaccine_col]], perl = TRUE) ~ "iis_child_series_rate",
          TRUE ~ paste0("iis_", tolower(gsub("[^a-z0-9]", "_",
                        trimws(.data[[vaccine_col]]))))
        )
      ) %>%
      select(parish_name, col_name, rate_val) %>%
      tidyr::pivot_wider(names_from = col_name, values_from = rate_val,
                         values_fn = mean)
  } else {
    # Single-rate layout (one rate per row)
    data_wide <- data_work %>%
      mutate(iis_child_series_rate = rate_val) %>%
      select(parish_name, iis_child_series_rate) %>%
      distinct()
  }

  # ---------------------------------------------------------------------------
  # 7. Join to FIPS and finalize
  # ---------------------------------------------------------------------------
  rate_cols <- setdiff(names(data_wide), "parish_name")

  data_standard <- data_wide %>%
    left_join(la_parish_fips, by = "parish_name") %>%
    mutate(
      geography = case_when(
        grepl("(?i)state|louisiana|overall", parish_name, perl = TRUE) ~ "22",
        !is.na(geography) ~ geography,
        TRUE ~ NA_character_
      ),
      time = time_val
    ) %>%
    filter(!is.na(geography)) %>%
    select(geography, time, all_of(rate_cols))

  # Add statewide row if not present
  if (!"22" %in% data_standard$geography) {
    state_row <- data_standard %>%
      summarize(across(all_of(rate_cols), ~ mean(.x, na.rm = TRUE))) %>%
      mutate(geography = "22", time = time_val)
    data_standard <- bind_rows(data_standard, state_row)
  }

  # ---------------------------------------------------------------------------
  # 8. Write standardized output
  # ---------------------------------------------------------------------------
  vroom::vroom_write(data_standard, "standard/data.csv.gz", delim = ",")

  # ---------------------------------------------------------------------------
  # 9. Update process record
  # ---------------------------------------------------------------------------
  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
