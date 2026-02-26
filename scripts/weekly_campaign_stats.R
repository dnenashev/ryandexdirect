#!/usr/bin/env Rscript
# -------------------------------------------------------------------
# Weekly Yandex Direct campaign stats → Google Sheets
#
# Поддержка нескольких аккаунтов. Одна вкладка «Статистика».
# Данные накапливаются: каждый запуск дописывает новую неделю.
#
# Env vars (GitHub Secrets):
#   YANDEX_ACCOUNTS      – JSON-массив аккаунтов:
#                          [{"login":"porg-xxx","token":"y0__..."},...]
#   GOOGLE_SHEET_ID      – ID целевой Google-таблицы
#   GOOGLE_SA_KEY        – JSON-ключ сервисного аккаунта Google
#
# Для обратной совместимости также поддерживается:
#   YANDEX_DIRECT_TOKEN  + YANDEX_DIRECT_LOGIN  (один аккаунт)
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

format_week_label <- function(date_from, date_to) {
  wn <- format(date_from, "%V")
  paste0("W", wn, " (", format(date_from, "%d.%m"), "\u2013", format(date_to, "%d.%m"), ")")
}

# ── parse accounts ───────────────────────────────────────────────────

accounts_json <- Sys.getenv("YANDEX_ACCOUNTS")

if (accounts_json != "") {
  accounts <- fromJSON(accounts_json)
  message("Accounts from YANDEX_ACCOUNTS: ", nrow(accounts))
} else {
  accounts <- data.frame(
    login = stop_if_missing("YANDEX_DIRECT_LOGIN"),
    token = stop_if_missing("YANDEX_DIRECT_TOKEN"),
    stringsAsFactors = FALSE
  )
  message("Single account: ", accounts$login[1])
}

gs_id   <- stop_if_missing("GOOGLE_SHEET_ID")
sa_json <- stop_if_missing("GOOGLE_SA_KEY")

# ── date range: last completed calendar week (Mon–Sun) ───────────────

today     <- Sys.Date()
wday      <- as.integer(format(today, "%u"))
date_from <- today - wday - 6
date_to   <- date_from + 6
week_label <- format_week_label(date_from, date_to)
week_sort  <- format(date_from, "%G-W%V")

message("Report period: ", date_from, " \u2014 ", date_to, "  [", week_label, "]")

# ── Google Sheets auth ───────────────────────────────────────────────

sa_path <- tempfile(fileext = ".json")
writeLines(sa_json, sa_path)
gs4_auth(path = sa_path)
message("Google Sheets auth OK")

# ── fetch report from Yandex Direct ─────────────────────────────────

fetch_report <- function(token, login, date_from, date_to) {
  report_name <- paste0("Weekly_", login, "_", format(Sys.time(), "%Y%m%d_%H%M%S"))

  body_xml <- paste0(
    '<ReportDefinition xmlns="http://api.direct.yandex.com/v5/reports">',
    '<SelectionCriteria>',
    '<DateFrom>', date_from, '</DateFrom>',
    '<DateTo>', date_to, '</DateTo>',
    '</SelectionCriteria>',
    '<FieldNames>CampaignId</FieldNames>',
    '<FieldNames>CampaignName</FieldNames>',
    '<FieldNames>Impressions</FieldNames>',
    '<FieldNames>Clicks</FieldNames>',
    '<FieldNames>Cost</FieldNames>',
    '<FieldNames>Conversions</FieldNames>',
    '<FieldNames>AvgTrafficVolume</FieldNames>',
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
    warning("Report failed for ", login, ": status ", resp$status_code)
    return(tibble())
  }

  suppressMessages(read_tsv(I(content(resp, "text", encoding = "UTF-8"))))
}

# ── collect data from all accounts ───────────────────────────────────

all_new_rows <- tibble()

