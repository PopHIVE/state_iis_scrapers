# =============================================================================
# Texas IIS Data Ingestion
# Source: DSHS ImmTrac2 Doses Administered
# https://www.dshs.texas.gov/immunizations/data/program-data
# =============================================================================

library(dplyr)
library(tidyr)

process <- dcf::dcf_process_record()

# -----------------------------------------------------------------------------
# 1. Download raw data
# -----------------------------------------------------------------------------
xlsx_url <- paste0(
  "https://www.dshs.texas.gov/sites/default/files/",
  "LIDS-Immunizations/xls/",
  "immtrac2-doses-administered-for-web.xlsx"
)

resp <- httr::GET(
  xlsx_url,
  httr::user_agent(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
  ),
  httr::timeout(120)
)
writeBin(
  httr::content(resp, "raw"),
  "raw/immtrac2-doses.xlsx"
)

raw_state <- list(
  hash = tools::md5sum("raw/immtrac2-doses.xlsx")
)

if (!identical(process$raw_state, raw_state)) {

  # -----------------------------------------------------------
  # 2. Load FIPS lookup for Texas counties
  # -----------------------------------------------------------
  all_fips <- vroom::vroom(
    "../../resources/all_fips.csv.gz",
    show_col_types = FALSE,
    col_types = list(geography = "c")
  )

  tx_county_fips <- all_fips %>%
    filter(
      nchar(geography) == 5,
      substr(geography, 1, 2) == "48"
    ) %>%
    select(geography, geography_name) %>%
    mutate(
      county_name = sub(" County$", "", geography_name)
    )

  # -----------------------------------------------------------
  # 3. Read and transform
  # -----------------------------------------------------------
  # Skip first 3 header rows; assign column names
  data_raw <- readxl::read_excel(
    "raw/immtrac2-doses.xlsx",
    sheet = "Data",
    skip = 3,
    col_names = c(
      "county", "year", "month",
      "age_group", "vaccine", "count"
    ),
    col_types = c(
      "text", "numeric", "text",
      "text", "text", "text"
    )
  )

  # Month name to number lookup
  month_nums <- setNames(
    sprintf("%02d", 1:12),
    c("January", "February", "March", "April",
      "May", "June", "July", "August",
      "September", "October", "November",
      "December")
  )

  data_clean <- data_raw %>%
    filter(!is.na(county), !is.na(year)) %>%
    mutate(
      # Handle suppressed values ("**")
      count = as.numeric(
        ifelse(count == "**", NA, count)
      ),
      # Clean vaccine names for columns
      vaccine_clean = tolower(
        gsub("[^a-zA-Z0-9]", "_", vaccine)
      ),
      vaccine_clean = gsub("_+", "_", vaccine_clean),
      vaccine_clean = gsub("^_|_$", "", vaccine_clean),
      # Remap vaccine names to remove age prefixes
      vaccine_clean = dplyr::recode(
        vaccine_clean,
        "adolescent_hpv" = "hpv",
        "adolescent_mcv4" = "mcv4",
        "adolescent_td_tdap" = "tdap",
        "pediatric_mmr" = "mmr",
        "all_other" = "other"
      ),
      col_name = paste0("iis_", vaccine_clean, "_count"),
      # Build time from year + month
      month_num = month_nums[month],
      time = paste0(year, "-", month_num, "-01"),
      # Normalize age group
      age = age_group
    ) %>%
    filter(!is.na(month_num))

  # Pivot vaccines to wide format
  data_wide <- data_clean %>%
    select(county, time, age, col_name, count) %>%
    pivot_wider(
      names_from = col_name,
      values_from = count,
      values_fn = sum
    )

  # Convert county names to FIPS
  data_standard <- data_wide %>%
    left_join(
      tx_county_fips,
      by = c("county" = "county_name")
    ) %>%
    filter(!is.na(geography)) %>%
    select(-county, -geography_name) %>%
    select(geography, time, age, everything())

  # -----------------------------------------------------------
  # 4. Write standardized output
  # -----------------------------------------------------------
  vroom::vroom_write(
    data_standard,
    "standard/data.csv.gz",
    delim = ","
  )

  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
