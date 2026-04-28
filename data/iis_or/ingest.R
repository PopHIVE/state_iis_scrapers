# =============================================================================
# Oregon IIS Data Ingestion
# Sources:
#   1. OHA School Immunization Rates (K-12 + Preschool/Child Care) — Excel
#      K-12:      https://www.oregon.gov/oha/PH/.../Documents/SchK-12.xlsx
#      Preschool: https://www.oregon.gov/oha/PH/.../Documents/SchPreschool.xlsx
#   2. OHA Early Childhood (2-year-old) Immunization Rates — ALERT IIS via Tableau Public
#      Dashboard: https://public.tableau.com/app/profile/oregon.immunization.program/viz/OregonEarlyChildhoodImmunizationRates/StatewideDashboard
# Updated: Annually (school files overwrite the same URL each fall)
# Note: Tableau CSV export requires a session GET first to establish cookies.
#       Column names are matched flexibly; check logged names on first run.
# =============================================================================

library(dplyr)

process <- dcf::dcf_process_record()

base_url <- paste0(
  "https://www.oregon.gov/oha/PH/PREVENTIONWELLNESS/VACCINESIMMUNIZATION/",
  "GETTINGIMMUNIZED/Documents/"
)
k12_url       <- paste0(base_url, "SchK-12.xlsx")
preschool_url <- paste0(base_url, "SchPreschool.xlsx")

# =============================================================================
# PART 1 & 2: School immunization rates (K-12 and Preschool)
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Download school Excel files
# -----------------------------------------------------------------------------
download.file(k12_url,       "raw/SchK-12.xlsx",       mode = "wb", quiet = TRUE)
download.file(preschool_url, "raw/SchPreschool.xlsx",  mode = "wb", quiet = TRUE)

raw_state <- list(
  k12_hash       = tools::md5sum("raw/SchK-12.xlsx"),
  preschool_hash = tools::md5sum("raw/SchPreschool.xlsx")
)