for (i in seq_len(nrow(accounts))) {
  acc_login <- accounts$login[i]
  acc_token <- accounts$token[i]
  message("\n[", i, "/", nrow(accounts), "] ", acc_login)

  stats <- fetch_report(acc_token, acc_login, date_from, date_to)
  if (nrow(stats) == 0) {
    message("  (no data)")
    next
  }

  rows <- stats %>%
    group_by(CampaignId, CampaignName) %>%
    summarise(
      Показы    = sum(Impressions, na.rm = TRUE),
      Клики     = sum(Clicks, na.rm = TRUE),
      Расход    = round(sum(Cost, na.rm = TRUE), 2),
      Конверсии = sum(Conversions, na.rm = TRUE),
      `Ср. объём трафика` = round(mean(AvgTrafficVolume, na.rm = TRUE), 1),
      .groups = "drop"
    ) %>%
    mutate(
      `CTR, %` = round(ifelse(Показы > 0, Клики / Показы * 100, 0), 2),
      `CPC, ₽` = round(ifelse(Клики > 0, Расход / Клики, 0), 2),
      `CPA, ₽` = round(ifelse(Конверсии > 0, Расход / Конверсии, 0), 2)
    ) %>%
    arrange(desc(Расход)) %>%
    transmute(
      Неделя      = week_label,
      `#`         = week_sort,
      Аккаунт     = acc_login,
      Кампания    = CampaignName,
      Показы,
      Клики,
      `Расход, ₽` = Расход,
      `CTR, %`,
      `CPC, ₽`,
      Конверсии,
      `CPA, ₽`,
      `Ср. объём трафика`
    )

  all_new_rows <- bind_rows(all_new_rows, rows)
  message("  ", nrow(rows), " campaigns, cost: ", sum(rows$`Расход, ₽`))
}

message("\nNew rows total: ", nrow(all_new_rows))

# ── write to Google Sheets (accumulate) ──────────────────────────────

SHEET_NAME <- "Статистика"

existing_sheets <- tryCatch(
  sheet_names(gs_id),
  error = function(e) character(0)
)

message("Writing to Google Sheets...")

if (SHEET_NAME %in% existing_sheets) {
  old_data <- tryCatch(
    read_sheet(gs_id, sheet = SHEET_NAME, col_types = "c"),
    error = function(e) tibble()
  )

  if (nrow(old_data) > 0 && "#" %in% names(old_data)) {
    old_data <- old_data %>% filter(`#` != week_sort)
  }

  new_rows_c <- all_new_rows %>% mutate(across(everything(), as.character))
  combined <- bind_rows(old_data, new_rows_c) %>% arrange(`#`, Аккаунт, desc(`Расход, ₽`))

  num_cols <- c("Показы", "Клики", "Расход, ₽", "CTR, %", "CPC, ₽",
                "Конверсии", "CPA, ₽", "Ср. объём трафика")
  for (col in intersect(num_cols, names(combined))) {
    combined[[col]] <- as.numeric(combined[[col]])
  }

  range_clear(gs_id, sheet = SHEET_NAME)
  range_write(gs_id, combined, sheet = SHEET_NAME)
} else {
  sheet_add(gs_id, sheet = SHEET_NAME)
  range_write(gs_id, all_new_rows, sheet = SHEET_NAME)
}

message("  \u2713 ", SHEET_NAME)

# Clean up unused sheets
for (s in setdiff(existing_sheets, SHEET_NAME)) {
  tryCatch(sheet_delete(gs_id, sheet = s), error = function(e) NULL)
}

message("\nDone! https://docs.google.com/spreadsheets/d/", gs_id)
total_cost <- sum(all_new_rows$`Расход, ₽`)
message("\n  ", week_label)
message("  Аккаунтов: ", nrow(accounts),
        " | Показы: ", sum(all_new_rows$Показы),
        " | Клики: ", sum(all_new_rows$Клики),
        " | Расход: ", round(total_cost, 2), " \u20bd",
        " | Конверсии: ", sum(all_new_rows$Конверсии))
