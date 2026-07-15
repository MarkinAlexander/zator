# webui/dev — фейковый dev-сервер для WebUI

Локальная среда для разработки и ручной проверки фронтенда `webui/`
(`index.html`, `app.js`, `styles.css`) **без реального роутера и без `/opt/zapret2`**.
Только стандартная библиотека Python — никаких pip-зависимостей.

Файлы:
- [`fake_router_server.py`](fake_router_server.py) — сервер (имитирует CGI + отдаёт статику).
- [`API_CONTRACT.md`](API_CONTRACT.md) — точный JSON-контракт эндпоинтов (снят с `cgi-bin/`).

## Запуск

```bash
python webui/dev/fake_router_server.py
```

Откройте **http://127.0.0.1:8099/** — это живой фронтенд. Порт по умолчанию
`8099` (не `17682`, чтобы не конфликтовать с реальным WebUI на устройстве).

> Сервер пишет фейковое состояние во **временную директорию** (`%TEMP%\z2r_fake_*`
> / `/tmp/z2r_fake_*`) и копию `config.default`. `/opt/zapret2` и репозиторий
> не меняются. Каждый запрос логируется в консоль с текущим фейк-состоянием.

## Сценарии (CLI при старте)

```bash
# zapret2 остановлен, есть зафиксированные стратегии, проверки «провалены»
python webui/dev/fake_router_server.py --service-state=stopped --lock-state="2=5,4=0,6=12" --check-result=fail

# сервис запущен, локов нет, проверки OK
python webui/dev/fake_router_server.py --service-state=running --lock-state=none --check-result=ok

# эндпоинт status отдаёт 500 (тренируем обработку ошибок в UI)
python webui/dev/fake_router_server.py --simulate-error=status
```

Флаги:

| Флаг | Значения | Что делает |
| --- | --- | --- |
| `--port` | число | порт (по умолч. `8099`) |
| `--service-state` | `running` \| `stopped` | `zapret2_running` в `/status` |
| `--lock-state` | `none` \| `профиль=страт,…` | стартовые локи; `страт`: число, `0` (выкл) или `auto`. Пример: `2=5,4=0,6=12` |
| `--check-result` | `ok` \| `fail` \| `mixed` | результаты TLS-проверок в `/check` и `set-lock` |
| `--simulate-error` | `status,service,check,set-lock,clear-lock` (через запятую) | эти эндпоинты отдают `500 {"error":…}` |
| `--provider` | строка | только для лога (в реальном WebUI поля провайдера нет) |

## Переключение сценариев на лету (без перезапуска)

`POST /__dev/state` с JSON меняет состояние в рантайме:

```bash
curl -X POST http://127.0.0.1:8099/__dev/state -H "Content-Type: application/json" \
  -d "{\"nfqws2_running\": false, \"check_result\": \"mixed\", \"lock_state\": \"1=7\"}"
```

Поля: `nfqws2_running`, `check_result`, `provider`, `simulate_error` (массив),
`lock_state` (перезаписывает все локи). Текущее состояние — `GET /__dev/state`.

## Что должно быть видно в UI по сценариям

- **service=running**: карточка «zapret2» = «Запущен», кнопка «Остановить zapret2»
  (красная), «↻» активна.
- **service=stopped**: «Остановлен», кнопка «Включить zapret2» (зелёная), «↻» заблокирована.
- **lock-state `2=5`**: в «Стратегиях» у Googlevideo «Текущий lock» = `5`, в поле
  подставляется `5`; «Локи стратегий» = «Есть».
- **lock-state `4=0`**: у Discord TCP lock = `0` (выключен).
- **check-result=fail**: «Проверить доступ» → все строки `TLS 1.2: FAIL / TLS 1.3: FAIL`.
- **check-result=mixed**: часть OK, часть FAIL.
- **simulate-error=status**: при загрузке/обновлении — красный баннер с текстом ошибки.
- **set-lock на профиле 5/6 (UDP)**: после «Сохранить» — сообщение про неприменимость
  быстрой TLS-проверки.

## Валидация

Контракт и эндпоинты проверены: `config_profile_max_strategy` для `config.default`
даёт 1→30, 2→30, 3→30, 4→28, 5→13, 6→32 (совпадает с awk из `lib/config.sh`);
все 5 fetch-вызовов `app.js` (`status`, `set-lock`, `clear-lock`, `service`, `check`)
обслуживаются без 404; коды ошибок и поля JSON совпадают с `API_CONTRACT.md`.
