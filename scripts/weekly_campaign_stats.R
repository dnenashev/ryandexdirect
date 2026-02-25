#!/usr/bin/env Rscript
# -------------------------------------------------------------------
# Weekly Yandex Direct campaign stats → Google Sheets
#
# Формат таблицы:
#   Лист "По кампаниям"  — строки = недели × кампании, метрики в столбцах
#   Лист "Итого"         — строки = недели (сумма по всем кампаниям)
#   Лист "Кампании"      — справочник кампаний (перезаписывается)
#
# Данные накапливаются: каждый запуск дописывает новую неделю.
#
# Required env vars (set as GitHub Secrets):
#   YANDEX_DIRECT_TOKEN  – OAuth-токен Яндекс.Директ
#   YANDEX_DIRECT_LOGIN  – логин аккаунта / организации Яндекс.Директ
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

format_week_label <- function(date_from, date_to) {
  wn <- format(date_from, "%V")
  yr <- format(date_from, "%Y")
  paste0("W", wn, " (", format(date_from, "%d.%m"), "\u2013", format(date_to, "%d.%m.%Y"), ")")
}

yd_token <- stop_if_missing("YANDEX_DIRECT_TOKEN")
yd_login <- stop_if_missing("YANDEX_DIRECT_LOGIN")
gs_id    <- stop_if_missing("GOOGLE_SHEET_ID")
sa_json  <- stop_if_missing("GOOGLE_SA_KEY")

date_to   <- Sys.Date() - 1
date_from <- date_to - 6
week_label <- format_week_label(date_from, date_to)
week_sort  <- format(date_from, "%Y-W%V")

message("Report period: ", date_from, " \u2014 ", date_to, "  [", week_label, "]")

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
          "StartDate", "Currency", "DailyBudget"
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
      stop(data$error$error_string, " \u2014 ", data$error$error_detail)
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
      ID               = safe(c$Id),
      Кампания         = safe(c$Name),
      Тип              = safe(c$Type),
      Статус           = safe(c$State),
      Валюта           = safe(c$Currency),
      `Дата старта`    = safe(c$StartDate),
      `Дневной бюджет` = safe(c$DailyBudget$Amount, 0) / 1e6
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
    '<FieldNames>CampaignId</FieldNames>',
    '<FieldNames>CampaignName</FieldNames>',
    '<FieldNames>Impressions</FieldNames>',
    '<FieldNames>Clicks</FieldNames>',
    '<FieldNames>Cost</FieldNames>',
    '<FieldNames>Conversions</FieldNames>',
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
    read_tsv(I(content(resp, "text", encoding = "UTF-8")))
  )
}

message("Fetching weekly stats report...")
stats <- fetch_report(yd_token, yd_login, date_from, date_to)
message("Stats rows loaded: ", nrow(stats))

# ── Build weekly rows per campaign ───────────────────────────────────

