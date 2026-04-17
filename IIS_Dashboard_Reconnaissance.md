# State IIS Dashboard Reconnaissance
## PopHIVE Project — April 2026

This document summarizes the initial reconnaissance and planning work for automated scraping of publicly accessible immunization registry (IIS) dashboards across 26 states, sourced from the spreadsheet `resources/IIS Data Dashboards, April 2026.csv`.

---

## Approach

For each of the 26 state dashboard URLs, we assessed:

1. **Data accessibility** — Is data downloadable without login or special access?
2. **Platform type** — Static file, API, Tableau, ArcGIS, Power BI, etc.
3. **Data content** — Which vaccines, age groups, geographies, and time periods are available?
4. **Automation feasibility** — Can this be reliably automated in R without a browser?

States were then classified into three tiers based on ease of automated data extraction.

---

## Tier 1: Direct Download (8 states implemented)

These states provide data as static CSV or Excel files, or via a public REST API. All eight were implemented in Phase 1.

### Minnesota (`iis_mn`)
- **Source**: MN Department of Health — MIIC (Minnesota Immunization Information Connection)
- **Platform**: 6 static CSV files served via HTTP
- **URL pattern**: `https://www.health.mn.gov/people/immunize/stats/gaps/childrates.csv` + 5 variants
- **Data**: County-level vaccination rates for children (24 months, 6 years) and adolescents (13 years); separate race/ethnicity breakdowns
- **Vaccines**: DTaP, MMR, Hep B, Hib, IPV, Varicella, PCV, Series completion
- **Notes**: Server requires browser-like User-Agent header (otherwise 403 error); "St. Louis County" needs period-stripping for FIPS match; rows with "NO ADDRESS" must be filtered
- **Output columns**: `iis_infant_dtap_rate`, `iis_infant_mmr_rate`, ..., `iis_teen_hpv_rate`, `iis_teen_mcv4_rate`, `iis_teen_tdap_rate`, `iis_teen_series_rate`

### Tennessee (`iis_tn`)
- **Source**: Tennessee Department of Health — TennIIS
- **Platform**: 5 direct CSV files
- **URL pattern**: `https://www.tn.gov/content/dam/tn/health/documents/cedep/coverage-rate-dashboard/VAX_COVERAGE_CHILD_RATES_2_3.CSV` + 4 variants
- **Data**: County-level rates for children (2–5y), school-age (4–6y), teens (11–17y), adults (18–64y), seniors (65+)
- **Vaccines**: DTaP, MMR, Hep B, Hep A, IPV, Varicella, Series, HPV, MCV4, Tdap, Pneumococcal, Zoster, Flu
- **Notes**: SSL intermittently fails — retry logic required; suppressed values encoded as `777` (recoded to NA)
- **Output columns**: `iis_child_dtap_rate`, ..., `iis_school_series_rate`, ..., `iis_teen_hpv_rate`, ..., `iis_senior_zoster_rate`

### Washington (`iis_wa`)
- **Source**: Washington State DOH — County Public Health Measures Dashboard
- **Platform**: 6 direct Excel files (one per age group + one for race/ethnicity)
- **URL pattern**: `https://doh.wa.gov/sites/default/files/2025-09/Immunization-Dashboard-Coverage-19-35montholds.xlsx` + 5 variants
- **Data**: County-level rates by age group (19–35mo, 4–6y, 9–10y, 11–12y, 13–17y); each workbook has one sheet per time period (monthly, 2016–present)
- **Vaccines**: MMR, Varicella, DTaP, Hep B, IPV, Hep A, HPV, MCV4, Tdap, Series
- **Notes**: Complex multi-header Excel structure — vaccine names in row 1, sub-headers in row 2, data from row 3; vaccine positions must be detected from row 1 (not fixed columns); dose-number and "UTD_" prefixes must be stripped from vaccine names
- **Output columns**: `iis_infant_mmr_rate`, ..., `iis_preteen_hpv_rate`, `iis_teen_hpv_rate` (plus race/ethnicity file)