if (!identical(process$raw_state, raw_state)) {

  # ---------------------------------------------------------------------------
  # 2. Load FIPS lookup (Oregon counties)
  # ---------------------------------------------------------------------------
  all_fips <- vroom::vroom("../../resources/all_fips.csv.gz",
                           show_col_types = FALSE,
                           col_types = list(geography = "c"))

  or_county_fips <- all_fips %>%
    filter(nchar(geography) == 5, substr(geography, 1, 2) == "41") %>%
    select(geography, geography_name) %>%
    mutate(county_name = sub(" County$", "", geography_name))

  # ---------------------------------------------------------------------------
  # 3. Helper: read OHA school immunization Excel file
  # ---------------------------------------------------------------------------
  read_oha_school <- function(path) {
    sheet_name <- readxl::excel_sheets(path)[1]

    year_match <- regmatches(sheet_name, regexpr("[0-9]{4}", sheet_name))
    school_year_end <- if (length(year_match) == 1) {
      paste0(year_match, "-06-30")
    } else {
      paste0(format(Sys.Date(), "%Y"), "-06-30")
    }

    df <- readxl::read_excel(path, sheet = sheet_name, col_names = TRUE,
                             col_types = "text", .name_repair = "minimal")
    df <- df %>%
      filter(!is.na(Agency), nchar(trimws(Agency)) > 0)

    count_cols <- grep("^#", names(df), value = TRUE)
    df <- df %>%
      mutate(across(all_of(count_cols), ~ as.numeric(gsub(",", "", .x))))

    list(data = df, time = school_year_end)
  }

  enroll_col <- "# Documentation Required (Adjusted Enrollment)"

  # ---------------------------------------------------------------------------
  # 4. Process K-12 data
  # ---------------------------------------------------------------------------
  k12_obj  <- read_oha_school("raw/SchK-12.xlsx")
  k12_df   <- k12_obj$data
  k12_time <- k12_obj$time

  k12_pairs <- list(
    "# Vaccinated: DTaP/Tdap"            = "iis_child_dtap_rate",
    "# Vaccinated: Polio"                = "iis_child_ipv_rate",
    "# Vaccinated: Varicella"            = "iis_child_var_rate",
    "# Vaccinated: MMR2"                 = "iis_child_mmr_rate",
    "# Vaccinated: HepB"                 = "iis_child_hepb_rate",
    "# Vaccinated: HepA"                 = "iis_child_hepa_rate",
    "# With All Vaccines Required"       = "iis_child_series_rate"
  )
  k12_pairs <- k12_pairs[names(k12_pairs) %in% names(k12_df)]

  k12_data <- k12_df %>%
    mutate(enrollment = as.numeric(.[[enroll_col]])) %>%
    filter(!is.na(enrollment), enrollment > 0) %>%
    group_by(county_name = Agency) %>%
    summarize(
      enrollment = sum(enrollment, na.rm = TRUE),
      across(all_of(names(k12_pairs)), ~ sum(as.numeric(.x), na.rm = TRUE)),
      .groups = "drop"
    ) %>%
    left_join(or_county_fips, by = "county_name") %>%
    filter(!is.na(geography)) %>%
    mutate(time = k12_time)

  for (cnt_col in names(k12_pairs)) {
    out_col <- k12_pairs[[cnt_col]]
    k12_data[[out_col]] <- round(k12_data[[cnt_col]] / k12_data$enrollment * 100, 1)
  }

  k12_state <- k12_data %>%
    summarize(
      enrollment = sum(enrollment),
      across(all_of(names(k12_pairs)), sum),
      geography = "41",
      time = k12_time
    )
  for (cnt_col in names(k12_pairs)) {
    out_col <- k12_pairs[[cnt_col]]
    k12_state[[out_col]] <- round(k12_state[[cnt_col]] / k12_state$enrollment * 100, 1)
  }

  output_cols_k12 <- c("geography", "time", unname(unlist(k12_pairs)))
  k12_standard <- bind_rows(k12_data[output_cols_k12], k12_state[output_cols_k12])

  # ---------------------------------------------------------------------------
  # 5. Process Preschool data
  # ---------------------------------------------------------------------------
  ps_obj  <- read_oha_school("raw/SchPreschool.xlsx")
  ps_df   <- ps_obj$data
  ps_time <- ps_obj$time

  ps_pairs <- list(
    "# Vaccinated: DTaP/Tdap"       = "iis_infant_dtap_rate",
    "# Vaccinated: Polio"           = "iis_infant_ipv_rate",
    "# Vaccinated: Varicella"       = "iis_infant_var_rate",
    "# Vaccinated: MMR1"            = "iis_infant_mmr_rate",
    "# Vaccinated: HepB"            = "iis_infant_hepb_rate",
    "# Vaccinated: HepA"            = "iis_infant_hepa_rate",
    "# Vaccinated: Hib"             = "iis_infant_hib_rate",
    "# With All Vaccines Required"  = "iis_infant_series_rate"
  )
  ps_pairs <- ps_pairs[names(ps_pairs) %in% names(ps_df)]

  ps_data <- ps_df %>%
    mutate(enrollment = as.numeric(.[[enroll_col]])) %>%
    filter(!is.na(enrollment), enrollment > 0) %>%
    group_by(county_name = Agency) %>%
    summarize(
      enrollment = sum(enrollment, na.rm = TRUE),
      across(all_of(names(ps_pairs)), ~ sum(as.numeric(.x), na.rm = TRUE)),
      .groups = "drop"
    ) %>%
    left_join(or_county_fips, by = "county_name") %>%
    filter(!is.na(geography)) %>%
    mutate(time = ps_time)

  for (cnt_col in names(ps_pairs)) {
    out_col <- ps_pairs[[cnt_col]]
    ps_data[[out_col]] <- round(ps_data[[cnt_col]] / ps_data$enrollment * 100, 1)
  }

  ps_state <- ps_data %>%
    summarize(
      enrollment = sum(enrollment),
      across(all_of(names(ps_pairs)), sum),
      geography = "41",
      time = ps_time
    )
  for (cnt_col in names(ps_pairs)) {
    out_col <- ps_pairs[[cnt_col]]
    ps_state[[out_col]] <- round(ps_state[[cnt_col]] / ps_state$enrollment * 100, 1)
  }

  output_cols_ps <- c("geography", "time", unname(unlist(ps_pairs)))
  ps_standard <- bind_rows(ps_data[output_cols_ps], ps_state[output_cols_ps])

  # ---------------------------------------------------------------------------
  # 6. Write school outputs and update process record
  # ---------------------------------------------------------------------------
  vroom::vroom_write(k12_standard, "standard/data_k12.csv.gz",      delim = ",")
  vroom::vroom_write(ps_standard,  "standard/data_preschool.csv.gz", delim = ",")

  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}

