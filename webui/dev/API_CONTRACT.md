# API-контракт WebUI (CGI)

Документ снят напрямую с кода `webui/cgi-bin/_lib.sh` и `*.cgi`.
Это «источник правды» для фейк-сервера `fake_router_server.py`: он обязан
воспроизводить ровно эти поля, коды ошибок и edge-case'ы.

Все эндпоинты живут под `/cgi-bin/`. CGI-скрипты — тонкие обёртки, вся логика
в функциях `api_*` из [`_lib.sh`](../cgi-bin/_lib.sh:1). Тело ответа — всегда
JSON, `Content-Type: application/json; charset=utf-8`.

Параметры разбираются функцией `parse_params()` ([`_lib.sh`](../cgi-bin/_lib.sh:58)):
для `GET` — из `QUERY_STRING`, для `POST` — из тела (`Content-Length`,
`application/x-www-form-urlencoded`). Распознаются ключи `profile`,
`strategy`, `action`. Значения URL-декодируются (`%xx` → символ, `+` → пробел).

---

## Жёстко зашитые пути и переменные окружения

| Где | Значение | Источник |
| --- | --- | --- |
| `WEBUI_ROOT` | `/opt/zapret2/webui` | [`_lib.sh:8`](../cgi-bin/_lib.sh:8) |
| `ZAPRET_ROOT` | `/opt/zapret2` | [`_lib.sh:9`](../cgi-bin/_lib.sh:9) |
| `CONFIG_FILE` | `/opt/zapret2/config` | [`_lib.sh:10`](../cgi-bin/_lib.sh:10) |
| `ORCH_DIR` | `/opt/zapret2/extra_strats/cache/orchestra` | [`_lib.sh:11`](../cgi-bin/_lib.sh:11) |
| `ORCH_LOCK_FILE` | `$ORCH_DIR/locked.tsv` (default) | [`orchestra_state.sh:4`](../../lib/orchestra_state.sh:4) |
| `locked.manual.tsv` | `$ORCH_DIR/locked.manual.tsv` | используется профилями 8/9 в `config.sh` |
| `PROFILE_STATE_FILE` | `/opt/etc/z2r/profile.lock` (default) | [`orchestra_state.sh:5`](../../lib/orchestra_state.sh:5) (env `Z2R_PROFILE_STATE_FILE`) |
| Порт WebUI | `17682` (env `WEBUI_PORT`) | [`run-webui.sh:13`](../run-webui.sh:13) |
| Поиск runtime-либ | `$ZAPRET_ROOT/z2r_lib`, `../../z2r_lib`, `../../lib`, `../lib` | [`_lib.sh:14`](../cgi-bin/_lib.sh:14) |

> Фейк-сервер **никогда** не лезет в эти пути: всё переопределяется во
> временную директорию (см. `fake_router_server.py`).

---

## Внешние команды и файлы, которые трогают эндпоинты

| Эндпоинт | Что реально вызывает |
| --- | --- |
| `status` | `pidof nfqws2` (через [`zapret2_running()`](../../lib/orchestra_state.sh:54)); чтение `CONFIG_FILE` (`config_mode_text`, `config_profile_max_strategy`); чтение `locked.tsv`, `locked.manual.tsv`, `profile.lock` (`strategy_locks_status_text`, `profile_state_display`) |
| `set-lock` | валидация по `config_profile_max_strategy`/`config_profile_proto_list`; запись `profile.lock` + `locked.tsv` (`profile_state_set_and_apply`); для профиля 6 — правка `NFQWS2_PORTS_UDP` в конфиге + `service_zapret2 restart`; `curl` к проверочным целям (`profile_check_json`); `send_stats` (telemetry, если есть) |
| `clear-lock` | запись `profile.lock` + `locked.tsv` в режим `auto`; для профиля 6 — правка портов + restart; telemetry |
| `service` | вызов init-скрипта `/opt/zapret2/init.d/{openwrt,sysv}/zapret2 {start,stop,restart}` |
| `check` | `curl --tls-max 1.2` и `curl --tlsv1.3` к 4 целям; `get_yt_cluster_domain` делает `curl` к `redirector.xn--ngstr-lra8j.com` (двойной запрос, fallback `rr1---sn-5goeenes.googlevideo.com`) |

