---
title: own-call-recorder — ручной рекордер + встроенная транскрибация
date: 2026-05-15
tags:
  - проект/workspace
  - подпроект/tools
  - тип/guide
  - область/tech
aliases:
  - own-call-recorder-readme
---

# own-call-recorder

Menu bar приложение для macOS 13+:

- запись запускается **по клику** или **глобальным хоткеем**
- запись останавливается **по клику** или **глобальным хоткеем**
- после остановки приложение само:
  - собирает общий аудиофайл
  - делает транскрипт
  - делает summary
  - сохраняет артефакты в `records/...`

`meeting_pipeline.py` для базового сценария больше не нужен.

## Что внутри

```
[Menu click / Global hotkey]
            ↓
[AudioRecorder] system + mic → merge/mp3
            ↓
[TranscriptionManager]
  - STT via Grok (xAI) or Groq Whisper (free)
  - Summary via API (Anthropic) or Cursor Agent
            ↓
[records/YYYY-MM-DD_HHmm/]
  - audio/recording.mp3|m4a
  - transcribe/transcript.txt (+ segments.json if provider returns speakers)
  - result/summary.md
  - result/metadata.json
```

## Требования

| Компонент | Минимум |
|---|---|
| macOS | 13 Ventura |
| Swift | 5.9 |
| ffmpeg | рекомендуется (`brew install ffmpeg`) |

## Права (TCC)

| Разрешение | Где | Зачем |
|---|---|---|
| Screen & System Audio Recording | System Settings → Privacy & Security | системный звук через ScreenCaptureKit |
| Microphone | System Settings → Privacy & Security | голос через AVAudioRecorder |
| Notifications (опц.) | System Settings → Notifications | этапные уведомления |

## Установка

Пошагово: [INSTALL.md](INSTALL.md). Коротко:

```bash
git clone https://github.com/Stillfrozen/own-call-recorder.git
cd own-call-recorder
brew install ffmpeg
swift build -c release
./scripts/install-app-launcher.sh
open /Applications/OwnRecorder.app
```

Не запускай голый `.build/.../OwnRecorder` — только `.app`. Иконка: `./scripts/build-app-icon.sh`.

## Работа из меню

- **Начать запись** — старт ручной записи
- **Остановить запись** — стоп + фоновая обработка
- **Открыть папку records** — открыть архив сессий
- **Настройки...** — открывает localhost-панель с конфигом/логами/healthcheck API

## Глобальные хоткеи

По умолчанию:

- Start: `cmd+shift+9`
- Stop: `cmd+shift+0`

Меняются в localhost-панели **Настройки** (`http://127.0.0.1:9780`).  
Формат: `cmd+shift+9`, `cmd+option+r`, `ctrl+shift+s`.

## Настройки в localhost-панели

По пункту меню **Настройки...** открывается `http://127.0.0.1:9780/`.

В панели доступны:

- `Summary mode`: `API нейронок` или `Headless Cursor Agent`
- `STT provider`: `Grok AI (xAI)` или `Groq Whisper (free)`
- `xAI API Key` (для STT Grok + fallback при ошибках Groq)
- `Groq API Key` + `Groq Whisper model`
- `Anthropic API Key` (для summary в API-режиме)
- `xAI STT language`, `Summary API model`, `Cursor model`
- `Cursor agent binary` (например `agent` или абсолютный путь)
- `Start/Stop hotkeys`
- переключатель системных уведомлений
- live healthcheck ключей (`✅ / ❌`) прямо рядом с полями
- live логи (автообновление)
- **история записей** в `records/` с путями и кнопкой **Перезапустить транскрибацию**

При выборе **Groq Whisper** и сбое STT (таймаут запроса, HTTP 429/408/5xx, сетевые ошибки) приложение автоматически повторяет распознавание через **xAI STT** (нужен xAI API key). В `metadata.json` поле `stt_fallback_from` будет `groq`.

Секреты сохраняются в Keychain.

### API записей (localhost:9780)

