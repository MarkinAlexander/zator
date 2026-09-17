-- break-detector.lua — автоматический детектор «домен ломается самим обходом».
--
-- Работает в обоих режимах затора:
--   * circular_locked (ручные профили 1-4/8/9) — сигналы считаются самим
--     модулем (z2r_break_track);
--   * circular_quality (авторотация) — переиспользуются уже вычисленные
--     is_failure/is_success (z2r_break_note).
--
-- Логика: пер-хостовый счётчик отказов (входящий RST на раннем seq,
-- ретрансмиты, отсутствие ответа). При пороге отказов за окно хост
-- ставится в очередь внешней дифференциальной проверки — файл
-- /tmp/z2r-break-check/request.<id> (атомарный rename, как у
-- strategy-validator). Демон break-validator.sh проверяет хост двумя
-- пробами: временно исключённым из обхода (горячий exclude_hostlist,
-- TTL 2с) и под текущей стратегией. Вердикт BROKEN («без обхода
-- работает, с обходом нет») — хост остаётся в исключении насовсем.
-- Результат демон пишет в result.<id>, модуль забирает его при
-- следующих пакетах хоста (poll, как validator_poll).
--
-- Пороги настраиваются аргументами оркестратора (break_fails=,
-- break_window=, break_cooldown=), дефолты рассчитаны на роутер:
-- 3 отказа за 120 секунд, кулдаун 15 минут (BROKEN — 6 часов).
-- Состояние живёт в памяти процесса, на флешку пишется только очередь.

local Z2R_BREAK_QUEUE_DIR = "/tmp/z2r-break-check"
local Z2R_BREAK_REQUEST_PREFIX = Z2R_BREAK_QUEUE_DIR .. "/request."
local Z2R_BREAK_RESULT_PREFIX = Z2R_BREAK_QUEUE_DIR .. "/result."

-- RAM-кэш вердиктов демона (tmpfs, «hostkey<TAB>вердикт<TAB>unixtime»):
-- свежий вердикт переиспользуется — повторная диффпроба не гоняется, кулдаун
-- переживает рестарт nfqws2. Демон периодически чистит протухшие записи.
local Z2R_BREAK_VERDICTS_PATH = "/tmp/z2r-break-verdicts.tsv"
local Z2R_BREAK_VERDICTS = nil
local Z2R_BREAK_VERDICTS_LOADED_AT = 0
local Z2R_BREAK_VERDICTS_TTL = 30    -- перечитываем кэш раз в 30с
local Z2R_BREAK_CD_BROKEN = 6 * 3600 -- кулдаун после BROKEN
local Z2R_BREAK_CD_OTHER = 900       -- кулдаун после остальных вердиктов

local function z2r_break_verdicts_load(now)
  if Z2R_BREAK_VERDICTS and (now - Z2R_BREAK_VERDICTS_LOADED_AT) < Z2R_BREAK_VERDICTS_TTL then
    return Z2R_BREAK_VERDICTS
  end
  Z2R_BREAK_VERDICTS_LOADED_AT = now
  local cache = {}
  local f = io.open(Z2R_BREAK_VERDICTS_PATH, "r")
  if f then
    for line in f:lines() do
      local host, verdict, ts = line:match("^([%w_.%-]+)\t([A-Z_]+)\t(%d+)$")
      if host then cache[host] = { verdict = verdict, ts = tonumber(ts) or 0 } end
    end
    f:close()
  end
  Z2R_BREAK_VERDICTS = cache
  return cache
end

-- Свежий вердикт по хосту: возвращает кулдаун (сек), если пробу можно
-- пропустить, иначе nil.
local function z2r_break_verdict_cooldown(host, now)
  local cache = z2r_break_verdicts_load(now)
  local entry = cache[host]
  if not entry then return nil end
  local window = (entry.verdict == "BROKEN") and Z2R_BREAK_CD_BROKEN or Z2R_BREAK_CD_OTHER
  local age = now - entry.ts
  if age < 0 or age >= window then return nil end
  return window - age
end

local Z2R_BREAK_STATE = {}      -- hostkey -> запись состояния
local Z2R_BREAK_SEQ = 0
local Z2R_BREAK_STATE_CAP = 256 -- предел памяти на роутере

