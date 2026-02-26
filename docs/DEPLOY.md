# Деплой: еженедельный экспорт статистики Яндекс.Директ → Google Sheets

## Что делает

Каждый понедельник в 07:00 UTC GitHub Actions запускает скрипт `scripts/weekly_campaign_stats.R`, который:

1. Загружает статистику по кампаниям из Яндекс.Директ за прошедшую неделю
2. Дозаписывает строки в Google-таблицу (лист «Статистика»)

Данные накапливаются — каждая неделя добавляется отдельными строками.

---

## Предварительные требования

### 1. OAuth-приложение Яндекс (один раз)

Если ваш аккаунт — **паспортная организация** (логин вида `porg-xxx`), приложение должно иметь два права доступа.

1. Зайти на [oauth.yandex.ru](https://oauth.yandex.ru/) → **Создать приложение**
2. Добавить доступы:
   - `Яндекс ID → Работа с организациями Яндекс ID` (`passport:business`)
   - `Яндекс.Директ → Использование API Яндекс.Директа` (`direct:api`)
3. Платформа: **Веб-сервисы**, Redirect URI: `https://oauth.yandex.ru/verification_code`
4. Сохранить → запомнить **ClientID**

Если логин обычный (не `porg-`), можно использовать встроенный ClientID пакета: `365a2d0a675c462d90ac145d4f5948cc`.

### 2. OAuth-токен Яндекс.Директ

Открыть в браузере (подставив ваш ClientID):

```
https://oauth.yandex.ru/authorize?response_type=token&client_id=ВАШ_CLIENT_ID&force_confirm=1
```

- Для организации: при авторизации **выбрать организацию**, а не личный аккаунт
- Скопировать `access_token` из URL после редиректа

> Токен действует ~1 год. При истечении — повторить этот шаг и обновить секрет.

### 3. Google-таблица

1. Создать пустую таблицу на [sheets.google.com](https://sheets.google.com)
2. Скопировать **ID** из URL: `https://docs.google.com/spreadsheets/d/ЭТОТ_ID/edit`

### 4. Сервисный аккаунт Google

1. [Google Cloud Console](https://console.cloud.google.com/) → создать/выбрать проект
2. **APIs & Services → Enable APIs** → включить **Google Sheets API**
3. **IAM & Admin → Service Accounts → Create Service Account**
4. Кликнуть на аккаунт → **Keys → Add Key → Create new key → JSON** → скачать файл
5. Скопировать `client_email` из JSON (вида `name@project.iam.gserviceaccount.com`)
6. В Google-таблице нажать **Поделиться** → вставить email → роль **Редактор**

---

## Настройка GitHub Secrets

В репозитории: **Settings → Secrets and variables → Actions → New repository secret**

| Secret name | Значение | Пример |
|---|---|---|
| `YANDEX_DIRECT_TOKEN` | OAuth-токен | `y0__xCky...` |
| `YANDEX_DIRECT_LOGIN` | Логин аккаунта/организации | `porg-3d2vffmf` |
| `GOOGLE_SHEET_ID` | ID Google-таблицы | `1R_SQTt497jaJs...` |
| `GOOGLE_SA_KEY` | Полное содержимое JSON-файла сервисного аккаунта | `{"type":"service_account",...}` |

---

## Запуск

### Автоматически

Workflow запускается каждый понедельник в 07:00 UTC по cron:

```
.github/workflows/weekly-stats.yml
```

### Вручную

GitHub → **Actions → Weekly Campaign Stats to Google Sheets → Run workflow**

### Локально

```bash
export YANDEX_DIRECT_TOKEN="..."
export YANDEX_DIRECT_LOGIN="..."
export GOOGLE_SHEET_ID="..."
export GOOGLE_SA_KEY="$(cat path/to/sa-key.json)"

Rscript scripts/weekly_campaign_stats.R
```

---

## Формат таблицы

Лист **«Статистика»** — одна строка = одна кампания за одну неделю:

| Столбец | Описание |
|---------|----------|
| Неделя | `W08 (18.02–24.02)` |
| # | Сортировочный ключ `2026-W08` |
| Аккаунт | Логин аккаунта/организации |
| Кампания | Название кампании |
| Показы | Impressions |
| Клики | Clicks |
| Расход, ₽ | Cost (с НДС) |
| CTR, % | Клики / Показы × 100 |
| CPC, ₽ | Расход / Клики |
| Конверсии | Conversions |
| CPA, ₽ | Расход / Конверсии |
| Ср. объём трафика | AvgTrafficVolume |

Данные накапливаются: повторный запуск за ту же неделю **заменяет** старые строки этой недели.

---

## Обновление токена

OAuth-токен Яндекс действует ~1 год. При ошибке `53 — Ошибка авторизации`:

1. Повторить шаг «OAuth-токен» из раздела выше
2. Обновить секрет `YANDEX_DIRECT_TOKEN` в GitHub Settings

---

## Устранение проблем

| Ошибка | Причина | Решение |
|--------|---------|---------|
| `Environment variable ... is not set` | Не настроен секрет | Добавить в GitHub Secrets |
| `Ошибка авторизации` / `expired_token` | Токен истёк | Получить новый токен |
| `Объект не найден` / `несуществующий логин` | Неверный `YANDEX_DIRECT_LOGIN` | Проверить логин, для организации нужен токен с `passport:business` |
| `403` от Google Sheets | Нет доступа | Проверить, что email сервисного аккаунта добавлен как Редактор |
| `Google Sheets API has not been enabled` | API не включён | Включить Google Sheets API в Cloud Console |