### Wisconsin (`iis_wi`)
- **Source**: Wisconsin DHS — Wisconsin Immunization Registry (WIR)
- **Platform**: 4 direct CSV files
- **URL pattern**: `https://www.dhs.wisconsin.gov/immunization/statewide-adult-immunization-data.csv` + county, region, demographic variants
- **Data**: Adult vaccines (18+) by county and statewide; demographic breakdown in separate file
- **Vaccines**: HPV, Hep A, Hep B (initiated + complete), Pneumococcal, Td/Tdap, Zoster
- **Notes**: Adult-only data (no childhood vaccines); percent column stored with `%` suffix — requires parsing
- **Output columns**: `iis_hepa_rate`, `iis_hepb_rate`, `iis_hepb_initiated_rate`, `iis_hpv_rate`, `iis_pneumo_rate`, `iis_tdap_rate`, `iis_tdap_any_rate`, `iis_zoster_rate`

### Virginia (`iis_va`)
- **Source**: Virginia Department of Health — VDH Open Data Portal
- **Platform**: CKAN portal (data.virginia.gov) — direct CSV download
- **Data**: Statewide and locality (county/city)-level COVID-19, influenza, and RSV vaccination coverage; weekly updates
- **Vaccines**: COVID-19, Influenza, RSV
- **Notes**: Data stratified by `INDICATOR` column (Age_Group, Race and Ethnicity, Sex); Age_Group rows used for primary output; FIPS codes included but must be zero-padded to 5 digits
- **Output columns**: `iis_covid_dose_count`, `iis_covid_people_count`, `iis_covid_rate`, `iis_flu_dose_count`, `iis_flu_people_count`, `iis_flu_rate`

### New York State (`iis_ny`)
- **Source**: New York State Immunization Information System (NYSIIS)
- **Platform**: Socrata open data API (health.data.ny.gov)
- **Dataset IDs**: `xrhr-cy84` (current season), archival datasets for prior years
- **Data**: Weekly COVID-19 and influenza dose counts by county; excludes NYC (separate CIR registry)
- **Notes**: NYC excluded from state data; county-level FIPS lookup via county name; state FIPS = "36"
- **Output columns**: `iis_covid_dose_count`, `iis_flu_dose_count`

### Texas (`iis_tx`)
- **Source**: Texas DSHS — ImmTrac2 Immunization Registry
- **Platform**: Single Excel file, monthly updates
- **URL**: `https://www.dshs.texas.gov/sites/default/files/LIDS-Immunizations/xls/immtrac2-doses-administered-for-web.xlsx`
- **Data**: Monthly dose counts by county and vaccine type (pediatric + adolescent categories)
- **Vaccines**: Pediatric MMR, Adolescent HPV, Adolescent MCV4, Adolescent Td/Tdap, All Other Vaccines
- **Notes**: ImmTrac2 is an opt-in consent registry — counts underrepresent true administration; data is counts, not rates; suppressed values encoded as `**`; sheet has 3 header rows requiring skip=3
- **Output columns**: `iis_mmr_count`, `iis_hpv_count`, `iis_mcv4_count`, `iis_tdap_count`, `iis_other_count`

### Indiana (`iis_in`)
- **Source**: Indiana CHIRP — Children and Hoosiers Immunization Registry Program
- **Platform**: CKAN portal (hub.mph.in.gov) — Excel files per school year
- **Data**: School immunization coverage by county and grade (K–12), school years 2023–2024 and 2024–2025
- **Vaccines**: DTaP/Td, Tdap, IPV, MMR, Hep B, Varicella, Hep A, MCV4
- **Notes**: Column names differ between school year files (spaces vs. underscores, "(CHIRP)" suffix); requires normalization; county aggregation via weighted mean by enrollment; enrollment count retained as separate measure
- **Output columns**: `iis_dtap_rate`, `iis_tdap_rate`, `iis_ipv_rate`, `iis_mmr_rate`, `iis_hepb_rate`, `iis_var_rate`, `iis_hepa_rate`, `iis_mcv4_rate`, `iis_enrollment_count`

---

## Tier 2: Requires API Reverse-Engineering (10 states)

These states use interactive dashboards (Tableau, ArcGIS, R Shiny) that do not offer direct file downloads. Data extraction requires identifying hidden API endpoints or using Tableau Server export URLs.