---

## 1. `GET /cgi-bin/status.cgi` → `api_status`

Параметры: нет.

```jsonc
{
  "zapret2_running": true,                 // bool: pidof nfqws2
  "strategy_locks_status": "Есть",         // "Есть" | "Нет"
  "hostlist_mode": "по листам",            // config_mode_text hostlist
  "fwtype": "iptables",                    // config_get_var FWTYPE
  "flowoffload": "donttouch",              // config_get_var FLOWOFFLOAD
  "tls_blob_mode": "default",              // config_mode_text tls_blob_menu
  "profiles": [
    {"profile":1,"label":"YouTube TCP","description":"Основной TCP профиль для YouTube","current_lock":"auto","max_strategy":30},
    {"profile":2,"label":"Googlevideo","description":"Видео-домены YouTube","current_lock":"auto","max_strategy":30},
    {"profile":3,"label":"Blocked Sites","description":"Основные блокировки сайтов","current_lock":"auto","max_strategy":30},
    {"profile":4,"label":"Discord TCP","description":"TCP профиль Discord","current_lock":"auto","max_strategy":28},
    {"profile":5,"label":"YouTube QUIC","description":"UDP 443 для YouTube","current_lock":"auto","max_strategy":13},
    {"profile":6,"label":"Voice UDP","description":"Discord/STUN и голосовые сервисы","current_lock":"auto","max_strategy":32}
  ]
}
```

Поле `current_lock` — результат `profile_state_display(profile, proto)`:
сначала читается `profile.lock` (`profile_state_stored_get`), при `auto` —
`locked.tsv` (`orch_locked_state_get`, default `auto`). Значения: `"auto"`,
`"0"` (выключен), либо номер стратегии строкой.

`strategy_locks_status` = `"Есть"`, если непустой хотя бы один из
`locked.tsv`, `locked.manual.tsv`, `profile.lock`; иначе `"Нет"`
([`_lib.sh:139`](../cgi-bin/_lib.sh:139)).

`max_strategy` для `config.default`: **1→30, 2→30, 3→30, 4→28, 5→13, 6→32**
(см. `config_profile_max_strategy`, профиль 7=11/8=30/9=8 в WebUI не видны).

Ошибок через `send_error` нет (при отсутствии runtime-либ — `500` + `{"error":"missing z2r runtime libs"}`).

---

## 2. `POST /cgi-bin/set-lock.cgi` → `api_set_lock`

Параметры: `profile` (обяз.), `strategy` (обяз.).

Валидация (порядок важен, [`_lib.sh:214`](../cgi-bin/_lib.sh:214)):

| Условие | Код | Сообщение |
| --- | --- | --- |
| `profile` не `^[1-7]$` | `400 Bad Request` | `Некорректный профиль` |
| `strategy` не `^[0-9]+$` | `400 Bad Request` | `Некорректная стратегия` |
| `strategy != 0` и вне `[1..max]` | `400 Bad Request` | `Стратегия вне диапазона` |
| пустой `proto_list` | `400 Bad Request` | `Не удалось определить протокол профиля` |
| `profile_state_set_and_apply` упала | `500 Internal Server Error` | `Не удалось сохранить состояние профиля` |

Успех (`200 OK`):

```jsonc
{
  "ok": true,
  "check": {                 // profile_check_json(profile)
    "results": [
      {"label":"YouTube","target":"https://www.youtube.com/","tls12":1,"tls13":0}
    ]
  }
}
```

Структура `check.results` зависит от профиля
([`_lib.sh:180`](../cgi-bin/_lib.sh:180)):