# =============================================================================
# PART 3: Early childhood (2-year-old) IIS rates via Tableau Public
# =============================================================================

# Helper: bootstrap Tableau session cookie, then fetch .csv export
tableau_csv <- function(workbook, view, out_path) {
  base    <- "https://public.tableau.com/views"
  viz_url <- paste0(base, "/", workbook, "/", view)
  csv_url <- paste0(viz_url, ".csv")

  sess <- httr::GET(
    viz_url,
    httr::user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"),
    httr::timeout(60)
  )
  cookies <- setNames(httr::cookies(sess)$value, httr::cookies(sess)$name)

  resp <- httr::GET(
    csv_url,
    httr::user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"),
    httr::set_cookies(.cookies = cookies),
    httr::add_headers(Referer = viz_url, Accept = "text/csv,*/*"),
    httr::timeout(60)
  )

  if (httr::status_code(resp) != 200) {
    stop(sprintf("HTTP %d for Tableau view '%s'", httr::status_code(resp), view))
  }
  bytes <- httr::content(resp, "raw")
  if (length(bytes) == 0) {
    stop(sprintf("Empty response for Tableau view '%s'", view))
  }
  writeBin(bytes, out_path)
  invisible(out_path)
}

ec_workbook <- "OregonEarlyChildhoodImmunizationRates"

# -----------------------------------------------------------------------------
# 7. Download EC statewide CSV (and county if a view exists)
# -----------------------------------------------------------------------------
tableau_csv(ec_workbook, "StatewideDashboard", "raw/ec_statewide.csv")

ec_county_downloaded <- FALSE
for (cv in c("CountyDashboard", "County", "CountyMap", "CountyLevel")) {
  result <- tryCatch({
    tableau_csv(ec_workbook, cv, "raw/ec_county.csv")
    TRUE
  }, error = function(e) {
    message("EC county view '", cv, "' not available: ", conditionMessage(e))
    FALSE
  })
  if (result) {
    ec_county_downloaded <- TRUE
    message("EC county view found: ", cv)
    break
  }
}

ec_raw_state <- list(
  state_hash  = tools::md5sum("raw/ec_statewide.csv"),
  county_hash = if (ec_county_downloaded) tools::md5sum("raw/ec_county.csv") else NULL
)