by_campaign <- stats %>%
  group_by(CampaignId, CampaignName) %>%
  summarise(
    Показы     = sum(Impressions, na.rm = TRUE),
    Клики      = sum(Clicks, na.rm = TRUE),
    Расход     = round(sum(Cost, na.rm = TRUE), 2),
    Конверсии  = sum(Conversions, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    `CTR, %`  = round(ifelse(Показы > 0, Клики / Показы * 100, 0), 2),
    `CPC, ₽`  = round(ifelse(Клики > 0, Расход / Клики, 0), 2),
    `CPA, ₽`  = round(ifelse(Конверсии > 0, Расход / Конверсии, 0), 2)
  ) %>%
  arrange(desc(Расход))

new_campaign_rows <- by_campaign %>%
  transmute(
    Неделя    = week_label,
    `#`       = week_sort,
    Кампания  = CampaignName,
    Показы,
    Клики,
    `Расход, ₽` = Расход,
    `CTR, %`,
    `CPC, ₽`,
    Конверсии,
    `CPA, ₽`
  )

# ── Build weekly totals row ──────────────────────────────────────────

total_impressions  <- sum(by_campaign$Показы)
total_clicks       <- sum(by_campaign$Клики)
total_cost         <- sum(by_campaign$Расход)
total_conversions  <- sum(by_campaign$Конверсии)

new_total_row <- tibble(
  Неделя       = week_label,
  `#`          = week_sort,
  Кампаний     = nrow(by_campaign),
  Показы       = total_impressions,
  Клики        = total_clicks,
  `Расход, ₽`  = round(total_cost, 2),
  `CTR, %`     = round(ifelse(total_impressions > 0, total_clicks / total_impressions * 100, 0), 2),
  `CPC, ₽`     = round(ifelse(total_clicks > 0, total_cost / total_clicks, 0), 2),
  Конверсии    = total_conversions,
  `CPA, ₽`     = round(ifelse(total_conversions > 0, total_cost / total_conversions, 0), 2)
)

# ── Write to Google Sheets (accumulate) ──────────────────────────────

existing_sheets <- tryCatch(
  sheet_names(gs_id),
  error = function(e) character(0)
)

append_or_create <- function(sheet_id, sheet_name, new_data, sort_col = "#") {
  if (sheet_name %in% existing_sheets) {
    old_data <- tryCatch(
      read_sheet(sheet_id, sheet = sheet_name),
      error = function(e) tibble()
    )

    if (nrow(old_data) > 0 && sort_col %in% names(old_data)) {
      week_key <- new_data[[sort_col]][1]
      old_data <- old_data %>% filter(.data[[sort_col]] != week_key)
    }

    combined <- bind_rows(old_data, new_data) %>%
      arrange(.data[[sort_col]])

    range_clear(sheet_id, sheet = sheet_name)
    range_write(sheet_id, combined, sheet = sheet_name)
  } else {
    sheet_add(sheet_id, sheet = sheet_name)
    range_write(sheet_id, new_data, sheet = sheet_name)
  }
}

message("Writing to Google Sheets...")

append_or_create(gs_id, "\u041f\u043e \u043a\u0430\u043c\u043f\u0430\u043d\u0438\u044f\u043c", new_campaign_rows)
message("  \u2713 \u041f\u043e \u043a\u0430\u043c\u043f\u0430\u043d\u0438\u044f\u043c")

append_or_create(gs_id, "\u0418\u0442\u043e\u0433\u043e", new_total_row)
message("  \u2713 \u0418\u0442\u043e\u0433\u043e")

write_or_create <- function(sheet_id, sheet_name, data) {
  if (sheet_name %in% existing_sheets) {
    range_clear(sheet_id, sheet = sheet_name)
  } else {
    sheet_add(sheet_id, sheet = sheet_name)
  }
  range_write(sheet_id, data, sheet = sheet_name)
}

write_or_create(gs_id, "\u041a\u0430\u043c\u043f\u0430\u043d\u0438\u0438", campaigns)
message("  \u2713 \u041a\u0430\u043c\u043f\u0430\u043d\u0438\u0438")

# Clean up default Sheet1 if present
if ("Sheet1" %in% existing_sheets || "\u041b\u0438\u0441\u04421" %in% existing_sheets) {
  tryCatch({
    if ("Sheet1" %in% existing_sheets) sheet_delete(gs_id, sheet = "Sheet1")
    if ("\u041b\u0438\u0441\u04421" %in% existing_sheets) sheet_delete(gs_id, sheet = "\u041b\u0438\u0441\u04421")
  }, error = function(e) NULL)
}

message("\nDone! Data exported to Google Sheets:")
message("  https://docs.google.com/spreadsheets/d/", gs_id)
message("\n  \u041d\u0435\u0434\u0435\u043b\u044f: ", week_label)
message("  \u041f\u043e\u043a\u0430\u0437\u044b: ", total_impressions,
        " | \u041a\u043b\u0438\u043a\u0438: ", total_clicks,
        " | \u0420\u0430\u0441\u0445\u043e\u0434: ", round(total_cost, 2), " \u20bd",
        " | \u041a\u043e\u043d\u0432\u0435\u0440\u0441\u0438\u0438: ", total_conversions)
