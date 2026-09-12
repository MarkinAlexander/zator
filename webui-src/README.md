# webui-src — исходники Web-панели (z2r Web UI)

Фронтенд Web-панели управления zapret2. Написан на **Vue 3 + TypeScript**,
собирается **Vite** в три обычных статических файла, которые сервер
(uhttpd / busybox httpd на роутере) отдаёт без каких-либо требований к
браузеру — даже старые Android WebView работают.

> Файлы `webui/app.js`, `webui/styles.css`, `webui/index.html` —
> **собранные артефакты**. Их не редактируют руками: правьте сорсы здесь,
> пересобирайте и коммитьте вместе. Устройства пользователей скачивают эти
> три файла поимённо с ветки `zator`, поэтому артефакты всегда обязаны
> лежать в репозитории и соответствовать исходникам.

## Требования

| Инструмент | Версия | Для чего |
| --- | --- | --- |
| Node.js | **>= 18** (рекомендуется LTS 20+) | сборка и dev-сервер |
| npm | идёт с Node | зависимости |
| Python 3 | любой | `webui/dev/fake_router_server.py` (локальные тесты без роутера) |

Установка зависимостей — один раз:

```bash
cd webui-src
npm install
```

## Команды

```bash
npm run dev     # dev-сервер Vite (http://127.0.0.1:5173) с hot-reload
npm run build   # сборка в ../webui + простановка ?v=<sha256>
npm run check   # проверка типов vue-tsc (без сборки)
npm run pack    # единый архив развёртывания zator-контента (см. ниже)
```

## Разработка с фейк-сервером (без роутера)

Рядом лежит `webui/dev/fake_router_server.py` — полный мэк бэкенда на
чистом Python (без pip-зависимостей). Он воспроизводит все CGI-эндпоинты
(включая агрегирующий `state.cgi`), хранит состояние во временной папке и
умеет симулировать ошибки, задержки и разные состояния сервиса.

Два режима:

1. **Hot-reload (основной):** в одном терминале поднимите мэк, в другом — Vite:

   ```bash
   python webui/dev/fake_router_server.py          # бэкенд-моки на :8099
   cd webui-src && npm run dev                     # Vite на :5173
   ```

   Откройте http://127.0.0.1:5173/ — запросы `/cgi-bin/*` уже
   проксируются на фейк-сервер (настроено в `vite.config.ts`).

2. **Проверка собранного бандла (как на устройстве):**

   ```bash
   npm run build
   python webui/dev/fake_router_server.py          # отдаёт webui/ на :8099
   ```

   Откройте http://127.0.0.1:8099/ — это ровно те файлы, которые поедут
   на роутер.

Полезные флаги фейк-сервера: `--service-state=stopped`, `--lock-state="2=5,4=0"`,
`--check-result=ok|fail|mixed|random`, `--simulate-error=settings`,
`--delay=3`, `--status-delay=3`; переключать состояние на ходу —
`POST /__dev/state`. Полный контракт ответов — в
`webui/dev/API_CONTRACT.md` (источник правды для мэка и TypeScript-типов).

## Сборка и деплой

- Сборка выдаёт **ровно три файла** в `../webui/`: `app.js` (один
  классический IIFE-скрипт, es2018, без sourcemap и чанков), `styles.css`
  и `index.html`. Такой состав — контракт установки `z2r.sh`: файлы
  качаются поимённо и кладутся в `/opt/zator/webui/www/`.
- `scripts/stamp-assets.mjs` автоматически проставляет в `index.html`
  `?v=<первые 8 символов sha256>` для `app.js`/`styles.css`/`favicon.svg`
  — после каждого обновления браузеры пользователей забирают свежие
  файлы, ручные `?v=15` не нужны.
- Коммитьте исходники и пересобранные артефакты **одним коммитом**.
- Проверка консистентности артефактов — `bash tests/webui_build_smoke.sh`
  (состав файлов, порядок тегов, совпадение `?v=` с хэшем).

Проверка на живом роутере: скопируйте три собранных файла в
`/opt/zator/webui/www/` и обновите страницу — смена `?v=` сама сбросит кэш.

### Архивы развёртывания (npm run pack)

`scripts/pack-zator-tar.mjs` собирает в `dist/` три варианта одним прогоном:
`zator-core.tar.gz` (весь zator-контент без webui), `zator-webui.tar.gz`
(только панель), `zator-full.tar.gz` (union). Пути в архиве относительно
`/opt/zator`, спецзаписи: `_root/z2r.sh` → `/opt/z2r.sh` и
`_payload/{config.default,Entware/keenetic-policy.sh,blockcheck2.d/...}` →
`/opt/zator/.deploy-payload/` (офлайн-источник, в `/opt/zapret2` автоматически
не ставится). Текст нормализован в LF, права 0755/0644 зашиты в заголовки tar,
сборка детерминирована (при фиксированном `--version`).

Рядом с каждым архивом: `.sha256` (формат `sha256sum -c`), `.manifest.json`,
`.manifest.tsv` (шелл-читаемый `path|dest|class|sha256|size|exec`); копии
`version.env` и манифестов лежат внутри архива в
`extra_strats/cache/deploy/`. Класс `keep-if-exists` (netrogat.txt,
TCP_Custom.txt, substrings-листы, custom_tls.bin) — основа защит при
развёртывании: существующие файлы пользователя не перезаписываются. При
`--variant=all` пишется ещё `latest.json` — указатель сборки с размерами
архивов для проверки свободного места на устройстве.