if (!identical(process$ec_state, ec_raw_state)) {

  # Reload FIPS lookup if not already in scope (school block may have been skipped)
  if (!exists("or_county_fips")) {
    all_fips <- vroom::vroom("../../resources/all_fips.csv.gz",
                             show_col_types = FALSE,
                             col_types = list(geography = "c"))
    or_county_fips <- all_fips %>%
      filter(nchar(geography) == 5, substr(geography, 1, 2) == "41") %>%
      select(geography, geography_name) %>%
      mutate(county_name = sub(" County$", "", geography_name))
  }

  # ---------------------------------------------------------------------------
  # 8. Helpers: detect vaccine columns and reporting year
  # ---------------------------------------------------------------------------
  ec_vax_patterns <- list(
    "(?i)dtap|dtp"          = "iis_ec_dtap_rate",
    "(?i)polio|ipv"         = "iis_ec_ipv_rate",
    "(?i)mmr"               = "iis_ec_mmr_rate",
    "(?i)hib"               = "iis_ec_hib_rate",
    "(?i)hep.*b|hepat.*b"  = "iis_ec_hepb_rate",
    "(?i)varicella|var|vzv" = "iis_ec_var_rate",
    "(?i)pcv|pneumo"        = "iis_ec_pcv_rate"
  )

  build_ec_col_map <- function(df) {
    col_map <- list()
    sc <- grep("(?i)4:3:1|series|combo", names(df), value = TRUE, perl = TRUE)[1]
    if (!is.na(sc)) col_map[[sc]] <- "iis_ec_series_rate"
    for (pat in names(ec_vax_patterns)) {
      m <- grep(pat, names(df), value = TRUE, perl = TRUE)
      m <- m[!m %in% names(col_map)]
      out <- ec_vax_patterns[[pat]]
      if (length(m) > 0 && !out %in% unlist(col_map)) col_map[[m[1]]] <- out
    }
    col_map
  }

  extract_ec_year <- function(df) {
    yc <- grep("(?i)^year$|birth.*year|survey.*year|cohort",
               names(df), value = TRUE, perl = TRUE)[1]
    if (!is.na(yc) && !all(is.na(df[[yc]]))) {
      as.integer(max(df[[yc]], na.rm = TRUE))
    } else {
      as.integer(format(Sys.Date(), "%Y"))
    }
  }

  recode_ec_values <- function(df, col_map) {
    for (src in names(col_map)) {
      df[[col_map[[src]]]] <- as.numeric(gsub("[%,]", "", df[[src]]))
    }
    df
  }

  # ---------------------------------------------------------------------------
  # 9. Process statewide CSV
  # ---------------------------------------------------------------------------
  ec_state_raw <- vroom::vroom("raw/ec_statewide.csv",
                               show_col_types = FALSE,
                               col_types = vroom::cols(.default = "c"))
  message("OR EC statewide columns: ", paste(names(ec_state_raw), collapse = ", "))

  col_map_s <- build_ec_col_map(ec_state_raw)
  if (length(col_map_s) == 0) {
    stop("No vaccine columns detected in OR EC statewide CSV. Columns: ",
         paste(names(ec_state_raw), collapse = ", "))
  }

  ec_time <- paste0(extract_ec_year(ec_state_raw), "-12-31")

  ec_statewide <- ec_state_raw %>%
    recode_ec_values(col_map_s) %>%
    mutate(geography = "41", time = ec_time) %>%
    select(geography, time, any_of(unname(unlist(col_map_s)))) %>%
    group_by(geography, time) %>%
    summarise(across(everything(), ~ mean(.x, na.rm = TRUE)), .groups = "drop")

  # ---------------------------------------------------------------------------
  # 10. Process county CSV (if available)
  # ---------------------------------------------------------------------------
  if (ec_county_downloaded) {
    ec_county_raw <- vroom::vroom("raw/ec_county.csv",
                                  show_col_types = FALSE,
                                  col_types = vroom::cols(.default = "c"))
    message("OR EC county columns: ", paste(names(ec_county_raw), collapse = ", "))

    county_col <- intersect(
      c("County Name", "County", "COUNTY", "county_name", "GeoName"),
      names(ec_county_raw)
    )[1]
    if (is.na(county_col)) county_col <- names(ec_county_raw)[1]

    col_map_c  <- build_ec_col_map(ec_county_raw)
    ec_time_c  <- paste0(extract_ec_year(ec_county_raw), "-12-31")

    ec_county <- ec_county_raw %>%
      rename(county_name = !!county_col) %>%
      mutate(county_name = trimws(county_name)) %>%
      filter(!is.na(county_name), nchar(county_name) > 0) %>%
      left_join(or_county_fips, by = "county_name") %>%
      filter(!is.na(geography)) %>%
      recode_ec_values(col_map_c) %>%
      mutate(time = ec_time_c) %>%
      select(geography, time, any_of(unname(unlist(col_map_c))))
  }

  # ---------------------------------------------------------------------------
  # 11. Write EC outputs and update process record
  # ---------------------------------------------------------------------------
  vroom::vroom_write(ec_statewide, "standard/data_ec_statewide.csv.gz", delim = ",")
  if (ec_county_downloaded) {
    vroom::vroom_write(ec_county, "standard/data_ec_county.csv.gz", delim = ",")
  }

  process$ec_state <- ec_raw_state
  dcf::dcf_process_record(updated = process)
}