-- TCP-флаги и пороги по умолчанию (зеркало standard_failure_detector).
local Z2R_BREAK_TH_RST = (type(TH_RST) == "number") and TH_RST or 0x04
local Z2R_BREAK_RST_INSEQ = 4096   -- входящий RST значим только на раннем rseq
local Z2R_BREAK_RETRANS = 3        -- порог ретрансмитов на соединение
local Z2R_BREAK_MAXSEQ = 32768     -- ретрансмиты учитываем до этого rseq
local Z2R_BREAK_SOFT_BYTES = 32768 -- входящих байт достаточно для «успеха»

local function z2r_break_band(left, right)
  local result, bit = 0, 1
  while left > 0 and right > 0 do
    if left % 2 == 1 and right % 2 == 1 then result = result + bit end
    left, right, bit = math.floor(left / 2), math.floor(right / 2), bit * 2
  end
  return result
end

-- Нормализация ключа хоста: как в circular_quality — группировка доменов
-- (googlevideo и пр.) и slm-нормализация, если они доступны.
local function z2r_break_hostkey(host)
  if type(host) ~= "string" then return nil end
  host = string.lower(host:gsub("%.+$", ""))
  if host == "" then return nil end
  if type(get_grouped_hostname) == "function" then
    host = get_grouped_hostname(host) or host
  end
  if type(slm_normalize_hostkey) == "function" then
    host = slm_normalize_hostkey(host) or host
  end
  if type(host) ~= "string" or host == "" then return nil end
  return host
end

-- Допустимый идентификатор для имени файла (как validator_token).
local function z2r_break_token(value)
  return type(value) == "string" and value:match("^[A-Za-z0-9_.%-]+$") ~= nil
end

local function z2r_break_hostname_ok(host)
  if type(host) ~= "string" then return false end
  return host:match("^[A-Za-z0-9%.%-]+%.%a[A-Za-z0-9%-]*$") ~= nil
end

local function z2r_break_defaults(arg)
  arg = arg or {}
  return {
    fails = tonumber(arg.break_fails) or 3,
    window = tonumber(arg.break_window) or 120,
    cooldown = tonumber(arg.break_cooldown) or 900,
  }
end

-- Забрать результат дифференциальной проверки у демона (если готов).
local function z2r_break_poll(rec, now)
  local pending = rec.inflight
  if not pending then return end
  if now >= pending.deadline then
    rec.inflight = nil
    return
  end
  local path = Z2R_BREAK_RESULT_PREFIX .. pending.id
  local f = io.open(path, "r")
  if not f then return end
  local line = f:read("*l")
  f:close()
  os.remove(path)
  rec.inflight = nil
  local id, verdict = line and line:match("^(%d+)\t([A-Z_]+)")
  if id ~= pending.id then return end
  if verdict == "BROKEN" then
    -- Хост уже исключён демоном насовсем; долго не вспоминаем о нём.
    rec.cooldown_until = now + 6 * 3600
  else
    rec.cooldown_until = now + (rec.cfg and rec.cfg.cooldown or 900)
  end
  rec.fails = 0
  rec.first_fail = nil
end

local function z2r_break_enqueue(rec, hostname, proto, strategy, now)
  Z2R_BREAK_SEQ = Z2R_BREAK_SEQ + 1
  local id = tostring(now) .. string.format("%06d", Z2R_BREAK_SEQ % 1000000)
  local request_path = Z2R_BREAK_REQUEST_PREFIX .. id
  local tmp_path = request_path .. ".tmp"
  local f = io.open(tmp_path, "w")
  if not f then return end
  f:write(id, "\t", rec.host, "\t", hostname, "\t", proto, "\t", tostring(strategy or 0), "\n")
  f:close()
  if not os.rename(tmp_path, request_path) then
    os.remove(tmp_path)
    return
  end
  rec.inflight = { id = id, deadline = now + 90 }
  if type(DLOG) == "function" then
    DLOG("break-detector: enqueue host=" .. rec.host .. " strategy=" .. tostring(strategy))
  end
end

