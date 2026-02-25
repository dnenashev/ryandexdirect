#!/usr/bin/env Rscript
# -------------------------------------------------------------------
# Weekly Yandex Direct campaign stats → Google Sheets
#
# Required env vars (set as GitHub Secrets):
#   YANDEX_DIRECT_TOKEN  – OAuth-токен Яндекс.Директ
#   YANDEX_DIRECT_LOGIN  – логин аккаунта Яндекс.Директ
#   GOOGLE_SHEET_ID      – ID целевой Google-таблицы
#   GOOGLE_SA_KEY        – JSON-ключ сервисного аккаунта Google (содержимое)
# -------------------------------------------------------------------

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(readr)
  library(data.table)
  library(googlesheets4)
  library(gargle)
})

# ── helpers ──────────────────────────────────────────────────────────

stop_if_missing <- function(var) {
  val <- Sys.getenv(var)
  if (val == "") stop(paste("Environment variable", var, "is not set"), call. = FALSE)
  val
}

yd_token <- stop_if_missing("YANDEX_DIRECT_TOKEN")
yd_login <- stop_if_missing("YANDEX_DIRECT_LOGIN")
gs_id    <- stop_if_missing("GOOGLE_SHEET_ID")
sa_json  <- stop_if_missing("GOOGLE_SA_KEY")

date_to   <- Sys.Date() - 1
date_from <- date_to - 6
message("Report period: ", date_from, " — ", date_to)

# ── Google Sheets auth (service account) ─────────────────────────────

sa_path <- tempfile(fileext = ".json")
writeLines(sa_json, sa_path)
gs4_auth(path = sa_path)
message("Google Sheets auth OK")

# ── Yandex Direct: campaign list ─────────────────────────────────────

fetch_campaigns <- function(token, login) {
  offset <- 0
  all_campaigns <- list()

  repeat {
    body <- list(
      method = "get",
      params = list(
        SelectionCriteria = list(
          States = list("ON", "SUSPENDED", "OFF", "ENDED")
        ),
        FieldNames = c(
          "Id", "Name", "Type", "State", "Status",
          "StartDate", "Statistics", "Currency",
          "DailyBudget", "Funds"
        ),
        Page = list(Limit = 10000, Offset = offset)
      )
    )

    resp <- POST(
      "https://api.direct.yandex.com/json/v5/campaigns",
      body = toJSON(body, auto_unbox = TRUE),
      add_headers(
        Authorization    = paste("Bearer", token),
        `Accept-Language` = "ru",
        `Client-Login`   = login
      ),
      content_type_json()
    )
    stop_for_status(resp)
    data <- content(resp, "parsed", "application/json")

    if (!is.null(data$error)) {
      stop(data$error$error_string, " — ", data$error$error_detail)
    }

    if (length(data$result$Campaigns) > 0) {
      all_campaigns <- c(all_campaigns, data$result$Campaigns)
    }

    if (is.null(data$result$LimitedBy)) break
    offset <- data$result$LimitedBy + 1
  }

  safe <- function(x, default = NA) if (is.null(x)) default else x

  map_dfr(all_campaigns, function(c) {
    tibble(
      CampaignId       = safe(c$Id),
      CampaignName     = safe(c$Name),
      CampaignType     = safe(c$Type),
      State            = safe(c$State),
      Status           = safe(c$Status),
      Currency         = safe(c$Currency),
      StartDate        = safe(c$StartDate),
      DailyBudget      = safe(c$DailyBudget$Amount, 0) / 1e6,
      TotalImpressions = safe(c$Statistics$Impressions, 0),
      TotalClicks      = safe(c$Statistics$Clicks, 0),
      FundsMode        = safe(c$Funds$Mode),
      AccountSpend     = safe(c$Funds$SharedAccountFunds$Spend, 0) / 1e6
    )
  })
}

message("Fetching campaign list...")
campaigns <- fetch_campaigns(yd_token, yd_login)
message("Campaigns loaded: ", nrow(campaigns))

# ── Yandex Direct: weekly statistics report ──────────────────────────

