# Новый Робинзон — порт на macOS

Нативный порт квеста «Новый Робинзон» (Nikita, 1999) на macOS. Написан на Swift и SpriteKit.
Оригинальный движок (`Roby.exe`, `NGI32.DLL`, `MiniGame.dll`) полностью разобран, и его логика переписана заново.
Игра читает **оригинальные файлы данных** без конвертации.

> ⚠️ В репозитории нет ни одного ресурса игры: графики, звука, видео и текстов.
> Для запуска нужна своя копия оригинального диска.

## Требования

- macOS 13 или новее
- Xcode или Command Line Tools со Swift 5.9+ (`xcode-select --install`)
- Файлы оригинальной игры «Новый Робинзон»

## Подготовка данных

Скопируй содержимое установленной игры (или CD) в папку `GameData/` в корне репозитория.
Движок ищет данные в `GameData/DATA` и берёт часть файлов мини-игр уровнем выше:

```
Roby/
├── Package.swift
├── Sources/
└── GameData/
    ├── BALOON.DAT  CHESS.DAT  CRYPT.DAT      ← мини-игры
    ├── HOUSE.DAT   MAP.DAT    PIPE.DAT
    ├── MINIGAME.WDT  MINIGAME.SDT            ← звуки и анимации мини-игр
    └── DATA/
        ├── STARTUP.DAN
        ├── OPTIONS.DAT
        ├── SLIDER.WAV
        ├── BAR/      ← панель инвентаря
        ├── CHAR/     ← персонажи
        ├── SCEN/     ← сцены
        ├── MOVIE/    ← катсцены (.MV)
        └── WAVE/     ← звук (WAVE.DAN)
```

Папка `GameData/` добавлена в `.gitignore`, поэтому в коммит она не попадёт.

## Сборка и запуск

```bash
swift build --product Roby
.build/debug/Roby
```

Релизная сборка:

```bash
swift build -c release --product Roby
.build/release/Roby
```

Бинарник ищет `GameData/DATA` в таком порядке:
1. в текущей директории;
2. рядом с бинарником;
3. в `~/Desktop/Develop/Roby/GameData/DATA`.

Поэтому проще всего запускать из корня репозитория.

## Управление

| Действие | Клавиша / мышь |
|---|---|
| Идти, взаимодействовать | левая кнопка мыши |
| Выбрать предмет | клик по панели внизу |
| Прокрутка сцены | ← / → |
| Меню | Esc |
| Пропустить катсцену | Esc |
| Сохранить / загрузить | S / L |

Сохранения лежат в `~/Library/Application Support/NovyRobinzon/`: это `saveN.json` и миниатюра `saveN.png`.

## Структура кода

| Модуль | Что внутри |
|---|---|
| `Sources/ResourceKit` | Разбор форматов оригинала: контейнер NL (LFSR-шифрование), распаковщик NGI (Huffman+LZSS), NGB, палитры COL, ролики MV/SCR, скрипты DAN (SCN/OB/FS/CHR/LST), поиск пути по сетке |
| `Sources/Roby` | Само приложение: сцены, персонажи, скриптовый движок и катсцены, инвентарь, меню, сохранения, звук и шесть мини-игр (карта, дом, шахматы, шар, орган, склеп) |
| `Sources/RobyTool` | CLI для исследования ресурсов |

Подробное описание форматов, собранное при реверсе, лежит в [`ROBY.MD`](ROBY.MD).

## RobyTool

```bash
swift run RobyTool list GameData/DATA/SCEN/SCENA0.DAT         # список ресурсов контейнера
swift run RobyTool extractall <file.DAT> <outdir> [max]       # распаковать всё
swift run RobyTool render <file.DAT> <outdir>                 # отрендерить NGB в PNG
swift run RobyTool dump startup|scene|character <path>        # разобрать DAN-скрипты
swift run RobyTool dump fs <file.DAN> <NAME.FS>               # покадровая анимация
```

Остальные команды (`composite`, `cutscenetest`, `ngbdiag`, `scenepos`, `overlay`) описаны в `Sources/RobyTool/main.swift`.

## Отладка

Переменные окружения:

| Переменная | Действие |
|---|---|
| `ROBY_MINIGAME=N` | сразу открыть мини-игру: 0 — карта, 1 — дом, 2 — шахматы, 3 — шар, 4 — орган, 5 — склеп |
| `ROBY_STATE=v` | начальное состояние мини-игры (по умолчанию 7) |
| `ROBY_SHOT=path.png` | сохранить скриншот через `ROBY_SHOT_DELAY` секунд (по умолчанию 3) |
| `ROBY_AUTO=organ` / `chess` | автопрохождение органа / шахмат |
| `ROBY_FAST=1` | ускорить анимации шахмат |
| `ROBY_BAL_TEST=1` | тест посадки шара |

```bash
ROBY_MINIGAME=2 .build/debug/Roby
```

Лог игры (скрипты, клики, состояние) пишется в stderr.

## Правовое

Это некоммерческий фанатский проект, сделанный ради сохранения старой игры.
Все права на «Новый Робинзон», его графику, звук и тексты принадлежат правообладателям.
Репозиторий содержит только собственный код порта.