Флаги: `--variant=core|webui|full|all` (дефолт all), `--version=<tag>`
(дефолт `deploy-<UTC таймстамп>`), `--out <dir>`, `--repo owner/name`
(URL в latest.json). Релизы на GitHub собирает workflow
`.github/workflows/deploy-tar.yml` (только workflow_dispatch): rolling-тег
`latest` + неизменяемые номерные. Развёртывание на устройстве делает
`lib/deploy.sh` (меню п.5 z2r) и лаунчер `z2r`; после распаковки webui нужен
`webui_fix_interpreters` (шебанг в репо портабельный, на Keenetic требуется
`/opt/bin/bash`) — deploy делает это сам.

Runtime-состояние (кэши, `autohostlist.txt`) в архивы не попадает.

## Структура

```
webui-src/
├─ index.html            # вход vite (мета + <script type="module" src="/src/main.ts">)
├─ vite.config.ts        # outDir ../webui, IIFE, dev-proxy /cgi-bin → :8099
├─ scripts/stamp-assets.mjs
└─ src/
   ├─ main.ts            # createApp + router + импорт стилей
   ├─ App.vue            # шапка (табы, тема), <router-view>, тосты, модалки, «наверх»
   ├─ router/index.ts    # hash-роутер + запрет навигации при операциях/загрузке
   ├─ api/               # client (fetch-обёртка), types (по API_CONTRACT.md), endpoints
   ├─ stores/            # состояние на composables (без Pinia):
   │                     #   status, settings, domains, backups, busy, toast,
   │                     #   confirm, theme, state (агрегированная загрузка)
   ├─ composables/       # useApiAction
   ├─ components/
   │  ├─ ui/             # ToastHost, ConfirmDialog, StatCard, NumberStepper, CheckResults
   │  ├─ status/         # StatusCards (карточки→ссылки/CLI), ServiceControls, ProfileGrid
   │  ├─ strategies/     # StrategyCard (лок-форма, inline-проверка, гейтинг)
   │  ├─ domains/        # DomainRow (trial-подбор стратегии)
   │  └─ settings/       # ModeTogglePanel (конфиг-Driven тумблеры) + отдельные панели
   ├─ views/             # StatusView, StrategiesView, DomainsView, SettingsView
   └─ styles/            # base.css (перенесён 1:1 из старого styles.css) + links.css
```

## Роутинг

`createWebHashHistory` — прямые ссылки вида `http://роутер:17682/#/settings/rst-guard`.
История (history-mode) невозможна: uhttpd/busybox httpd не умеют SPA-rewrite.

Маршруты: `/`, `/strategies` (`?scope=`, `?focus=N` — скролл к карточке
профиля с подсветкой; можно списком через запятую `focus=8,9`: скролл к
самой верхней карточке, подсвечиваются все перечисленные), `/domains/:list`,
`/settings/:panel` (13 панелей, диплинк скроллит к панели и подсвечивает
кольцом 6с).

## Архитектурные договорённости

- **Состояние** — простые composables-модули (`ref`/`reactive`), без Pinia
  и vuex. Один агрегирующий запрос `GET /cgi-bin/state.cgi` на старте и по
  кнопкам «Обновить»; точечные `settings.cgi?setting=…` — только
  перепроверка после изменения одной настройки. Не возвращайтесь к
  «куче запросов на старте»: на слабых роутерах каждый CGI — новый процесс.
- **busy-lock**: любая мутация идёт через `withBusy(key, fn)` — блокируются
  все контролы и навигация; у кнопки-инициатора спиннер (`busyButton`).
- **Гейтинг** профилей — `src/gating.ts` (единое место: тексты причин,
  `gatedPanel()` для ссылки «перейти к настройке»).
- **Тумблеры настроек** описываются конфигом `components/settings/modeToggles.ts`
  (тексты, чипы, конфирмы) и рендерятся одним `ModeTogglePanel` — новый
  тумблер = новая запись в конфиге, без копипасты.
- **Данные на «Доменах»** ленивые (грузятся при входе на вкладку), с
  индикатором «Пожалуйста подождите…».

## Стили

- `src/styles/base.css` — перенесён из старой вёрстки практически 1:1;
  тема на CSS-переменных (`--accent`, `--surface`, …), тёмная — через
  `html[data-theme]`. Старайтесь не менять его без нужды.
- `src/styles/links.css` — всё новое: кликабельные карточки, кольцо
  подсветки `is-target`, кнопка «наверх», ссылка-кнопка `a.ghost`.
- Подсветка цели (`scrollIntoView` + класс `is-target`) — единый паттерн
  для панелей настроек, карточек стратегий и результатов проверки.
- Отступ диплинка — `scroll-margin-top: 18px` у `.panel`/`.profile-card`.

## Правила кода

- TypeScript strict; типы ответов — в `src/api/types.ts` строго по
  `webui/dev/API_CONTRACT.md`.
- Комментарии — минимальные, только неочевидные ограничения, по-русски.
- Все тексты интерфейса — русские, формулировки переносите дословно из
  старой панели (пользовательские привычки + их проверяют смоки).
- **Не переименовывайте id элементов** (`auto-mode-form`, `ports-tcp-form`,
  `backup-create-btn`, `domains-panel`, …) и классы `checks domain-check`,
  `check-pair`, `fallback-hint` — смок-тесты грепают их по исходникам
  `webui-src/src/**` (минифицированный бандл не проверяется).
- Изменение API CGI → синхронно правьте: `_lib.sh`, `fake_router_server.py`,
  `API_CONTRACT.md`, `src/api/types.ts`.
