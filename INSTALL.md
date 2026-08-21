---
title: Own Recorder — установка на macOS
date: 2026-08-18
tags:
  - проект/workspace
  - подпроект/tools
  - тип/guide
  - область/tech
  - дата/2026-08-18
---

# Own Recorder — установка

Menu bar рекордер: системный звук + микрофон → транскрипт → конспект. Запуск только через `.app` в `/Applications`, не через голый бинарь из `.build`.

Репозиторий: [Stillfrozen/own-call-recorder](https://github.com/Stillfrozen/own-call-recorder).

## Что нужно

| Компонент | Зачем |
|-----------|--------|
| macOS 13+ | ScreenCaptureKit |
| Xcode Command Line Tools (`swift`) | сборка |
| [Homebrew](https://brew.sh) + `ffmpeg` | склейка system+mic и mp3 |
| Ключи xAI и/или Groq | STT |
| Ключ Anthropic **или** бинарь Cursor `agent` | конспект |

```bash
xcode-select --install   # если swift ещё нет
brew install ffmpeg
```

## Сборка и установка

```bash
git clone https://github.com/Stillfrozen/own-call-recorder.git
cd own-call-recorder
swift build -c release
./scripts/build-app-icon.sh          # если нет Resources/AppIcon.icns
./scripts/install-app-launcher.sh
open /Applications/OwnRecorder.app
```

Скрипт кладёт `/Applications/OwnRecorder.app`, пишет в бандл путь к `records/` **этого клона** и делает ad-hoc подпись. Без подписи уведомления и TCC ведут себя плохо.

Другой путь установки (без прав на `/Applications`):

```bash
OWN_RECORDER_APP_DIR="$HOME/Applications/OwnRecorder.app" ./scripts/install-app-launcher.sh
open "$HOME/Applications/OwnRecorder.app"
```

Не запускай `.build/.../OwnRecorder`: иконка в Cmd+Tab пустая, папка записей может стать `/records`.

После `git pull` снова: `swift build -c release && ./scripts/install-app-launcher.sh`, затем выйти из трея и `open` ещё раз.

## Права macOS

При первом старте записи система спросит. Если отказал — вручную:

1. **Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука** — включить OwnRecorder. Это звук встречи, не постоянная запись картинки.
2. Там же → **Микрофон** — OwnRecorder.
3. Если macOS спросит уведомления — можно разрешить. Оффер «началась встреча в Толке» всё равно идёт **панелью на экране**, не только баннером (ad-hoc приложению Центр уведомлений часто закрыт).

Путь `.app` лучше не менять: иначе TCC спросит снова.

## Первый запуск

1. В трее — микрофон.
2. Меню → **Настройки...** — браузер откроет `http://127.0.0.1:9780/?token=…` (токен сессии, только с этой машины). Панель слушает **только loopback**, без токена API отвечает 401. Ключи в JSON не отдаются, поля парольные:
   - STT: Grok (xAI) или Groq Whisper;
   - ключи в соответствующие поля (лежат в Keychain; пустое поле при сохранении ключ не затирает);
   - конспект: API Anthropic или Cursor Agent (`agent` в PATH или полный путь);
   - хоткеи: по умолчанию Start `⌘⇧9`, Stop `⌘⇧0`.
3. Короткая запись 15–30 с. Стоп. Должны появиться:
   - `records/YYYY-MM-DD_HHmm/audio/recording.*`
   - `transcribe/transcript.txt`
   - `result/summary.md`
   - строка в `records/INDEX.md`

Автозагрузка: Системные настройки → Основные → Объекты входа → `+` → OwnRecorder.

## Толк

Если открыт десктоп **Контур.Толк** (`Толк.app`) и появляется **второе** большое окно (звонок, календарь может висеть), через ~6 с сверху экрана панель: **Начать запись** / **Закрыть уведомление**. Zoom в этой версии не предлагается. Автостарта нет.

## Трей

| Состояние | Что видно |
|-----------|-----------|
| Ожидание | микрофон под цвет меню-бара |
| Запись | микрофон + красная точка |
| Транскрибация | оранжевый waveform |
| Сводка | бирюзовый текст |
| Транскрипт готов | зелёная точка (сброс — новая запись или «Открыть папку records») |

## Если сломалось

```bash
tail -f ~/Library/Logs/own-call-recorder/own-call-recorder.log
```

| Симптом | Что проверить |
|---------|----------------|
| Нет новых папок в `records/` | В логе `Records root:` должен быть `.../own-call-recorder/records`, не `/records`. Переустанови `.app` из этого клона. |
| Нет системного звука | TCC «Запись экрана», ffmpeg: `which ffmpeg`. |
| Нет панели Толка | В логе `TalkMeetingDetector: meeting started`. Нужен десктоп Толк, не вкладка в Chrome. |
| Голый бинарь / нет иконки | Запускай `/Applications/OwnRecorder.app`. |

Старые папки `record-ddmmyy-hhmm` при старте переименовываются в `YYYY-MM-DD_HHmm`.