fetch_report <- function(token, login, date_from, date_to) {
  report_name <- paste0("WeeklyStats_", format(Sys.time(), "%Y%m%d_%H%M%S"))

  body_xml <- paste0(
    '<ReportDefinition xmlns="http://api.direct.yandex.com/v5/reports">',
    '<SelectionCriteria>',
    '<DateFrom>', date_from, '</DateFrom>',
    '<DateTo>', date_to, '</DateTo>',
    '</SelectionCriteria>',
    '<FieldNames>Date</FieldNames>',
    '<FieldNames>CampaignId</FieldNames>',
    '<FieldNames>CampaignName</FieldNames>',
    '<FieldNames>Impressions</FieldNames>',
    '<FieldNames>Clicks</FieldNames>',
    '<FieldNames>Cost</FieldNames>',
    '<FieldNames>Ctr</FieldNames>',
    '<FieldNames>AvgCpc</FieldNames>',
    '<FieldNames>Conversions</FieldNames>',
    '<FieldNames>CostPerConversion</FieldNames>',
    '<ReportName>', report_name, '</ReportName>',
    '<ReportType>CAMPAIGN_PERFORMANCE_REPORT</ReportType>',
    '<DateRangeType>CUSTOM_DATE</DateRangeType>',
    '<Format>TSV</Format>',
    '<IncludeVAT>YES</IncludeVAT>',
    '<IncludeDiscount>NO</IncludeDiscount>',
    '</ReportDefinition>'
  )

  send_request <- function() {
    POST(
      "https://api.direct.yandex.com/v5/reports",
      body = body_xml,
      add_headers(
        Authorization       = paste("Bearer", token),
        `Accept-Language`   = "ru",
        `Client-Login`      = login,
        skipReportHeader    = "true",
        skipReportSummary   = "true",
        returnMoneyInMicros = "false",
        processingMode      = "auto"
      ),
      content_type("application/xml; charset=utf-8")
    )
  }

  resp <- send_request()

  retries <- 0
  while (resp$status_code %in% c(201, 202) && retries < 60) {
    message("  report queued (", resp$status_code, "), waiting 5s...")
    Sys.sleep(5)
    resp <- send_request()
    retries <- retries + 1
  }

  if (resp$status_code != 200) {
    stop("Report request failed with status ", resp$status_code,
         ": ", content(resp, "text", encoding = "UTF-8"))
  }

  suppressMessages(
    read_tsv(content(resp, "text", encoding = "UTF-8"))
  )
}

message("Fetching weekly stats report...")
stats <- fetch_report(yd_token, yd_login, date_from, date_to)
message("Stats rows loaded: ", nrow(stats))

# ── Prepare summary sheet ────────────────────────────────────────────

summary_stats <- stats %>%
  group_by(CampaignId, CampaignName) %>%
  summarise(
    Impressions       = sum(Impressions, na.rm = TRUE),
    Clicks            = sum(Clicks, na.rm = TRUE),
    Cost              = sum(Cost, na.rm = TRUE),
    Conversions       = sum(Conversions, na.rm = TRUE),
    AvgCTR            = ifelse(sum(Impressions, na.rm = TRUE) > 0,
                               sum(Clicks, na.rm = TRUE) / sum(Impressions, na.rm = TRUE) * 100, 0),
    AvgCPC            = ifelse(sum(Clicks, na.rm = TRUE) > 0,
                               sum(Cost, na.rm = TRUE) / sum(Clicks, na.rm = TRUE), 0),
    CostPerConversion = ifelse(sum(Conversions, na.rm = TRUE) > 0,
                               sum(Cost, na.rm = TRUE) / sum(Conversions, na.rm = TRUE), 0),
    .groups = "drop"
  ) %>%
  arrange(desc(Cost))

run_meta <- tibble(
  Parameter = c("Login", "Period start", "Period end",
                "Total campaigns", "Total impressions",
                "Total clicks", "Total cost", "Report generated at"),
  Value = c(
    yd_login,
    as.character(date_from),
    as.character(date_to),
    as.character(nrow(summary_stats)),
    as.character(sum(summary_stats$Impressions)),
    as.character(sum(summary_stats$Clicks)),
    as.character(round(sum(summary_stats$Cost), 2)),
    format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")
  )
)

# ── Write to Google Sheets ───────────────────────────────────────────

sheet_names <- tryCatch(
  sheet_names(gs_id),
  error = function(e) character(0)
)

write_or_create <- function(sheet_id, sheet_name, data) {
  if (sheet_name %in% sheet_names) {
    range_clear(sheet_id, sheet = sheet_name)
  } else {
    sheet_add(sheet_id, sheet = sheet_name)
  }
  range_write(sheet_id, data, sheet = sheet_name)
}

message("Writing to Google Sheets...")

write_or_create(gs_id, "Meta", run_meta)
message("  ✓ Meta")

write_or_create(gs_id, "Campaigns", campaigns)
message("  ✓ Campaigns")

write_or_create(gs_id, "WeeklyStats", stats)
message("  ✓ WeeklyStats (daily breakdown)")

write_or_create(gs_id, "Summary", summary_stats)
message("  ✓ Summary (aggregated by campaign)")

message("Done! Data exported to Google Sheets: https://docs.google.com/spreadsheets/d/", gs_id)
