# =============================================================================
# Virginia IIS Data Ingestion
# Source: Virginia Dept of Health - Respiratory Disease Vaccines
# https://data.virginia.gov/ (CKAN portal)
# =============================================================================

library(dplyr)

process <- dcf::dcf_process_record()

# -----------------------------------------------------------------------------
# 1. Download raw data
# -----------------------------------------------------------------------------
csv_url <- paste0(
  "https://data.virginia.gov/dataset/",
  "f90989a2-0218-4f0d-b276-2ed798f538ec/",
  "resource/95c732d9-b69b-4c60-87f7-",
  "d75c567d4223/download/",
  "vdh-covid-19-vaccine-population-metrix.csv"
)

resp <- httr::GET(
  csv_url,
  httr::user_agent(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
  ),
  httr::timeout(120)
)
writeBin(
  httr::content(resp, "raw"),
  "raw/vdh-vaccine-metrix.csv"
)

raw_state <- list(
  hash = tools::md5sum("raw/vdh-vaccine-metrix.csv")
)

if (!identical(process$raw_state, raw_state)) {

  # -----------------------------------------------------------
  # 2. Read raw data
  # -----------------------------------------------------------
  data_raw <- vroom::vroom(
    "raw/vdh-vaccine-metrix.csv",
    show_col_types = FALSE,
    col_types = list(FIPS = "c")
  )

  # -----------------------------------------------------------
  # 3. Process age-group data (primary)
  # -----------------------------------------------------------
  data_age <- data_raw %>%
    filter(INDICATOR == "Age_Group") %>%
    mutate(
      geography = sprintf(
        "%05s", as.character(FIPS)
      ),
      time = format(REPORT_DATE, "%Y-%m-%d"),
      age = SUB_INDICATOR,
      iis_covid_dose_count = as.numeric(
        COVID_VACCINE_COUNT
      ),
      iis_covid_people_count = as.numeric(
        COVID_19_PEOPLE_COUNT
      ),
      iis_flu_dose_count = as.numeric(
        FLU_VACCINE_COUNT
      ),
      iis_flu_people_count = as.numeric(
        FLU_PEOPLE_COUNT
      ),
      iis_covid_rate = as.numeric(
        COVID_VACCINE_RATE
      ),
      iis_flu_rate = as.numeric(
        FLU_VACCINE_RATE
      ),
      season = VACCINE_RESPIRATORY_SEASON
    ) %>%
    select(
      geography, time, age, season,
      iis_covid_dose_count, iis_covid_people_count,
      iis_flu_dose_count, iis_flu_people_count,
      iis_covid_rate, iis_flu_rate
    )

  # -----------------------------------------------------------
  # 4. Process race/ethnicity data
  # -----------------------------------------------------------
  data_re <- data_raw %>%
    filter(INDICATOR == "Race and Ethnicity") %>%
    mutate(
      geography = sprintf(
        "%05s", as.character(FIPS)
      ),
      time = format(REPORT_DATE, "%Y-%m-%d"),
      race_ethnicity = SUB_INDICATOR,
      iis_covid_rate = as.numeric(
        COVID_VACCINE_RATE
      ),
      iis_flu_rate = as.numeric(
        FLU_VACCINE_RATE
      ),
      season = VACCINE_RESPIRATORY_SEASON
    ) %>%
    select(
      geography, time, race_ethnicity, season,
      iis_covid_rate, iis_flu_rate
    )

  # -----------------------------------------------------------
  # 5. Write standardized output
  # -----------------------------------------------------------
  vroom::vroom_write(
    data_age,
    "standard/data.csv.gz",
    delim = ","
  )
  vroom::vroom_write(
    data_re,
    "standard/data_race_ethnicity.csv.gz",
    delim = ","
  )

  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