| State | Abbrev | Platform | Data Available |
|-------|--------|----------|----------------|
| Illinois | `iis_il` | Tableau (public.data.illinois.gov) | School vaccination, flu, COVID, Head Start; 4 dashboards |
| Iowa | `iis_ia` | Tableau (data.idph.state.ia.us) | Childhood (2yr) by county |
| Kansas | `iis_ks` | Tableau (kshealthdata.kdhe.ks.gov) | Kindergarten coverage, influenza |
| Louisiana | `iis_la` | Tableau (analytics.la.gov) | 7-Series, 10-Series, HPV by parish |
| Massachusetts | `iis_ma` | Tableau Server | RSV immunizations by county/town |
| Oregon | `iis_or` | Tableau Public | Child, adolescent, adult, school, respiratory; 11+ dashboards |
| North Carolina | `iis_nc` | Custom dashboard | COVID, Flu, RSV (adult + pediatric); download button present |
| California | `iis_ca` | ArcGIS Dashboard | COVID/respiratory vaccines; feature service URLs to reverse-engineer |
| Utah | `iis_ut` | R Shiny app | Early childhood, teen, adult, flu, school exemptions |
| NYC | `iis_nyc` | Open data portal | Childhood vaccination; portal timed out during recon |

**Recommended approach for Tableau states**: Use the Tableau Server REST API or the `?:format=csv` download URL pattern (`https://[server]/views/[workbook]/[view].csv`). Many Tableau Public dashboards support direct CSV export if the author has enabled it.

**Recommended approach for ArcGIS states**: Inspect the network requests in browser DevTools to identify the FeatureServer REST endpoint, then use `httr::GET` with the query parameters `f=json&where=1=1&outFields=*`.

---

## Tier 3: Blocked or No Structured Data (8 states)

These states either block automated access, require authentication, use formats with no extraction path, or have defunct dashboards.

| State | Abbrev | Issue | Recommendation |
|-------|--------|-------|----------------|
| Arizona | `iis_az` | Navigation page only; actual data behind restricted ASIIS portal | Contact AZ DHS for data access agreement |
| Colorado | `iis_co` | CloudFront WAF blocks automated access; returns 403/503 | Try rotating User-Agent; otherwise request data directly |
| Kentucky | `iis_ky` | Mixed system; unclear if public data extraction is feasible | Investigate further |
| New Jersey | `iis_nj` | Tableau Cloud; no direct data export visible | May require Tableau Connected App or manual export |
| North Dakota | `iis_nd` | Power BI Government Cloud with encrypted/token-based URLs | Power BI API requires Azure AD authentication |
| Rhode Island | `iis_ri` | ArcGIS Hub; limited data accessible via public APIs | Try ArcGIS REST endpoint discovery |
| Vermont | `iis_vt` | PDF reports only; no structured data export | Consider PDF parsing with `pdftools`; labor-intensive |
| West Virginia | `iis_wv` | Dashboard URL returns 404 | Dashboard appears defunct; check for alternative sources |

---

## Column Naming Convention

All output columns across all state scrapers follow a single shared convention to enable `dplyr::bind_rows()` directly across states:

```
iis_{agegroup}_{vaccine}_{suffix}
```

- **No state abbreviation** — the `geography` column (FIPS code) already identifies the state
- **Age group** (omit when `age` is a separate row dimension):
  - `infant` = 0–35 months
  - `child` = 4–6 years
  - `pread` = 9–10 years (pre-adolescent)
  - `preteen` = 11–12 years
  - `teen` = 13–17 years
  - `adult` = 18–64 years
  - `senior` = 65+ years
- **Canonical vaccine abbreviations**:

  | Column token | Vaccine |
  |---|---|
  | `dtap` | DTaP (diphtheria, tetanus, pertussis — pediatric) |
  | `tdap` | Tdap (tetanus, diphtheria, pertussis — adolescent/adult) |
  | `mmr` | MMR (measles, mumps, rubella) |
  | `hepb` | Hepatitis B |
  | `hepa` | Hepatitis A |
  | `ipv` | IPV (inactivated polio) |
  | `var` | Varicella (chickenpox) |
  | `hpv` | HPV |
  | `mcv4` | MCV4 (meningococcal conjugate) |
  | `pcv` | PCV (pneumococcal conjugate — pediatric) |
  | `hib` | Hib (Haemophilus influenzae type b) |
  | `rotavirus` | Rotavirus |
  | `series` | Combined series completion |
  | `covid` | COVID-19 |
  | `flu` | Influenza |
  | `zoster` | Zoster/Shingles |
  | `pneumo` | Pneumococcal (adult) |