-- Ограничение памяти: выбрасываем протухшие записи.
local function z2r_break_evict(now)
  local n = 0
  for _ in pairs(Z2R_BREAK_STATE) do n = n + 1 end
  if n <= Z2R_BREAK_STATE_CAP then return end
  local stale = {}
  for host, rec in pairs(Z2R_BREAK_STATE) do
    if rec.inflight == nil and (rec.last_note or 0) < now - 600 then
      stale[#stale + 1] = host
    end
  end
  for _, host in ipairs(stale) do Z2R_BREAK_STATE[host] = nil end
end

-- Общая точка входа для обоих оркестраторов.
--   hostkey  — уже нормализованный ключ (может быть nil — тогда сами не знаем
--              хост, пропускаем);
--   is_failure/is_success — внешние вердикты (circular_quality) или nil
--              (тогда z2r_break_track вычисляет их сам).
function z2r_break_note(desync, hostkey, strategy, is_failure, is_success)
  if not desync or not desync.dis or not desync.dis.tcp then return end
  local host = z2r_break_hostkey(hostkey)
  if not host then return end

  local now = os.time() or 0
  local cfg = z2r_break_defaults(desync.arg)
  local rec = Z2R_BREAK_STATE[host]
  if not rec then
    rec = { host = host, fails = 0, cfg = cfg }
    Z2R_BREAK_STATE[host] = rec
  end
  rec.last_note = now
  z2r_break_evict(now)
  z2r_break_poll(rec, now)

  if is_failure then
    local first = rec.first_fail
    if not first or (now - first) > cfg.window then
      first = now
      rec.fails = 0
    end
    rec.first_fail = first
    rec.fails = rec.fails + 1
    if rec.fails >= cfg.fails
       and rec.inflight == nil
       and now >= (rec.cooldown_until or 0) then
      -- Переиспользование RAM-кэша вердиктов: если демон недавно уже выносил
      -- вердикт по этому хосту (в т.ч. до рестарта nfqws2) — кулдаун из кэша,
      -- повторную диффпробу не гоняем.
      local cd = z2r_break_verdict_cooldown(host, now)
      if cd then
        rec.cooldown_until = now + cd
        rec.fails = 0
        rec.first_fail = nil
      else
        local hostname = nil
        if type(desync_hostname) == "function" then
          hostname = desync_hostname(desync)
        end
        hostname = hostname or (desync.track and desync.track.hostname) or host
        if z2r_break_hostname_ok(hostname) then
          local proto = "tls"
          if desync.l7payload == "http_req" or desync.l7payload == "http_reply" then
            proto = "http"
          end
          z2r_break_enqueue(rec, hostname, proto, strategy, now)
        end
      end
    end
  elseif is_success then
    rec.fails = 0
    rec.first_fail = nil
  end
end

-- Самостоятельный подсчёт сигналов (для circular_locked, ручной режим).
-- Зеркалит дешёвую часть standard_failure_detector, но хранит состояние
-- в lua_state соединения, чтобы не конфликтовать с crec авторотации.
function z2r_break_track(desync, hostkey, strategy)
  local dis = desync and desync.dis
  if not dis or not dis.tcp then return end
  local payload = dis.payload
  local is_rst = z2r_break_band(dis.tcp.th_flags or 0, Z2R_BREAK_TH_RST) ~= 0

  -- Дешёвый гейт: пустые пакеты без RST не несут сигнала.
  if (not payload or #payload == 0) and not is_rst then return end

  local track = desync.track
  if not track then return end
  local state = track.lua_state
  if type(state) ~= "table" then return end
  local crec = state.z2r_break
  if not crec then
    crec = {}
    state.z2r_break = crec
  end

  local is_failure = false
  local is_success = false

  if desync.outgoing then
    if payload and #payload > 0
       and type(is_retransmission) == "function"
       and is_retransmission(desync) then
      local seq = nil
      if type(pos_get) == "function" then seq = pos_get(desync, "s") end
      if not seq or (seq <= Z2R_BREAK_MAXSEQ) then
        crec.retrans = (crec.retrans or 0) + 1
        is_failure = crec.retrans >= Z2R_BREAK_RETRANS
      end
    end
  else
    if is_rst then
      local seq = nil
      if type(pos_get) == "function" then seq = pos_get(desync, "s") end
      -- RST значим только на раннем rseq (разрыв после ClientHello).
      is_failure = (not seq) or (seq >= 1 and seq <= Z2R_BREAK_RST_INSEQ)
    elseif payload and #payload > 0 then
      crec.in_bytes = (crec.in_bytes or 0) + #payload
      -- Явного детектора ответа нет: мягкий успех по объёму входящих данных.
      is_success = crec.in_bytes >= Z2R_BREAK_SOFT_BYTES
    end
  end

  if not is_failure and not is_success then return end
  z2r_break_note(desync, hostkey, strategy, is_failure, is_success)
end

-- Точка входа для тестов: прямая работа с внутренним состоянием.
function z2r_break_state_for_tests()
  return Z2R_BREAK_STATE
end

function z2r_break_reset_for_tests()
  Z2R_BREAK_STATE = {}
  Z2R_BREAK_SEQ = 0
end
