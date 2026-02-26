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
    ReportsAPI["/v5/reports"]
  end

  subgraph GoogleSheets ["Google Sheets"]
    Stats["Лист: Статистика"]
  end

  Cron --> GHA --> Script
  Secrets --> Script
  Script -->|"CAMPAIGN_PERFORMANCE_REPORT"| ReportsAPI
  Script -->|"googlesheets4"| Stats
```

## Потоки данных

```mermaid
sequenceDiagram
  participant GHA as GitHub Actions
  participant Script as R Script
  participant YD as Yandex Direct API
  participant GS as Google Sheets

  GHA->>Script: Запуск по расписанию (cron) или вручную
  Script->>YD: POST /v5/reports (статистика за 7 дней)
  YD-->>Script: TSV (CampaignId, Impressions, Clicks, Cost, Conversions, AvgTrafficVolume)
  Script->>Script: Агрегация по кампаниям, расчёт CTR/CPC/CPA
  Script->>GS: Чтение существующих данных из листа "Статистика"
  Script->>GS: Дозапись новой недели (или замена, если неделя уже есть)
```

## Структура Google Sheets

Одна вкладка **«Статистика»** — данные накапливаются понедельно:

| Столбец | Описание |
|---------|----------|
| **Неделя** | Метка недели, напр. `W08 (18.02–24.02)` |
| **#** | Сортировочный ключ, напр. `2026-W08` |
| **Аккаунт** | Логин аккаунта/организации Яндекс.Директ |
| **Кампания** | Название кампании |
| **Показы** | Сумма показов за неделю |
| **Клики** | Сумма кликов за неделю |
| **Расход, ₽** | Сумма расходов за неделю (с НДС) |
| **CTR, %** | Click-through rate |
| **CPC, ₽** | Средняя цена клика |
| **Конверсии** | Сумма конверсий за неделю |
| **CPA, ₽** | Средняя цена конверсии |
| **Ср. объём трафика** | Средний объём трафика (AvgTrafficVolume) |

## Необходимые секреты (GitHub Secrets)

| Секрет | Описание |
|--------|----------|
| `YANDEX_DIRECT_TOKEN` | OAuth-токен Яндекс.Директ (с правом `passport:business` для организаций) |
| `YANDEX_DIRECT_LOGIN` | Логин аккаунта или организации Яндекс.Директ (напр. `porg-xxx` для паспортной организации) |
| `GOOGLE_SHEET_ID` | ID целевой Google-таблицы (из URL) |
| `GOOGLE_SA_KEY` | JSON-ключ сервисного аккаунта Google (полное содержимое файла) |
