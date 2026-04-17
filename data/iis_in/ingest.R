# =============================================================================
# Indiana IIS Data Ingestion
# Source: Indiana DOH - CHIRP School Immunization Data
# https://hub.mph.in.gov/dataset/
#   immunization-division-s-school-supplemental-dashboard
# =============================================================================

library(dplyr)

process <- dcf::dcf_process_record()

# -----------------------------------------------------------------------------
# 1. Download raw data (2 school year files)
# -----------------------------------------------------------------------------
base_url <- paste0(
  "https://hub.mph.in.gov/dataset/",
  "f4e11e6e-2e4f-41b1-a46c-c6d43c6ce1a3/resource/"
)

files <- list(
  sy2324 = paste0(
    base_url,
    "0c777e9d-6817-43ee-9527-e9b366b4eef1/",
    "download/immunization-data_",
    "school-year-2023-2024.xlsx"
  ),
  sy2425 = paste0(
    base_url,
    "0312dc24-bd75-4f20-8367-e9660c5e801c/",
    "download/immunization-data_",
    "school-year-2024-2025.xlsx"
  )
)

for (key in names(files)) {
  fname <- paste0("school-", key, ".xlsx")
  resp <- httr::GET(
    files[[key]],
    httr::user_agent(
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    ),
    httr::timeout(120)
  )
  writeBin(
    httr::content(resp, "raw"),
    file.path("raw", fname)
  )
}

raw_hashes <- sapply(
  file.path(
    "raw",
    paste0("school-", names(files), ".xlsx")
  ),
  tools::md5sum
)
raw_state <- list(hashes = raw_hashes)

if (!identical(process$raw_state, raw_state)) {

  # -----------------------------------------------------------
  # 2. Load FIPS lookup for Indiana counties
  # -----------------------------------------------------------
  all_fips <- vroom::vroom(
    "../../resources/all_fips.csv.gz",
    show_col_types = FALSE,
    col_types = list(geography = "c")
  )

  in_county_fips <- all_fips %>%
    filter(
      nchar(geography) == 5,
      substr(geography, 1, 2) == "18"
    ) %>%
    select(geography, geography_name) %>%
    mutate(
      county_upper = toupper(
        sub(" County$", "", geography_name)
      )
    )

  # -----------------------------------------------------------
  # 3. Read and normalize each school year
  # -----------------------------------------------------------
  school_years <- list(
    "2023-2024" = "raw/school-sy2324.xlsx",
    "2024-2025" = "raw/school-sy2425.xlsx"
  )

  all_data <- list()
  for (sy in names(school_years)) {
    fpath <- school_years[[sy]]
    sheets <- readxl::excel_sheets(fpath)
    d <- readxl::read_excel(fpath, sheet = sheets[1])

    # Normalize column names: replace spaces with _
    names(d) <- gsub(" ", "_", names(d))
    # Fix rate column names for 2023-2024 format
    names(d) <- gsub("Dtap_Rate", "Dtap/Td_Rate", names(d))
    names(d) <- gsub("MCV4_Rate", "MCV4_Rate", names(d))
    names(d) <- gsub("DOE_Enrollment", "DOE_Enrollment", names(d))
    names(d) <- gsub(
      "Reported_in_SNM_\\(CHIRP\\)",
      "Reported_in_SNM_CHIRP",
      names(d)
    )
    names(d) <- gsub(
      "Meets_Immunization_Requirements",
      "Meets_Immunization_Requirements",
      names(d)
    )
    names(d) <- gsub(
      "Does_Not_Meet_Immunization_Requirements",
      "Does_Not_Meet_Immunization_Requirements",
      names(d)
    )

    # Identify rate columns
    rate_cols <- grep("_Rate$", names(d), value = TRUE)

    # Convert rate columns to numeric
    for (col in rate_cols) {
      d[[col]] <- as.numeric(d[[col]])
    }

    # Use County name for FIPS lookup
    reported_col <- if (
      "Reported_in_SNM_CHIRP" %in% names(d)
    ) {
      "Reported_in_SNM_CHIRP"
    } else {
      NULL
    }

    county_agg <- d %>%
      mutate(
        county_upper = toupper(County),
        reported = as.numeric(
          .data[[
            grep("Reported", names(d), value = TRUE)[1]
          ]]
        ),
        enrollment = as.numeric(DOE_Enrollment)
      ) %>%
      group_by(county_upper, Grade) %>%
      summarize(
        across(
          all_of(rate_cols),
          ~ weighted.mean(.x, reported, na.rm = TRUE)
        ),
        iis_enrollment_count = sum(
          enrollment, na.rm = TRUE
        ),
        .groups = "drop"
      ) %>%
      mutate(school_year = sy)

    all_data[[sy]] <- county_agg
  }

  data_combined <- bind_rows(all_data)

  # -----------------------------------------------------------
  # 4. Standardize columns and convert geography
  # -----------------------------------------------------------
  # Normalize rate column names
  rename_map <- c(
    "iis_dtap_rate" = "Dtap/Td_Rate",
    "iis_tdap_rate" = "Tdap_Rate",
    "iis_ipv_rate" = "IPV/OPV_Rate",
    "iis_mmr_rate" = "MMR_Rate",
    "iis_hepb_rate" = "HepB_Rate",
    "iis_var_rate" = "VAR_Rate",
    "iis_hepa_rate" = "HepA_Rate",
    "iis_mcv4_rate" = "MCV4_Rate"
  )

  # Only rename columns that exist
  existing <- intersect(
    unname(rename_map), names(data_combined)
  )
  rename_use <- rename_map[rename_map %in% existing]

  data_standard <- data_combined %>%
    rename(!!!rename_use) %>%
    left_join(in_county_fips, by = "county_upper") %>%
    mutate(
      year_end = as.numeric(
        sub(".*-(\\d{4})$", "\\1", school_year)
      ),
      time = paste0(year_end, "-06-30"),
      age = paste0("grade_", Grade)
    ) %>%
    filter(!is.na(geography)) %>%
    select(
      geography, time, age,
      starts_with("iis_")
    )

  # -----------------------------------------------------------
  # 5. Write standardized output
  # -----------------------------------------------------------
  vroom::vroom_write(
    data_standard,
    "standard/data.csv.gz",
    delim = ","
  )

  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
