# ryandexdirect — Архитектура и обзор

## Общая архитектура пакета

```mermaid
flowchart LR
  subgraph ryandexdirect ["R-пакет ryandexdirect"]
    Auth[yadirAuth / yadirGetToken]
    Campaigns[yadirGetCampaign]
    Report[yadirGetReport]
    CostData[yadirGetCostData]
    Balance[yadirGetBalance]
    Manage["Управление: Start/Stop Campaigns, Ads, Keywords"]
    Bids[yadirSetKeyWordsBids]
  end

  Token[(OAuth Token)]
  API["Yandex Direct API v5"]

  Auth --> Token
  Token --> Campaigns
  Token --> Report
  Token --> CostData
  Token --> Balance
  Token --> Manage
  Token --> Bids

  Campaigns --> API
  Report --> API
  CostData --> API
  Balance --> API
  Manage --> API
  Bids --> API
```

## Еженедельный экспорт статистики (GitHub Actions)

```mermaid
flowchart TB
  Cron["⏰ Cron: каждый понедельник 07:00 UTC"]
  GHA["GitHub Actions Runner"]
  Script["scripts/weekly_campaign_stats.R"]

  subgraph Secrets ["GitHub Secrets"]
    YDToken[YANDEX_DIRECT_TOKEN]
    YDLogin[YANDEX_DIRECT_LOGIN]
    GSID[GOOGLE_SHEET_ID]
    GSAK[GOOGLE_SA_KEY]
  end

  subgraph YandexDirect ["Yandex Direct API"]
    CampaignsAPI["/v5/campaigns"]
    ReportsAPI["/v5/reports"]
  end

  subgraph GoogleSheets ["Google Sheets"]
    Meta["Лист: Meta"]
    Camp["Лист: Campaigns"]
    Weekly["Лист: WeeklyStats"]
    Summary["Лист: Summary"]
  end

  Cron --> GHA --> Script
  Secrets --> Script
  Script -->|"список кампаний"| CampaignsAPI
  Script -->|"статистика за неделю"| ReportsAPI
  Script -->|"googlesheets4"| Meta
  Script --> Camp
  Script --> Weekly
  Script --> Summary
```

## Потоки данных

```mermaid
sequenceDiagram
  participant GHA as GitHub Actions
  participant Script as R Script
  participant YD as Yandex Direct API
  participant GS as Google Sheets

  GHA->>Script: Запуск по расписанию (cron)
  Script->>YD: GET /v5/campaigns (список кампаний)
  YD-->>Script: JSON (кампании, бюджеты, статус)
  Script->>YD: POST /v5/reports (статистика за 7 дней)
  YD-->>Script: TSV (Date, CampaignId, Clicks, Cost, ...)
  Script->>Script: Агрегация и подготовка данных
  Script->>GS: Запись лист "Meta" (параметры запуска)
  Script->>GS: Запись лист "Campaigns" (список кампаний)
  Script->>GS: Запись лист "WeeklyStats" (ежедневная разбивка)
  Script->>GS: Запись лист "Summary" (сводка по кампаниям)
```

## Структура Google Sheets

| Лист | Содержимое |
|------|-----------|
| **Meta** | Логин, период, дата генерации, итоги |
| **Campaigns** | Полный список кампаний с бюджетами и статусами |
| **WeeklyStats** | Подневная статистика: показы, клики, расход, CTR, CPC, конверсии |
| **Summary** | Агрегация за неделю по кампаниям: общие расходы, клики, CPA |

## Необходимые секреты (GitHub Secrets)

| Секрет | Описание |
|--------|----------|
| `YANDEX_DIRECT_TOKEN` | OAuth-токен Яндекс.Директ |
| `YANDEX_DIRECT_LOGIN` | Логин аккаунта Яндекс.Директ |
| `GOOGLE_SHEET_ID` | ID целевой Google-таблицы |
| `GOOGLE_SA_KEY` | JSON-ключ сервисного аккаунта Google (полное содержимое) |
