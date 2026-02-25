# AGENTS.md

## Cursor Cloud specific instructions

### Overview
This is `ryandexdirect` — an R package (CRAN) for loading data from the Yandex Direct advertising API (v4, Live 4, v5) into R. There are no backend services, databases, or Docker containers — it is a pure client-side API wrapper library.

### System dependencies
R (>= 3.5.0) must be installed from the CRAN repository (Ubuntu: `r-base`, `r-base-dev`). The following system libraries are also required for building R package dependencies: `libcurl4-openssl-dev`, `libssl-dev`, `libxml2-dev`, `libharfbuzz-dev`, `libfribidi-dev`, `libfreetype6-dev`, `libpng-dev`, `libtiff5-dev`, `libjpeg-dev`, `libfontconfig1-dev`, `pandoc`.

### Development commands
- **Load package in dev mode:** `Rscript -e 'devtools::load_all()'` (from repo root)
- **Build tarball:** `R CMD build .` (from repo root)
- **Check package:** `_R_CHECK_FORCE_SUGGESTS_=false R CMD check --no-manual <tarball>` or `Rscript -e 'devtools::check(args="--no-manual")'`
- **Lint:** `Rscript -e 'lintr::lint_package()'`
- **Generate docs:** `Rscript -e 'devtools::document()'`

### Known issues
- `httr2` is used in `NAMESPACE` (`import(httr2)`) but is **not** listed in `DESCRIPTION` Imports. This causes `R CMD check` to fail with an ERROR about "Namespace dependency missing from DESCRIPTION". The package still loads fine via `devtools::load_all()`.
- `googleAnalyticsR` is listed as a Suggested dependency but is not always available. Use `_R_CHECK_FORCE_SUGGESTS_=false` when running `R CMD check`.
- There are no automated tests (`tests/` directory does not exist).

### API credentials
All API-calling functions (`yadirGetReport`, `yadirGetCampaignList`, etc.) require a valid Yandex Direct OAuth token obtained via `yadirAuth()`. This is an interactive browser-based flow that cannot run in non-interactive/headless mode. Tokens are cached as `.RData` files in the working directory.

### Useful non-API functions for testing
- `date_ranges(start, end, by)` — generates date range chunks (no API needed)
- `yadirToList(df)` — converts data.frame (no API needed)
- `yadirTokenPath()` — returns the default token storage path
