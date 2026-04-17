# ingest-source

Ingest a new data source: create the folder structure, write the ingest.R script to standardize raw data, and create the measure_info.json.

## Usage

```
/ingest-source <source_name> [description of data source and where to get it]
```

## Description

End-to-end skill for adding and ingesting a new data source into the PopHIVE/Ingest repository. This skill:

1. Creates the folder structure via the `add-source` skill
2. Examines the raw data to understand its structure
3. Writes an `ingest.R` script that transforms raw data into the standard wide format
4. Creates a `measure_info.json` documenting all output variables

## Instructions

When the user invokes this skill:

### Phase 1: Create Folder Structure

Run the `add-source` skill with the provided source name to initialize the directory structure (`data/<source_name>/raw/`, `standard/`, `process.json`, etc.). Follow all steps in that skill (detect R version, run `dcf::dcf_add_source()`, verify structure).

### Phase 2: Gather Information

Ask the user (if not already provided):
- **Data source URL or file location**: Where is the raw data? (CDC Socrata dataset ID, direct URL, API, or local file)
- **What does the data measure?**: Brief description of the outcomes/variables
- **Geographic level**: National, state, county, or multiple?
- **Time resolution**: Weekly, monthly, annual?
- **Demographic breakdowns**: Age, race/ethnicity, sex, other?

If the user has already placed raw files in the `raw/` directory, examine them directly. If the user provides a URL or dataset ID, note it for the download step in ingest.R.

### Phase 3: Examine Raw Data

Before writing any code, understand the raw data structure:

1. **If raw files exist**: Read the first 20-30 rows to understand columns, types, and values
2. **If a CDC dataset ID is provided**: Note it for `dcf::dcf_download_cdc()` — the raw file will be at `raw/{dataset-id}.csv.xz`
3. **If a URL is provided**: Note it for `download.file()` in ingest.R

Identify:
- All column names and their meanings
- Which columns map to `geography`, `time`, and demographic dimensions (`age`, `sex`, `race_ethnicity`)
- Which columns contain outcome/measure values
- Any filtering needed (e.g., selecting specific record types, removing aggregates)
- Geographic format (state names, abbreviations, FIPS codes, county names)
- Date format in the raw data

### Phase 4: Write ingest.R

Write the `ingest.R` script at `data/<source_name>/ingest.R` following these rules:

#### Script Structure

```r
# =============================================================================
# {SOURCE_NAME} Data Ingestion
# Source: {URL or description}
# =============================================================================

library(dplyr)

# Initialize process record
process <- dcf::dcf_process_record()

# --- 1. Download raw data ---
# (Use dcf::dcf_download_cdc(), download.file(), or other method)

# --- 2. Check for changes ---
if (!identical(process$raw_state, raw_state)) {

  # --- 3. Read raw data ---
  # --- 4. Transform to standard wide format ---
  # --- 5. Write standardized output ---
  # --- 6. Update process record ---

  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
```

#### Output Format: Standard Wide Format

The standardized output MUST be in **wide format** with:

- **Index columns**: `geography`, `time`, and optionally `age`, `sex`, `race_ethnicity` (one row per unique combination)
- **Value columns**: Each unique outcome variable gets its own column

#### Column Naming Convention

All value columns MUST follow this naming pattern:

```
iis_{agegroup}_{vaccine}_{suffix}
```

Where:
- **`iis_`**: Fixed prefix identifying this as IIS (Immunization Information System) data. Do NOT include the state abbreviation — geography is conveyed by the `geography` column (FIPS codes), so state in the column name is redundant.
- **`{agegroup}`**: Age group prefix. Include ONLY when different age groups have different vaccine sets in wide-format columns. Omit when `age` is a row-level dimension column and all age groups share the same value columns.
- **`{vaccine}`**: Canonical vaccine abbreviation (see table below)
- **`{suffix}`**: One of `_rate` (percentage), `_count` (integer count), or `_pop` (population denominator)

##### Canonical Vaccine Names

| Canonical | Full Name | Aliases to remap |
|-----------|-----------|------------------|
| `dtap` | DTaP/Td/DTP | |
| `mmr` | MMR | |
| `hepb` | Hepatitis B | `hep_b` → `hepb` |
| `hepa` | Hepatitis A | `hep_a` → `hepa` |
| `ipv` | Polio (IPV/OPV) | `polio`, `poliovirus` → `ipv` |
| `var` | Varicella | `varicella` → `var` |
| `hpv` | HPV | |
| `tdap` | Tdap | |
| `mcv4` | Meningococcal (MenACWY) | `menacwy`, `mcv` → `mcv4` |
| `pcv` | Pneumococcal conjugate (child) | |
| `hib` | Hib | |
| `rotavirus` | Rotavirus | |
| `series` | Complete age-appropriate series | `daycareseries`, `kindergartenseries`, `childseries` → `series` |
| `covid` | COVID-19 | |
| `flu` | Influenza | |
| `zoster` | Shingles/Zoster | `shingles` → `zoster` |
| `pneumo` | Pneumococcal (adult) | `pneumococcal` → `pneumo` |

##### Standard Age Group Labels

| Label | Ages | Use in column names when... |
|-------|------|---------------------------|
| `infant` | 0–35 months | Different vaccines than other groups |
| `child` | 4–6 years | Different vaccines than other groups |
| `pread` | 9–10 years | Exists as separate data |
| `preteen` | 11–12 years | Exists as separate data |
| `teen` | 11–17 years | Different vaccines than other groups |
| `adult` | 18–64 years | Different vaccines than other groups |
| `senior` | 65+ years | Different vaccines than other groups |

