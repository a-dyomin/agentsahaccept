# Агент «Акцепт вывоза» — теневой конвейер

Автоматизация проверки заявок САХ по ТЗ: Stage 1 (правила) + Stage 2 (vision по чек-листам) → склейка ИТОГ.

## Быстрый старт

```bash
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
copy .env.example .env
```

```bash
python -m accept_agent.cli check-s3
python -m accept_agent.cli stage1 --day 2026-07-12 --data-dir data/greta_exports
```

## Доступы (проверено 28.07.2026)

| | |
|---|---|
| S3 | Selectel `main` — OK (`S3_VERIFY_SSL=false` на этой сети) |
| Greta SSH | `gretaadmin@greta.akea-ds.ru -p 34023` — OK |
| Wialon API (`Wialon::Service`) | треки: ТРЕК/ВРЕМЯ. **Не** `vehicle_trackings` — таблица слишком большая |
| Координаты фото | `photo_exifs.lonlat` |
| Фото | S3 ActiveStorage keys в `main` |

## Stage 1 на CSV 12.07.2026

Прогон: **1129** «не взяты в работу», **7349** «Выполнено» (охват как в ТЗ).  
ГЕО/ТРЕК/ВРЕМЯ = `Н/Д` до join с Postgres.

## Дальше

1. Экспорт треков и EXIF из Greta DB за день  
2. ГЕО/ТРЕК/ВРЕМЯ + невывозы  
3. Stage 2 vision  
4. Склейка ИТОГ