# =============================================================================
# PART 4: Adolescent (13-17 year-old) IIS rates via Tableau Public
# =============================================================================
# Dashboard: https://public.tableau.com/app/profile/oregon.immunization.program/viz/OregonAdolescentImmunizations/D-Landing
# Vaccines: HPV (2-dose series), Meningococcal conjugate, Tdap
# Note: tableau_csv() helper defined in PART 3 above is reused here.

adol_workbook <- "OregonAdolescentImmunizations"

# -----------------------------------------------------------------------------
# 12. Download adolescent CSVs
# -----------------------------------------------------------------------------
# D-Landing is the summary/entry view; also try Statewide and County views
adol_state_downloaded <- FALSE
for (sv in c("D-Landing", "Statewide", "StatewideDashboard")) {
  result <- tryCatch({
    tableau_csv(adol_workbook, sv, "raw/adol_statewide.csv")
    TRUE
  }, error = function(e) {
    message("Adol statewide view '", sv, "' not available: ", conditionMessage(e))
    FALSE
  })
  if (result) {
    adol_state_downloaded <- TRUE
    message("Adol statewide view found: ", sv)
    break
  }
}

if (!adol_state_downloaded) {
  stop("No adolescent statewide view could be downloaded. ",
       "Check dashboard views at: https://public.tableau.com/app/profile/",
       "oregon.immunization.program/viz/OregonAdolescentImmunizations/")
}

adol_county_downloaded <- FALSE
for (cv in c("County", "CountyDashboard", "CountyMap", "CountyLevel")) {
  result <- tryCatch({
    tableau_csv(adol_workbook, cv, "raw/adol_county.csv")
    TRUE
  }, error = function(e) {
    message("Adol county view '", cv, "' not available: ", conditionMessage(e))
    FALSE
  })
  if (result) {
    adol_county_downloaded <- TRUE
    message("Adol county view found: ", cv)
    break
  }
}

adol_raw_state <- list(
  state_hash  = tools::md5sum("raw/adol_statewide.csv"),
  county_hash = if (adol_county_downloaded) tools::md5sum("raw/adol_county.csv") else NULL
)