When age is a **row dimension** (the `age` column distinguishes rows and all age groups share the same value columns), omit the age group from the column name entirely.

##### Suffix Rules

- **`_rate`**: Always append for percentage/coverage values (e.g., `iis_infant_dtap_rate`)
- **`_count`**: Always append for integer counts (doses, people) (e.g., `iis_covid_dose_count`)
- **`_pop`**: Use for population denominators (e.g., `iis_infant_pop`)

##### Examples

IIS sources with age groups in wide columns (different vaccines per age):
- `iis_infant_dtap_rate`, `iis_infant_mmr_rate`, `iis_infant_series_rate`
- `iis_child_dtap_rate`, `iis_child_hepa_rate`, `iis_child_ipv_rate`
- `iis_teen_hpv_rate`, `iis_teen_tdap_rate`, `iis_teen_mcv4_rate`
- `iis_senior_pneumo_rate`, `iis_senior_zoster_rate`

IIS sources with age as a row dimension (same columns for all ages):
- `iis_dtap_rate`, `iis_mmr_rate`, `iis_hepb_rate`, `iis_var_rate`

Respiratory vaccine dose counts:
- `iis_covid_dose_count`, `iis_flu_dose_count`, `iis_covid_rate`

Rules:
- All lowercase with underscores
- Do NOT include the state abbreviation in column names
- Always use canonical vaccine names (remap aliases)
- Always include `_rate`, `_count`, or `_pop` suffix for clarity
- Names should be short but unambiguous

#### Geography Handling

- Convert state names/abbreviations to FIPS codes using `resources/all_fips.csv.gz` (preferred, fast)
- National level = `"00"`
- State = 2-digit FIPS string (e.g., `"06"`)
- County = 5-digit FIPS string (e.g., `"06037"`)
- See CLAUDE.md for FIPS lookup patterns

```r
all_fips <- vroom::vroom("../../resources/all_fips.csv.gz", show_col_types = FALSE)

# For state abbreviations:
state_fips_lookup <- all_fips %>%
  filter(nchar(geography) == 2) %>%
  select(geography, state)

# For state names:
state_fips_lookup <- all_fips %>%
  filter(nchar(geography) == 2) %>%
  select(geography, geography_name)
```

#### Time Handling

- Format as `YYYY-mm-dd`
- Weekly data: use Saturday at end of epiweek
- Monthly data: use last day of month
- Annual data: use `YYYY-12-31`

#### National Averages

If the raw data does not include national-level aggregates, calculate population-weighted averages for state-level data and append with `geography = "00"`.

#### Data Quality

- Handle suppressed values: flag with `suppressed_flag` column if imputing
- Remove or filter irrelevant rows (totals that would cause double-counting, non-standard geographies)
- Ensure no duplicate rows per (geography, time, demographic) combination

#### Output Writing

```r
vroom::vroom_write(data_standard, "standard/data.csv.gz", ",")
```

If state and county data are separate, write to `standard/data_state.csv.gz` and `standard/data_county.csv.gz`, or combine into a single file.

### Phase 5: Write measure_info.json

Create `data/<source_name>/measure_info.json` with an entry for every value column in the standardized output. Follow the schema from CLAUDE.md.

#### For Each Value Column

```json
{
  "column_name": {
    "id": "column_name",
    "short_name": "Human-readable short name",
    "long_name": "Full descriptive name",
    "category": "respiratory|immunization|chronic|injury|demographic",
    "short_description": "One sentence description.",
    "long_description": "Detailed description with methodology notes.",
    "statement": "Template: 'In {location}, the {measure} was {value}.'",
    "measure_type": "Incidence|Prevalence|Rate|Percent|Count",
    "unit": "Cases per 100,000|Percent|Count",
    "time_resolution": "Week|Month|Year",
    "sources": [{ "id": "source_id" }]
  }
}
```

#### Use Variants When Columns Follow a Pattern

If multiple columns share the same structure differing only by a variant (e.g., `wastewater_covid`, `wastewater_flu`, `wastewater_rsv`), use the `variants` mechanism:

```json
{
  "{prefix}_{variant}": {
    "short_name": "{prefix}: {variant.short_name}",
    "long_name": "Full name of {variant.short_name}",
    "variants": {
      "covid": { "short_name": "COVID-19" },
      "flu":   { "short_name": "Influenza" },
      "rsv":   { "short_name": "RSV" }
    },
    ...
  }
}
```

#### Always Include `_sources`

```json
{
  "_sources": {
    "source_id": {
      "name": "Full source name",
      "url": "https://...",
      "organization": "Organization name",
      "organization_url": "https://...",
      "description": "Detailed narrative description.",
      "restrictions": "License and usage restrictions."
    }
  }
}
```

### Phase 6: Validate and Report

After writing all files:

1. **Check file structure**: Verify `ingest.R`, `measure_info.json`, `process.json` all exist
2. **If raw data is available**: Offer to run the ingest.R script to test
3. **Report what was created**:
   - Source directory path
   - List of standardized output columns (prefix + name)
   - Geographic levels covered
   - Time resolution
   - Next steps (run ingest, add to bundle, etc.)

## Example

User: `/ingest-source nssp_ili CDC NSSP ILI data, dataset ID abc-1234, state and county level weekly ED visits for ILI`

The skill would:
1. Run `dcf::dcf_add_source("nssp_ili")`
2. Write `ingest.R` that downloads via `dcf::dcf_download_cdc("abc-1234", ...)`, transforms to wide format with columns like `nssp_ili_pct_visits`
3. Write `measure_info.json` with entries for each output column
4. Report the created structure and suggest next steps
