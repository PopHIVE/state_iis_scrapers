# =============================================================================
# Tennessee IIS Data Ingestion
# Source: Tennessee Department of Health - TennIIS Coverage Rate Dashboard
# https://www.tn.gov/health/cedep/immunization-program/ip/
#   immunization-fact-sheet/coverage-rate-dashboard.html
# =============================================================================

library(dplyr)
library(tidyr)

process <- dcf::dcf_process_record()

# -----------------------------------------------------------------------------
# 1. Download raw data (5 CSV files)
# -----------------------------------------------------------------------------
base_url <- paste0(
  "https://www.tn.gov/content/dam/tn/health/",
  "documents/cedep/coverage-rate-dashboard/"
)

files <- list(
  child  = "VAX_COVERAGE_CHILD_RATES_2_3.CSV",
  school = "VAX_COVERAGE_SCHOOL_RATES_4_6.CSV",
  teen   = "VAX_COVERAGE_TEEN_RATES_11_17.CSV",
  adult  = "VAX_COVERAGE_ADULT_RATES_18_64.CSV",
  senior = "VAX_COVERAGE_ADULT_RATES_65UP.CSV"
)

# Age suffix in column names for each file
age_suffix <- list(
  child  = "2_3",
  school = "4_6",
  teen   = "11_17",
  adult  = "18_64",
  senior = "65UP"
)

for (f in files) {
  dest <- file.path("raw", f)
  for (attempt in 1:3) {
    tryCatch({
      resp <- httr::GET(
        paste0(base_url, f),
        httr::user_agent(
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
        ),
        httr::config(ssl_verifypeer = TRUE),
        httr::timeout(120)
      )
      writeBin(httr::content(resp, "raw"), dest)
      break
    }, error = function(e) {
      if (attempt == 3) stop(e)
      Sys.sleep(5)
    })
  }
}

# Hash raw files for change detection
raw_hashes <- sapply(
  file.path("raw", unlist(files)),
  tools::md5sum
)
raw_state <- list(hashes = raw_hashes)

if (!identical(process$raw_state, raw_state)) {

  # -----------------------------------------------------------
  # 2. Load FIPS lookup for Tennessee counties
  # -----------------------------------------------------------
  all_fips <- vroom::vroom(
    "../../resources/all_fips.csv.gz",
    show_col_types = FALSE,
    col_types = list(geography = "c")
  )

  tn_county_fips <- all_fips %>%
    filter(
      nchar(geography) == 5,
      substr(geography, 1, 2) == "47"
    ) %>%
    select(geography, geography_name) %>%
    mutate(
      county_upper = toupper(
        sub(" County$", "", geography_name)
      )
    )

  # -----------------------------------------------------------
  # 3. Process each file
  # -----------------------------------------------------------
  process_file <- function(file_key) {
    fname <- files[[file_key]]
    suffix <- age_suffix[[file_key]]
    total_col <- paste0("TOTAL_", suffix, "_VAX_RATE")

    df <- vroom::vroom(
      file.path("raw", fname),
      show_col_types = FALSE,
      col_select = c(
        EVAL_DATE, COUNTY, VACCINE_NAME,
        all_of(total_col)
      )
    )

    names(df)[names(df) == total_col] <- "rate"

    df %>%
      mutate(
        # Suppress values coded as 777
        rate = if_else(
          rate >= 777, NA_real_, rate
        ),
        vaccine = tolower(
          gsub("[^a-zA-Z0-9]", "", VACCINE_NAME)
        ),
        # Remap to canonical vaccine names
        vaccine = case_when(
          vaccine == "varicella"          ~ "var",
          vaccine == "menacwy"            ~ "mcv4",
          vaccine == "pneumococcal"       ~ "pneumo",
          vaccine == "shingles"           ~ "zoster",
          vaccine == "daycareseries"      ~ "series",
          vaccine == "kindergartenseries" ~ "series",
          TRUE                            ~ vaccine
        ),
        col_name = paste0(
          "iis_", file_key, "_", vaccine, "_rate"
        ),
        time = format(
          as.Date(EVAL_DATE, "%m/%d/%Y"),
          "%Y-%m-%d"
        ),
        county_upper = toupper(COUNTY)
      ) %>%
      select(time, county_upper, col_name, rate) %>%
      pivot_wider(
        names_from = col_name,
        values_from = rate
      )
  }

  results <- lapply(names(files), process_file)

  # -----------------------------------------------------------
  # 4. Merge all age groups and convert geography
  # -----------------------------------------------------------
  data_merged <- results[[1]]
  for (i in 2:length(results)) {
    data_merged <- full_join(
      data_merged,
      results[[i]],
      by = c("time", "county_upper")
    )
  }

  data_standard <- data_merged %>%
    left_join(tn_county_fips, by = "county_upper") %>%
    filter(!is.na(geography)) %>%
    select(
      -county_upper, -geography_name
    ) %>%
    select(geography, time, everything())

  # -----------------------------------------------------------
  # 5. Write standardized output
  # -----------------------------------------------------------
  vroom::vroom_write(
    data_standard,
    "standard/data.csv.gz",
    delim = ","
  )

  # -----------------------------------------------------------
  # 6. Update process record
  # -----------------------------------------------------------
  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