- **Suffix**:
  - `_rate` — percentage (0–100 scale)
  - `_count` — integer count of doses or individuals
  - `_pop` — denominator/population

---

## Cross-State Column Overlap (Phase 1)

The table below shows which vaccines are available from each implemented state. Shared columns enable direct cross-state comparison after `bind_rows()`.

| Column | MN | TN | WA | WI | VA | NY | TX | IN |
|--------|----|----|----|----|----|----|----|----|
| `iis_*_dtap_rate` | ✓ | ✓ | ✓ | — | — | — | — | ✓ |
| `iis_*_mmr_rate` | ✓ | ✓ | ✓ | — | — | — | ✓ | ✓ |
| `iis_*_hepb_rate` | ✓ | ✓ | ✓ | ✓ | — | — | — | ✓ |
| `iis_*_hepa_rate` | — | ✓ | ✓ | ✓ | — | — | — | ✓ |
| `iis_*_ipv_rate` | ✓ | ✓ | ✓ | — | — | — | — | ✓ |
| `iis_*_var_rate` | ✓ | ✓ | ✓ | — | — | — | — | ✓ |
| `iis_*_hpv_rate` | ✓ | ✓ | ✓ | ✓ | — | — | ✓ | — |
| `iis_*_mcv4_rate` | ✓ | ✓ | ✓ | — | — | — | ✓ | ✓ |
| `iis_*_tdap_rate` | ✓ | ✓ | ✓ | ✓ | — | — | ✓ | ✓ |
| `iis_*_series_rate` | ✓ | ✓ | ✓ | — | — | — | — | — |
| `iis_*_pneumo_rate` | — | ✓ | — | ✓ | — | — | — | — |
| `iis_*_zoster_rate` | — | ✓ | — | ✓ | — | — | — | — |
| `iis_covid_dose_count` | — | — | — | — | ✓ | ✓ | — | — |
| `iis_flu_dose_count` | — | — | — | — | ✓ | ✓ | — | — |

---

## Implementation Status

| State | Directory | Status | Output files |
|-------|-----------|--------|--------------|
| Minnesota | `data/iis_mn` | Complete | `standard/data.csv.gz`, `standard/data_race.csv.gz` |
| Tennessee | `data/iis_tn` | Complete | `standard/data.csv.gz` |
| Washington | `data/iis_wa` | Complete | `standard/data.csv.gz`, `standard/data_race.csv.gz` |
| Wisconsin | `data/iis_wi` | Complete | `standard/data.csv.gz` |
| Virginia | `data/iis_va` | Complete | `standard/data.csv.gz`, `standard/data_race.csv.gz` |
| New York State | `data/iis_ny` | Complete | `standard/data.csv.gz` |
| Texas | `data/iis_tx` | Complete | `standard/data.csv.gz` |
| Indiana | `data/iis_in` | Complete | `standard/data.csv.gz` |
| Illinois | `data/iis_il` | Planned (Tier 2) | — |
| Iowa | `data/iis_ia` | Planned (Tier 2) | — |
| Kansas | `data/iis_ks` | Planned (Tier 2) | — |
| Louisiana | `data/iis_la` | Planned (Tier 2) | — |
| Massachusetts | `data/iis_ma` | Planned (Tier 2) | — |
| Oregon | `data/iis_or` | Planned (Tier 2) | — |
| North Carolina | `data/iis_nc` | Planned (Tier 2) | — |
| California | `data/iis_ca` | Planned (Tier 2) | — |
| Utah | `data/iis_ut` | Planned (Tier 2) | — |
| NYC | `data/iis_nyc` | Planned (Tier 2) | — |
| Arizona | `data/iis_az` | Blocked (Tier 3) | — |
| Colorado | `data/iis_co` | Blocked (Tier 3) | — |
| Kentucky | `data/iis_ky` | Blocked (Tier 3) | — |
| New Jersey | `data/iis_nj` | Blocked (Tier 3) | — |
| North Dakota | `data/iis_nd` | Blocked (Tier 3) | — |
| Rhode Island | `data/iis_ri` | Blocked (Tier 3) | — |
| Vermont | `data/iis_vt` | Blocked (Tier 3) | — |
| West Virginia | `data/iis_wv` | Defunct (Tier 3) | — |