if (!identical(process$adol_state, adol_raw_state)) {

  # Reload FIPS lookup if not already in scope
  if (!exists("or_county_fips")) {
    all_fips <- vroom::vroom("../../resources/all_fips.csv.gz",
                             show_col_types = FALSE,
                             col_types = list(geography = "c"))
    or_county_fips <- all_fips %>%
      filter(nchar(geography) == 5, substr(geography, 1, 2) == "41") %>%
      select(geography, geography_name) %>%
      mutate(county_name = sub(" County$", "", geography_name))
  }

  # ---------------------------------------------------------------------------
  # 13. Helpers: detect adolescent vaccine columns and reporting year
  # ---------------------------------------------------------------------------
  adol_vax_patterns <- list(
    "(?i)hpv"                      = "iis_adol_hpv_rate",
    "(?i)mening|menacwy|mcv|mpsv"  = "iis_adol_mening_rate",
    "(?i)tdap"                     = "iis_adol_tdap_rate"
  )

  build_adol_col_map <- function(df) {
    col_map <- list()
    sc <- grep("(?i)series|combo|all.*vac|utd",
               names(df), value = TRUE, perl = TRUE)[1]
    if (!is.na(sc)) col_map[[sc]] <- "iis_adol_series_rate"
    for (pat in names(adol_vax_patterns)) {
      m <- grep(pat, names(df), value = TRUE, perl = TRUE)
      m <- m[!m %in% names(col_map)]
      out <- adol_vax_patterns[[pat]]
      if (length(m) > 0 && !out %in% unlist(col_map)) col_map[[m[1]]] <- out
    }
    col_map
  }

  extract_adol_year <- function(df) {
    yc <- grep("(?i)^year$|survey.*year|report.*year|cohort",
               names(df), value = TRUE, perl = TRUE)[1]
    if (!is.na(yc) && !all(is.na(df[[yc]]))) {
      as.integer(max(df[[yc]], na.rm = TRUE))
    } else {
      as.integer(format(Sys.Date(), "%Y"))
    }
  }

  recode_adol_values <- function(df, col_map) {
    for (src in names(col_map)) {
      df[[col_map[[src]]]] <- as.numeric(gsub("[%,]", "", df[[src]]))
    }
    df
  }

  # ---------------------------------------------------------------------------
  # 14. Process adolescent statewide CSV
  # ---------------------------------------------------------------------------
  adol_state_raw <- vroom::vroom("raw/adol_statewide.csv",
                                 show_col_types = FALSE,
                                 col_types = vroom::cols(.default = "c"))
  message("OR adol statewide columns: ", paste(names(adol_state_raw), collapse = ", "))

  col_map_as <- build_adol_col_map(adol_state_raw)
  if (length(col_map_as) == 0) {
    stop("No vaccine columns detected in OR adol statewide CSV. Columns: ",
         paste(names(adol_state_raw), collapse = ", "))
  }

  adol_time <- paste0(extract_adol_year(adol_state_raw), "-12-31")

  adol_statewide <- adol_state_raw %>%
    recode_adol_values(col_map_as) %>%
    mutate(geography = "41", time = adol_time) %>%
    select(geography, time, any_of(unname(unlist(col_map_as)))) %>%
    group_by(geography, time) %>%
    summarise(across(everything(), ~ mean(.x, na.rm = TRUE)), .groups = "drop")

  # ---------------------------------------------------------------------------
  # 15. Process adolescent county CSV (if available)
  # ---------------------------------------------------------------------------
  if (adol_county_downloaded) {
    adol_county_raw <- vroom::vroom("raw/adol_county.csv",
                                    show_col_types = FALSE,
                                    col_types = vroom::cols(.default = "c"))
    message("OR adol county columns: ",
            paste(names(adol_county_raw), collapse = ", "))

    county_col_a <- intersect(
      c("County Name", "County", "COUNTY", "county_name", "GeoName"),
      names(adol_county_raw)
    )[1]
    if (is.na(county_col_a)) county_col_a <- names(adol_county_raw)[1]

    col_map_ac  <- build_adol_col_map(adol_county_raw)
    adol_time_c <- paste0(extract_adol_year(adol_county_raw), "-12-31")

    adol_county <- adol_county_raw %>%
      rename(county_name = !!county_col_a) %>%
      mutate(county_name = trimws(county_name)) %>%
      filter(!is.na(county_name), nchar(county_name) > 0) %>%
      left_join(or_county_fips, by = "county_name") %>%
      filter(!is.na(geography)) %>%
      recode_adol_values(col_map_ac) %>%
      mutate(time = adol_time_c) %>%
      select(geography, time, any_of(unname(unlist(col_map_ac))))
  }

  # ---------------------------------------------------------------------------
  # 16. Write adolescent outputs and update process record
  # ---------------------------------------------------------------------------
  vroom::vroom_write(adol_statewide,
                     "standard/data_adol_statewide.csv.gz", delim = ",")
  if (adol_county_downloaded) {
    vroom::vroom_write(adol_county,
                       "standard/data_adol_county.csv.gz", delim = ",")
  }

  process$adol_state <- adol_raw_state
  dcf::dcf_process_record(updated = process)
}