| profile | label / target |
| --- | --- |
| 1 | `YouTube` / `https://www.youtube.com/` |
| 2 | `Googlevideo` / `https://<yt-cluster-domain>` |
| 3 | `Blocked Sites` / `https://meduza.io` |
| 4 | `Discord` / `https://discord.com/` |
| 5, 6 | `results: []` + `message`: «Для UDP-профиля быстрая TLS-проверка неприменима. Проверьте работу в браузере или приложении.» |
| прочее | `results: []` |

Каждый элемент результата: `{"label":str,"target":str,"tls12":0|1,"tls13":0|1}`.

> Для профиля 6 дополнительно выполняется `service_zapret2 restart` (результат
> игнорируется) и правка голосовых портов в конфиге.

---

## 3. `POST /cgi-bin/clear-lock.cgi` → `api_clear_lock`

Параметры: `profile` (обяз.).

| Условие | Код | Сообщение |
| --- | --- | --- |
| `profile` не `^[1-7]$` | `400 Bad Request` | `Некорректный профиль` |
| пустой `proto_list` | `400 Bad Request` | `Не удалось определить протокол профиля` |
| apply упала | `500 Internal Server Error` | `Не удалось сбросить состояние профиля` |

Успех (`200 OK`):

```json
{ "ok": true }
```

Сбрасывает профиль в `auto` (удаляет запись из `profile.lock` и `locked.tsv`).
Для профиля 6 — restart + правка портов.

---

## 4. `POST /cgi-bin/service.cgi` → `api_service`

Параметры: `action` (обяз.).

| Условие | Код | Сообщение |
| --- | --- | --- |
| `action` не `start\|stop\|restart` | `400 Bad Request` | `Некорректное действие` |
| `service_zapret2` упала (нет init-скрипта / ненулевой код) | `500 Internal Server Error` | `Не удалось выполнить команду zapret2` |

Успех (`200 OK`):

```json
{ "ok": true }
```

`service_zapret2` ([`_lib.sh:125`](../cgi-bin/_lib.sh:125)) выбирает
`init.d/openwrt/zapret2`, иначе `init.d/sysv/zapret2`; если файла нет —
возвращает ненулевой код → `500`.

---

## 5. `POST /cgi-bin/check.cgi` → `api_check`

Параметры: нет. (Фронтенд шлёт `POST`, но метод для этого эндпоинта не важен.)

Успех (`200 OK`):

```jsonc
{
  "results": [
    {"label":"YouTube","target":"https://www.youtube.com/","tls12":1,"tls13":1},
    {"label":"Googlevideo","target":"https://<yt-cluster-domain>","tls12":1,"tls13":1},
    {"label":"Blocked Sites","target":"https://meduza.io","tls12":0,"tls13":1},
    {"label":"Instagram","target":"https://www.instagram.com/","tls12":1,"tls13":0}
  ]
}
```

Ошибок через `send_error` нет.

---

## Что фронтенд реально вызывает (`app.js`)

| Вызов | Метод | Тело |
| --- | --- | --- |
| [`api('/cgi-bin/status.cgi')`](../app.js:292) | GET | — |
| [`api('/cgi-bin/set-lock.cgi', POST)`](../app.js:215) | POST | `profile=<id>&strategy=<n>` |
| [`api('/cgi-bin/clear-lock.cgi', POST)`](../app.js:232) | POST | `profile=<id>` |
| [`api('/cgi-bin/service.cgi', POST)`](../app.js:322) | POST | `action=<start\|stop\|restart>` |
| [`api('/cgi-bin/check.cgi', POST)`](../app.js:347) | POST | — |

Статика: `index.html`, `styles.css`, `app.js` (отдаются как есть).

> Замечание: реальный `api_status` **не отдаёт** провайдера (`lib/provider.sh`).
> Поле провайдера есть только в шелл-меню, в JSON WebUI его нет. Поэтому флаг
> `--provider` фейк-сервера влияет только на лог/dev-состояние, но не на UI.