| Method | Path | Описание |
|--------|------|----------|
| `GET` | `/api/records` | Список сессий и статусы |
| `GET` | `/api/records/{sessionId}` | Одна сессия |
| `GET` | `/api/records/{sessionId}/status` | Статус + stage при обработке |
| `POST` | `/api/records/{sessionId}/reprocess` | Повтор STT + summary (409 если уже идёт) |
| `POST` | `/api/records/{sessionId}/reveal` | Открыть папку в Finder |

Статусы: `complete`, `transcribed_only`, `audio_only`, `failed`, `processing`. При ошибке пишется `result/error.txt`.

## Проверка после установки

1. Старт приложения и появление иконки в трее.
2. Проверка горячих клавиш Start/Stop.
3. Тест записи 15-30 секунд.
4. Проверка цвета иконки по стадиям:
   - красный: запись
   - желтый: транскрибация
   - голубой: суммаризация
5. Проверка артефактов в `records/YYYY-MM-DD_HHmm/`:
   - `audio/recording.*`
   - `transcribe/transcript.txt` (+ `segments.json` при наличии diarization у провайдера)
   - `result/summary.md`
   - `result/metadata.json`

## Папка результатов

После остановки записи создаётся сессия:

`own-call-recorder/records/<YYYY-MM-DD_HHmm>/`

Сводный список со ссылками — `records/INDEX.md` (новые сверху, пересобирается после каждой сессии). Старые папки `record-ddmmyy-hhmm` при старте приложения переименовываются в ISO.

Внутри:

- `audio/recording.mp3` (или `audio/recording.m4a`, если mp3 не собрался)
- `transcribe/transcript.txt`
- `transcribe/segments.json` (если провайдер вернул speaker-сегменты)
   - `result/summary.md`
   - `result/metadata.json`
6. В **Настройки** → вкладка **Записи**: запись видна в таблице; при сбое — **Перезапустить**.

## Уведомления по этапам

Приложение шлёт системные нотификации:

1. Начал запись
2. Закончил запись
3. Собран общий mp3 (или предупреждение о merge)
4. Отправил на транскрайб
5. Закончил транскрибацию/суммаризацию

Иконка в трее показывает текущий этап пайплайна:

- `красный` — идёт запись
- `желтый` — идёт транскрибация
- `голубой` — идёт обработка нейронкой (summary)

## Переменные окружения

| Переменная | По умолчанию | Описание |
|---|---|---|
| `OWN_RECORDER_LOG_PATH` | `~/Library/Logs/own-call-recorder/` | директория логов |
| `OWN_RECORDER_MIC` | `1` | `0/false/no` — не писать микрофон |
| `OWN_RECORDER_RECORDS_DIR` | авто (`.../own-call-recorder/records`) | корень архива сессий |
| `OWN_RECORDER_STT_TIMEOUT_SEC` | `900` | таймаут одного HTTP-запроса STT (сек) |
| `OWN_RECORDER_STT_RESOURCE_TIMEOUT_SEC` | `3600` | общий лимит загрузки/ответа STT (сек) |

Файлы **>12 MB** перед STT сжимаются через **ffmpeg** (16 kHz mono, 32 kbps). Записи **длиннее ~8 минут** режутся на куски по **10 минут** и транскрибируются по очереди (иначе облако обрывает запрос по таймауту). Переменные: `OWN_RECORDER_STT_CHUNK_THRESHOLD_SEC`, `OWN_RECORDER_STT_CHUNK_SEC`.

## Отладка

```bash
tail -f ~/Library/Logs/own-call-recorder/own-call-recorder.log
```

Если зависает сборка общего файла:

- убедись, что `ffmpeg` установлен (`which ffmpeg`)
- заверши зависший процесс: `killall ffmpeg`
- проверь строки `ffmpeg merge starting` / `ffmpeg merge done` в логе

## Связанные заметки

- [[OWN_RECORDER_PROJECT_PLAN]]
- [[HOW_IT_WORKS]]
