#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Фейковый dev-сервер, имитирующий роутер с zapret2 WebUI.

Назначение
----------
Позволяет разрабатывать и гонять фронтенд `webui/` (index.html, app.js,
styles.css) локально, без реального устройства и без `/opt/zapret2`.

Что делает
----------
* Отдаёт настоящие статические файлы из `webui/` как есть.
* Реализует те же CGI-эндпоинты, что и `webui/cgi-bin/*.cgi`, воспроизводя
  JSON-контракт из `webui/dev/API_CONTRACT.md` максимально точно (те же поля,
  те же коды ошибок, те же edge-case'ы).
* Держит фейковое состояние «роутера» во временной директории (НИКОГДА не в
  `/opt/zapret2` и не в самом репозитории):
    - копия `config.default` (читается и правится sed-логикой как lib/config.sh);
    - фейковые `locked.tsv` / `locked.manual.tsv` / `profile.lock`;
    - флаг «nfqws2 running».
* Логирует каждый запрос и то, каким фейковым состоянием он обработан.

Ограничения
-----------
Только стандартная библиотека Python (http.server/json/argparse/re/tempfile).
Никаких pip-зависимостей — в духе dependency-light WebUI этого репозитория.

Парсинг конфига и lock-файлов — честный Python-порт функций из
`lib/config.sh` и `lib/orchestra_state.sh` (awk/sed-логика перенесена 1:1,
сверяйтесь с комментариями-ссылками).
"""

import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


# ===========================================================================
# Константы контракта (взяты из webui/cgi-bin/_lib.sh)
# ===========================================================================

# all_profiles_json() — _lib.sh:109
PROFILES = [
    (1, "YouTube TCP", "Основной TCP профиль для YouTube"),
    (2, "Googlevideo", "Видео-домены YouTube"),
    (3, "Blocked Sites", "Основные блокировки сайтов"),
    (4, "Discord TCP", "TCP профиль Discord"),
    (5, "YouTube QUIC", "UDP 443 для YouTube"),
    (6, "Voice UDP", "Discord/STUN и голосовые сервисы"),
]

# config_profile_proto_list() — lib/config.sh:359
_PROTO_LIST = {
    1: "tls http",
    2: "tls", 3: "tls", 4: "tls", 8: "tls",
    5: "udp", 6: "udp", 7: "udp",
    9: "http",
}


def proto_list(profile):
    """config_profile_proto_list() — lib/config.sh:359."""
    return _PROTO_LIST.get(int(profile), "")


def profile_proto(profile):
    """profile_proto() — _lib.sh:94: первое слово из proto_list."""
    pl = proto_list(profile)
    return pl.split()[0] if pl else ""


# config_profile_voice_ports() — lib/config.sh:434
VOICE_PORTS = "50000-50099,1400,3478-3481,5349,19294-19344"

# get_yt_cluster_domain() fallback — _lib.sh:154
YT_CLUSTER_FALLBACK = "rr1---sn-5goeenes.googlevideo.com"

# api_check() — _lib.sh:254: (label, target|None)  None → подставить YT-кластер
CHECK_TARGETS = [
    ("YouTube", "https://www.youtube.com/"),
    ("Googlevideo", None),
    ("Blocked Sites", "https://meduza.io"),
    ("Instagram", "https://www.instagram.com/"),
]

# profile_check_json() — _lib.sh:180
PROFILE_CHECK = {
    1: [("YouTube", "https://www.youtube.com/")],
    2: [("Googlevideo", None)],
    3: [("Blocked Sites", "https://meduza.io")],
    4: [("Discord", "https://discord.com/")],
}
UDP_CHECK_MESSAGE = ("Для UDP-профиля быстрая TLS-проверка неприменима. "
                     "Проверьте работу в браузере или приложении.")

# Сообщения об ошибках — дословно из _lib.sh (send_error)
ERR_BAD_PROFILE = "Некорректный профиль"
ERR_BAD_STRATEGY = "Некорректная стратегия"
ERR_STRATEGY_RANGE = "Стратегия вне диапазона"
ERR_NO_PROTO = "Не удалось определить протокол профиля"
ERR_SAVE_STATE = "Не удалось сохранить состояние профиля"
ERR_RESET_STATE = "Не удалось сбросить состояние профиля"
ERR_BAD_ACTION = "Некорректное действие"
ERR_SERVICE = "Не удалось выполнить команду zapret2"

# Допустимые эндпоинты для --simulate-error
SIMULATABLE = {"status", "service", "check", "set-lock", "clear-lock", "settings"}


# ===========================================================================
# Порт lib/config.sh — чтение/правка конфига
# ===========================================================================

_STRATEGY_RE = re.compile(r"strategy=[0-9]+")


def _read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def config_get_var(cfg_text, var):
    """config_get_var() — lib/config.sh:30: sed -n 's/^\\s*VAR=//p' | head -1."""
    for line in cfg_text.splitlines():
        m = re.match(r"^\s*" + re.escape(var) + r"=(.*)$", line)
        if m:
            return m.group(1)
    return None


def _scan_strategies(line, in_template, tpl, tplmax, active, prof, pid, maxval):
    """scan_strategies() из awk в config_profile_max_strategy — lib/config.sh:281."""
    for m in _STRATEGY_RE.finditer(line):
        # substr(line, RSTART+9, RLENGTH-9): пропускаем "strategy=" (9 символов)
        num = int(m.group(0)[9:])
        if in_template:
            if num > tplmax.get(tpl, 0):
                tplmax[tpl] = num
        else:
            if active and prof == pid and num > maxval:
                maxval = num
    return maxval


def _fallback_max_strategy(profile, cfg_text):
    """Часть для профилей 8/9 — lib/config.sh:235 (блоки #Z2R_FALLBACK_*)."""
    if profile == 9:
        begin, end = "#Z2R_FALLBACK_HTTP_BEGIN", "#Z2R_FALLBACK_HTTP_END"
    else:
        begin, end = "#Z2R_FALLBACK_BEGIN", "#Z2R_FALLBACK_END"
    inblk = False
    in_template = False
    tpl = ""
    tplmax = {}
    maxval = 0
    for line in cfg_text.splitlines():
        if begin in line:
            inblk = True
            continue
        if end in line:
            break
        if not inblk:
            continue
        if re.match(r"^--template=", line):
            in_template = True
            tpl = re.sub(r"^--template=", "", line)
            tpl = re.sub(r"\s.*$", "", tpl)
        else:
            in_template = False
        if re.match(r"^--import([=\s]|$)", line):
            imp = re.sub(r"^--import[=\s]+", "", line)
            imp = re.sub(r"\s.*$", "", imp)
            if tplmax.get(imp, 0) > maxval:
                maxval = tplmax[imp]
        maxval = _scan_strategies(line, in_template, tpl, tplmax,
                                  True, 0, profile, maxval)
    return maxval


def config_profile_max_strategy(profile, cfg_text):
    """config_profile_max_strategy() — lib/config.sh:230 (порт awk 1:1)."""
    pid = int(profile)

    # Профили 8/9 — отдельный fallback-разбор; при успехе возвращаем сразу.
    if pid in (8, 9):
        fb = _fallback_max_strategy(pid, cfg_text)
        if fb and fb > 0:
            return fb

    inopt = False
    prof = 0
    active = False
    in_template = False
    tpl = ""
    tplmax = {}
    maxval = 0

    for line in cfg_text.splitlines():
        if re.match(r'^NFQWS2_OPT="', line):
            inopt = True
        if not inopt:
            continue

        if re.match(r"^--template=", line):
            in_template = True
            tpl = re.sub(r"^--template=", "", line)
            tpl = re.sub(r"\s.*$", "", tpl)
        else:
            # start_profile_if_needed() — lib/config.sh:289
            if (not in_template and not active
                    and re.match(r"^--", line)
                    and not re.match(r"^--new", line)
                    and not re.match(r"^--lua-init", line)
                    and not re.match(r"^--blob=", line)
                    and not re.match(r"^--reasm-disable", line)):
                prof += 1
                active = True

        # import внутри активного профиля подтягивает tplmax шаблона
        if (not in_template and active and prof == pid
                and re.match(r"^--import([=\s]|$)", line)):
            imp = re.sub(r"^--import[=\s]+", "", line)
            imp = re.sub(r"\s.*$", "", imp)
            if tplmax.get(imp, 0) > maxval:
                maxval = tplmax[imp]

        maxval = _scan_strategies(line, in_template, tpl, tplmax,
                                  active, prof, pid, maxval)

        if re.match(r"^--new", line):
            active = False
            in_template = False
            tpl = ""
        if re.match(r'^"$', line):
            break

    return maxval


def config_tls_blob_mode_value(cfg_text):
    """config_tls_blob_mode_value() — lib/config.sh:115."""
    has_maxru = False
    has_default = False
    for line in cfg_text.splitlines():
        if "--lua-desync=" not in line:
            continue
        if "blob=maxru" in line and "strategy=26" not in line:
            has_maxru = True
        if "blob=fake_default_tls" in line and "strategy=26" not in line:
            has_default = True
    if has_maxru and not has_default:
        return "maxru"
    if has_default and not has_maxru:
        return "fake_default_tls"
    if has_default and has_maxru:
        return "mixed"
    return "не определён"


def config_tls_blob_menu_value(cfg_text):
    """config_tls_blob_menu_value() — lib/config.sh:145."""
    mode = config_tls_blob_mode_value(cfg_text)
    if mode == "fake_default_tls":
        return "default"
    if mode == "mixed":
        return "mixed"
    m = re.search(r"--blob=maxru:@/opt/zapret2/files/fake/(\S+)", cfg_text)
    if m:
        return m.group(1)
    return "неизвестно"


def config_mode_text(mode, cfg_text):
    """config_mode_text() — lib/config.sh:157 (порты, нужные WebUI)."""
    if mode == "flowoffload":
        return config_get_var(cfg_text, "FLOWOFFLOAD") or "неизвестно"
    if mode == "fwtype":
        return config_get_var(cfg_text, "FWTYPE") or "неизвестно"
    if mode == "hostlist":
        for line in cfg_text.splitlines():
            if re.match(r"^MODE_FILTER=autohostlist", line):
                return "авто"
        for line in cfg_text.splitlines():
            if re.match(r"^MODE_FILTER=hostlist", line):
                return "по листам"
        return "неизвестно"
    if mode == "tls_blob_mode":
        return config_tls_blob_mode_value(cfg_text)
    if mode == "tls_blob_menu":
        return config_tls_blob_menu_value(cfg_text)
    return "неизвестно"


# --- csv-хелперы для голосовых портов (lib/config.sh:369 / 438) ------------

def _csv_contains(csv, token):
    return token in (csv.split(",") if csv else [])


def csv_add_tokens(csv, tokens):
    """csv_add_tokens() — lib/config.sh:384."""
    out = csv or ""
    for tok in tokens.split(","):
        tok = tok.strip()
        if not tok:
            continue
        if not _csv_contains(out, tok):
            out = tok if not out else out + "," + tok
    return out


def csv_remove_tokens(csv, tokens):
    """csv_remove_tokens() — lib/config.sh:406."""
    remove = [t.strip() for t in tokens.split(",") if t.strip()]
    keep = [c for c in (csv or "").split(",") if c and c not in remove]
    return ",".join(keep)


def config_set_var(cfg_text, var, val):
    """config_set_var() — lib/config.sh:38 (in-memory, возвращает новый текст)."""
    lines = cfg_text.splitlines()
    pattern = re.compile(r"^\s*" + re.escape(var) + r"=.*$")
    replaced = False
    for i, line in enumerate(lines):
        if pattern.match(line):
            lines[i] = "{0}={1}".format(var, val)
            replaced = True
            break
    if not replaced:
        lines.append("{0}={1}".format(var, val))
    return "\n".join(lines) + "\n"


def config_profile_voice_ports_apply(cfg_text, state):
    """config_profile_voice_ports_apply() — lib/config.sh:438."""
    cur = config_get_var(cfg_text, "NFQWS2_PORTS_UDP") or ""
    if state == "0":
        new_ports = csv_remove_tokens(cur, VOICE_PORTS)
        if not new_ports:
            new_ports = "443"
    else:  # auto или номер стратегии — порты добавляются
        new_ports = csv_add_tokens(cur, VOICE_PORTS)
    if cur != new_ports:
        cfg_text = config_set_var(cfg_text, "NFQWS2_PORTS_UDP", new_ports)
    return cfg_text


# ===========================================================================
# Порт lib/orchestra_state.sh — lock-файлы и состояние профиля
# ===========================================================================

def _read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


def profile_state_normalize(s):
    """profile_state_normalize() — orchestra_state.sh:62. None = некорректно."""
    if s in ("", "auto"):
        return "auto"
    if s in ("0", "skip"):
        return "0"
    if re.match(r"^[1-9][0-9]*$", s):
        return s
    return None


def orch_locked_read(lock_file, profile, proto, default):
    """_orch_locked_read() — orchestra_state.sh:9 (TSV: profile\\tproto\\tstrat)."""
    prof = str(profile)
    for line in _read_lines(lock_file):
        if not line:
            continue
        f = line.split("\t")
        if len(f) >= 3 and f[0] == prof and f[1] == proto:
            return f[2]
        # legacy 2-поле: profile\tstrategy — трактуется как tls
        if len(f) == 2 and f[0] == prof and proto == "tls":
            return f[1]
    return default


def orch_locked_state_get(lock_file, profile, proto):
    return orch_locked_read(lock_file, profile, proto, "auto")


def profile_state_stored_get(profile_lock, profile, proto):
    """profile_state_stored_get() — orchestra_state.sh:80 (FS='[ \\t]+')."""
    prof = str(profile)
    for line in _read_lines(profile_lock):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = re.split(r"[ \t]+", line.strip())
        if len(f) >= 3 and f[0] == prof and f[1] == proto:
            return f[2]
        if len(f) == 2 and f[0] == prof and proto == "tls":
            return f[1]
    return "auto"


def profile_state_get(profile_lock, lock_file, profile, proto):
    """profile_state_get() / profile_state_display() — orchestra_state.sh:96."""
    stored = profile_state_stored_get(profile_lock, profile, proto)
    if stored != "auto":
        n = profile_state_normalize(stored)
        return n if n is not None else "auto"
    n = profile_state_normalize(orch_locked_state_get(lock_file, profile, proto))
    return n if n is not None else "auto"


def _write_tsv(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write("\t".join(str(x) for x in r) + "\n")
    os.replace(tmp, path)


def orch_locked_set(lock_file, profile, proto, strategy):
    """orch_locked_set() — orchestra_state.sh:28."""
    prof, p, s = str(profile), proto, str(strategy)
    rows = [line.split("\t") for line in _read_lines(lock_file) if line]
    found = False
    for r in rows:
        if r and r[0] == prof and ((len(r) > 1 and r[1] == p) or (len(r) == 2 and p == "tls")):
            r[:] = [prof, p, s]
            found = True
    if not found:
        rows.append([prof, p, s])
    _write_tsv(lock_file, rows)


def orch_locked_clear(lock_file, profile, proto):
    """orch_locked_clear() — orchestra_state.sh:43."""
    prof, p = str(profile), proto
    rows = [line.split("\t") for line in _read_lines(lock_file) if line]
    keep = [r for r in rows
            if not (r and r[0] == prof and ((len(r) > 1 and r[1] == p) or (len(r) == 2 and p == "tls")))]
    _write_tsv(lock_file, keep)


def profile_state_set(profile_lock, profile, proto, state):
    """profile_state_set() — orchestra_state.sh:157 (с предудалением + дописыванием)."""
    prof = str(profile)
    normalized = profile_state_normalize(state)
    if normalized is None:
        return False
    if normalized == "auto":
        profile_state_clear(profile_lock, profile, proto)
        return True
    rows = [re.split(r"[ \t]+", line.strip())
            for line in _read_lines(profile_lock)
            if line.strip() and not line.lstrip().startswith("#")]
    keep = [r for r in rows
            if not (r and r[0] == prof and ((len(r) > 1 and r[1] == proto) or (len(r) == 2 and proto == "tls")))]
    keep.append([prof, proto, normalized])
    _write_tsv(profile_lock, keep)
    return True


def profile_state_clear(profile_lock, profile, proto):
    """profile_state_clear() — orchestra_state.sh:171."""
    prof = str(profile)
    rows = [re.split(r"[ \t]+", line.strip())
            for line in _read_lines(profile_lock)
            if line.strip() and not line.lstrip().startswith("#")]
    keep = [r for r in rows
            if not (r and r[0] == prof and ((len(r) > 1 and r[1] == proto) or (len(r) == 2 and proto == "tls")))]
    _write_tsv(profile_lock, keep)


def profile_state_set_and_apply(state_obj, profile, proto_list_str, state):
    """profile_state_set_and_apply() + profile_config_apply_state() —
    lib/config.sh:531 / 486. Пишет и profile.lock, и locked.tsv."""
    pl = proto_list_str.split()
    normalized = profile_state_normalize(state)
    if normalized is None:
        return False
    for proto in pl:
        if normalized == "auto":
            profile_state_clear(state_obj.profile_lock, profile, proto)
            orch_locked_clear(state_obj.lock_file, profile, proto)
        else:
            profile_state_set(state_obj.profile_lock, profile, proto, normalized)
            orch_locked_set(state_obj.lock_file, profile, proto, normalized)
    # Профиль 6: правка голосовых портов в конфиге (config_profile_voice_ports_apply)
    if int(profile) == 6:
        state_obj.cfg_text = config_profile_voice_ports_apply(state_obj.cfg_text, normalized)
        state_obj._save_config()
    return True


# ===========================================================================
# Порт функций для TLS-блоба (lib/actions.sh + webui/cgi-bin/_lib.sh)
# ===========================================================================

def _scan_fake_blobs(fake_dir):
    """Сканирует директорию fake для .bin файлов с TLS, stun, rdp."""
    blobs = []
    if not os.path.isdir(fake_dir):
        return blobs
    for fname in sorted(os.listdir(fake_dir)):
        if not fname.endswith(".bin"):
            continue
        # Валидация: tls_*.bin, custom_tls.bin, stun.bin, rdp.bin
        if (fname.startswith("tls_") or fname == "custom_tls.bin" or
                fname in ("stun.bin", "rdp.bin")):
            blobs.append(fname)
    return blobs


def config_tls_blob_current(cfg_text):
    """Возвращает текущий blob-файл из --blob=maxru declaration."""
    m = re.search(r"--blob=maxru:@/opt/zapret2/files/fake/(\S+)", cfg_text)
    return m.group(1) if m else ""


def _apply_tls_blob(cfg_text, blob):
    """Применяет новый blob, возвращает новый текст конфига."""
    if blob == "fake_default_tls":
        # Переключение на встроенный: maxru -> fake_default_tls в lua-desync
        lines = []
        for line in cfg_text.splitlines():
            if ("--lua-desync=" in line and "blob=maxru" in line and
                    "strategy=26" not in line):
                line = re.sub(r"(blob=)maxru", r"\1fake_default_tls", line)
            lines.append(line)
        return "\n".join(lines) + "\n"
    else:
        # Переключение на внешний файл: fake_default_tls -> maxru + замена файла
        lines = []
        for line in cfg_text.splitlines():
            if ("--lua-desync=" in line and "blob=fake_default_tls" in line and
                    "strategy=26" not in line):
                line = re.sub(r"(blob=)fake_default_tls", r"\1maxru", line)
            # Замена пути в объявлении --blob=maxru:@...
            line = re.sub(r"(--blob=maxru:@/opt/zapret2/files/fake/)\S+",
                          r"\1" + blob, line)
            lines.append(line)
        return "\n".join(lines) + "\n"


# --- Порт функций для WireGuard-блоба (lib/actions.sh: menu_action_set_wg_blob
#     и menu_action_wg_repeats + webui/cgi-bin/_lib.sh: api_wg_blob_*) --------

def _scan_wg_blobs(fake_dir):
    """Сканирует директорию fake для wg_initial_fake_* (menu_action_set_wg_blob)."""
    blobs = []
    if not os.path.isdir(fake_dir):
        return blobs
    for fname in sorted(os.listdir(fake_dir)):
        if fname.startswith("wg_initial_fake_"):
            blobs.append(fname)
    return blobs


def config_wg_blob_current(cfg_text):
    """Возвращает текущий WG blob-файл из объявления --blob=fakewgblob:@..."""
    m = re.search(r"--blob=fakewgblob:@/opt/zapret2/files/fake/(\S+)", cfg_text)
    return m.group(1) if m else ""


def config_wg_repeats_current(cfg_text):
    """Возвращает текущее значение repeats из blob=fakewgblob:repeats=N."""
    m = re.search(r"blob=fakewgblob:repeats=([0-9]+)", cfg_text)
    return m.group(1) if m else ""


def _apply_wg_blob(cfg_text, blob):
    """Применяет новый WG blob-файл, возвращает новый текст конфига.

    Эквивалент sed из menu_action_set_wg_blob:
      s#(--blob=fakewgblob:@/opt/zapret2/files/fake/)\\S+#\\1<blob>#g

    ВАЖНО: используем \\g<1>, а не \\1 — иначе имя файла/число, начинающееся
    с цифры, сольётся с номером группы (\\1 + '25' == '\\125' == восьмеричный
    escape). В sed такой проблемы нет, но Python re.sub требует \\g<1>.
    """
    return re.sub(r"(--blob=fakewgblob:@/opt/zapret2/files/fake/)\S+",
                  r"\g<1>" + blob, cfg_text)


def _apply_wg_repeats(cfg_text, repeats):
    """Применяет новое значение repeats, возвращает новый текст конфига.

    Эквивалент sed из menu_action_wg_repeats:
      s#(blob=fakewgblob:repeats=)[0-9]+#\\1<repeats>#g

    ВАЖНО: \\g<1> вместо \\1 — иначе '\\1'+'25'=='\\125' (восьмеричный escape).
    """
    return re.sub(r"(blob=fakewgblob:repeats=)[0-9]+",
                  r"\g<1>" + str(repeats), cfg_text)


# ===========================================================================
# Фейковое состояние роутера
# ===========================================================================

class FakeRouterState:
    """Всё фейковое состояние живёт в self.tmpdir. Потокобезопасно через лок."""

    def __init__(self, config_default_path, service_state, lock_state,
                 check_result, simulate_error, provider, fake_dir, delay=3.0, status_delay=0.0):
        self.tmpdir = tempfile.mkdtemp(prefix="z2r_fake_")
        self.lock = threading.Lock()

        # Директория с fake-файлами
        self.fake_dir = fake_dir

        # Фейковый config — копия config.default
        self.config_path = os.path.join(self.tmpdir, "config")
        shutil.copyfile(config_default_path, self.config_path)
        self.cfg_text = _read_text(self.config_path)

        # Фейковая orchestra-директория
        self.orch_dir = os.path.join(self.tmpdir, "orchestra")
        os.makedirs(self.orch_dir, exist_ok=True)
        self.lock_file = os.path.join(self.orch_dir, "locked.tsv")
        self.lock_manual_file = os.path.join(self.orch_dir, "locked.manual.tsv")
        for f in (self.lock_file, self.lock_manual_file):
            open(f, "w", encoding="utf-8").close()

        # Фейковый profile.lock
        self.profile_lock = os.path.join(self.tmpdir, "profile.lock")
        open(self.profile_lock, "w", encoding="utf-8").close()

        # Динамические флаги
        self.nfqws2_running = (service_state == "running")
        self.check_result = check_result  # ok | fail | mixed
        self.simulate_error = set(simulate_error or [])
        self.provider = provider

        # Искусственные задержки (сек) на «медленных» операциях — чтобы
        # тестировать спиннеры/«Обновление...»/«Сохранение и проверка...».
        # zapret2 на реальном устройстве стартует не мгновенно, проверки тоже
        # занимают время. Меняются в рантайме через dev-API.
        self.delays = {
            "service": float(delay),
            "check": float(delay),
            "set-lock": float(delay),
            "clear-lock": float(delay),
            "status": float(status_delay),
        }

        # Применяем стартовый сценарий локов
        self._apply_lock_state(lock_state)

    # --- внутреннее -------------------------------------------------------

    def _save_config(self):
        with open(self.config_path, "w", encoding="utf-8") as fh:
            fh.write(self.cfg_text)

    def _apply_lock_state(self, lock_state):
        """Разбор --lock-state: 'none' | 'profile=strat,...' (strat: N|0|auto)."""
        if not lock_state or lock_state == "none":
            return
        for token in lock_state.split(","):
            token = token.strip()
            if not token:
                continue
            if "=" not in token:
                continue
            prof_s, strat = token.split("=", 1)
            prof_s, strat = prof_s.strip(), strat.strip()
            if not re.match(r"^[1-9]$", prof_s):
                continue
            prof = int(prof_s)
            pl = proto_list(prof)
            if not pl:
                continue
            # Записываем как сохранённое состояние (profile.lock + locked.tsv)
            profile_state_set_and_apply(self, prof, pl, strat)

    # --- чтение для api_status -------------------------------------------

    def strategy_locks_status_text(self):
        """strategy_locks_status_text() — _lib.sh:139."""
        for f in (self.lock_file, self.lock_manual_file, self.profile_lock):
            if os.path.exists(f) and os.path.getsize(f) > 0:
                return "Есть"
        return "Нет"

    def profile_json(self, pid, label, desc):
        proto = profile_proto(pid)
        current = profile_state_get(self.profile_lock, self.lock_file, pid, proto)
        maxstrat = config_profile_max_strategy(pid, self.cfg_text)
        return {
            "profile": pid,
            "label": label,
            "description": desc,
            "current_lock": current,
            "max_strategy": maxstrat,
        }

    def all_profiles_json(self):
        return [self.profile_json(p, l, d) for (p, l, d) in PROFILES]

    def build_status(self):
        return {
            "zapret2_running": bool(self.nfqws2_running),
            "strategy_locks_status": self.strategy_locks_status_text(),
            "hostlist_mode": config_mode_text("hostlist", self.cfg_text),
            "fwtype": config_mode_text("fwtype", self.cfg_text),
            "flowoffload": config_mode_text("flowoffload", self.cfg_text),
            "tls_blob_mode": config_mode_text("tls_blob_menu", self.cfg_text),
            "profiles": self.all_profiles_json(),
        }

    # --- генерация результатов проверок ----------------------------------

    def _pair(self, idx):
        """tls12/tls13 по режиму check_result (детерминированно)."""
        if self.check_result == "ok":
            return 1, 1
        if self.check_result == "fail":
            return 0, 0
        # mixed: чередуем, чтобы в UI были и OK, и FAIL
        return (idx % 2), (1 - idx % 2)

    def _check_item(self, label, target, idx):
        t12, t13 = self._pair(idx)
        return {"label": label, "target": target, "tls12": t12, "tls13": t13}

    def build_check(self):
        results = []
        for i, (label, target) in enumerate(CHECK_TARGETS):
            if target is None:
                target = "https://{0}/".format(YT_CLUSTER_FALLBACK)
            results.append(self._check_item(label, target, i))
        return {"results": results}

    def profile_check_json(self, profile):
        """profile_check_json() — _lib.sh:180."""
        pid = int(profile)
        if pid in (5, 6):
            return {"results": [], "message": UDP_CHECK_MESSAGE}
        targets = PROFILE_CHECK.get(pid, [])
        if not targets:
            return {"results": []}
        results = []
        for i, (label, target) in enumerate(targets):
            if target is None:
                target = "https://{0}/".format(YT_CLUSTER_FALLBACK)
            results.append(self._check_item(label, target, i))
        return {"results": results}

    # --- TLS blob -----------------------------------------------------------

    def build_tls_blob_settings(self):
        """api_tls_blob_get() — _lib.sh."""
        current_blob = config_tls_blob_current(self.cfg_text)
        current_mode = config_tls_blob_mode_value(self.cfg_text)
        available_blobs = _scan_fake_blobs(self.fake_dir)
        return {
            "current_mode": current_mode,
            "current_blob": current_blob,
            "available_blobs": available_blobs,
        }

    def apply_tls_blob(self, blob):
        """api_tls_blob_set() — _lib.sh."""
        # Валидация
        if blob != "fake_default_tls":
            valid = False
            if blob in ("stun.bin", "rdp.bin"):
                valid = True
            elif blob.startswith("tls_") or blob == "custom_tls.bin":
                valid = True
            if not valid:
                raise ValueError("Некорректное значение блоба")
            # Проверка существования файла (в fake_dir)
            if not os.path.isfile(os.path.join(self.fake_dir, blob)):
                raise ValueError("Файл блоба не существует")
        # Проверка наличия строки --blob=maxru:@... в конфиге
        if "--blob=maxru:@/opt/zapret2/files/fake/" not in self.cfg_text:
            raise ValueError("Строка --blob=maxru не найдена в конфиге")
        # Применение
        self.cfg_text = _apply_tls_blob(self.cfg_text, blob)
        self._save_config()
        return {"ok": True, "reboot_required": True}

    # --- WireGuard blob / repeats -----------------------------------------

    def build_wg_blob_settings(self):
        """api_wg_blob_get() — _lib.sh."""
        current_blob = config_wg_blob_current(self.cfg_text)
        current_repeats = config_wg_repeats_current(self.cfg_text)
        available_blobs = _scan_wg_blobs(self.fake_dir)
        return {
            "current_blob": current_blob,
            "current_repeats": current_repeats,
            "available_blobs": available_blobs,
        }

    def apply_wg_blob(self, blob):
        """api_wg_blob_set() — _lib.sh."""
        # Валидация: только wg_initial_fake_*
        if not blob.startswith("wg_initial_fake_"):
            raise ValueError("Некорректное значение блоба")
        if not os.path.isfile(os.path.join(self.fake_dir, blob)):
            raise ValueError("Файл блоба не существует")
        if "--blob=fakewgblob:@/opt/zapret2/files/fake/" not in self.cfg_text:
            raise ValueError("Стратегия WireGuard не найдена в конфиге (нет --blob=fakewgblob:@...)")
        self.cfg_text = _apply_wg_blob(self.cfg_text, blob)
        self._save_config()
        return {"ok": True, "reboot_required": True}

    def apply_wg_repeats(self, repeats):
        """api_wg_repeats_set() — _lib.sh."""
        # Валидация: целое число 2..99 (как в menu_action_wg_repeats)
        if not re.match(r"^[0-9]+$", str(repeats)):
            raise ValueError("Некорректное значение repeats")
        val = int(repeats)
        if val < 2 or val > 99:
            raise ValueError("Значение repeats должно быть от 2 до 99")
        if "blob=fakewgblob:repeats=" not in self.cfg_text:
            raise ValueError("Стратегия WireGuard не найдена в конфиге (нет blob=fakewgblob:repeats=)")
        self.cfg_text = _apply_wg_repeats(self.cfg_text, val)
        self._save_config()
        return {"ok": True, "reboot_required": True}

    # --- dev-снимок -------------------------------------------------------

    def dev_snapshot(self):
        locks = {}
        for pid, _, _ in PROFILES:
            proto = profile_proto(pid)
            locks[str(pid)] = profile_state_get(self.profile_lock, self.lock_file,
                                                pid, proto)
        return {
            "nfqws2_running": bool(self.nfqws2_running),
            "check_result": self.check_result,
            "simulate_error": sorted(self.simulate_error),
            "provider": self.provider,
            "locks": locks,
            "delays": dict(self.delays),
            "tmpdir": self.tmpdir,
            "config_path": self.config_path,
            "orch_dir": self.orch_dir,
        }


# ===========================================================================
# HTTP-обработчик
# ===========================================================================

# (status_code, reason) для send_error — соответствуют CGI Status-строкам
_HTTP_STATUS = {
    200: (200, "OK"),
    400: (400, "Bad Request"),
    500: (500, "Internal Server Error"),
}


class FakeRouterHandler(BaseHTTPRequestHandler):
    server_version = "z2r-fake-router/1.0"
    protocol_version = "HTTP/1.1"

    # --- helpers ----------------------------------------------------------

    @property
    def state(self):
        return self.server.router_state

    def _log(self, msg):
        print("[fake-router] {0}".format(msg), flush=True)

    def _sleep_for(self, category):
        """Искусственная задержка операции (симуляция медленного роутера).

        Вызывается ВНЕ state.lock, чтобы не блокировать параллельные запросы
        (например, одновременный опрос /status во время долгого service start).
        """
        d = self.state.delays.get(category, 0.0)
        if d and d > 0:
            time.sleep(d)

    def _send_json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        reason = _HTTP_STATUS.get(code, (code, ""))[1]
        self.send_response(code, reason)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_error_json(self, code, message):
        self._send_json({"error": message}, code)

    def _read_params(self, body_raw=None):
        """parse_params() — _lib.sh:58: query (GET) или тело (POST).

        Тело POST уже прочитано в do_POST и передаётся через body_raw, чтобы
        не читать rfile повторно (повторный read блокируется до таймаута).
        """
        parsed = urlparse(self.path)
        params = {k: v[-1] for k, v in parse_qs(parsed.query, keep_blank_values=True).items()}
        if body_raw is not None:
            raw = body_raw.decode("utf-8", "replace")
            for k, v in parse_qs(raw, keep_blank_values=True).items():
                params[k] = v[-1]
        return parsed, params

    def _serve_static(self, relpath):
        """Отдаёт реальные файлы из webui/ как есть."""
        webui_root = self.server.webui_root
        # Нормализуем путь и не даём выйти за пределы webui/
        safe = os.path.normpath(os.path.join(webui_root, relpath))
        if not safe.startswith(os.path.abspath(webui_root)):
            self._send_json({"error": "forbidden"}, 403)
            return
        if not os.path.isfile(safe):
            self._send_json({"error": "not found: {0}".format(relpath)}, 404)
            return
        ext = os.path.splitext(safe)[1].lower()
        ctype = {
            ".html": "text/html; charset=utf-8",
            ".js": "application/javascript; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".json": "application/json; charset=utf-8",
            ".svg": "image/svg+xml",
            ".png": "image/png",
            ".ico": "image/x-icon",
        }.get(ext, "application/octet-stream")
        with open(safe, "rb") as fh:
            body = fh.read()
        self.send_response(200, "OK")
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    # --- маршрутизация CGI ------------------------------------------------

    def _dispatch_cgi(self, endpoint, body_raw=None):
        """Общий диспетчер для /cgi-bin/*.cgi. endpoint: status|set-lock|..."""
        parsed, params = self._read_params(body_raw)
        with self.state.lock:
            snapshot = self.state.dev_snapshot()
            running = snapshot["nfqws2_running"]
            locks = snapshot["locks"]

        # --simulate-error: эндпоинт падает 500
        if endpoint in self.state.simulate_error:
            self._log("{0} {1} -> 500 (simulate-error)".format(
                self.command, parsed.path))
            self._send_error_json(500, "Симуляция ошибки эндпоинта '{0}'".format(endpoint))
            return

        if endpoint == "status":
            self._sleep_for("status")
            self._log("GET {0} | nfqws2={1} locks={2}".format(
                parsed.path, running, locks))
            with self.state.lock:
                self._send_json(self.state.build_status())
            return

        if endpoint == "check":
            self._sleep_for("check")
            self._log("{0} {1} | check_result={2}".format(
                self.command, parsed.path, self.state.check_result))
            with self.state.lock:
                self._send_json(self.state.build_check())
            return

        if endpoint == "service":
            self._handle_service(params, parsed)
            return

        if endpoint == "set-lock":
            self._handle_set_lock(params, parsed)
            return

        if endpoint == "clear-lock":
            self._handle_clear_lock(params, parsed)
            return

        if endpoint == "settings":
            self._handle_settings(params, parsed)
            return

        self._send_error_json(404, "Неизвестный эндпоинт: {0}".format(endpoint))

    # --- обработчики эндпоинтов ------------------------------------------

    def _handle_service(self, params, parsed):
        # api_service() — _lib.sh:244
        action = params.get("action", "")
        if action not in ("start", "stop", "restart"):
            self._log("{0} {1} | action='{2}' -> 400".format(
                self.command, parsed.path, action))
            self._send_error_json(400, ERR_BAD_ACTION)
            return
        # zapret2 стартует/останавливается не мгновенно — задержка вне блокировки
        self._sleep_for("service")
        with self.state.lock:
            # Эмулируем init-скрипт: меняем состояние nfqws2
            if action == "start":
                self.state.nfqws2_running = True
            elif action == "stop":
                self.state.nfqws2_running = False
            elif action == "restart":
                self.state.nfqws2_running = True
            self._log("{0} {1} | action={2} -> nfqws2={3}".format(
                self.command, parsed.path, action, self.state.nfqws2_running))
            self._send_json({"ok": True})

    def _handle_set_lock(self, params, parsed):
        # api_set_lock() — _lib.sh:214
        profile = params.get("profile", "")
        strategy = params.get("strategy", "")
        if not re.match(r"^[1-7]$", profile):
            self._send_error_json(400, ERR_BAD_PROFILE)
            return
        if not re.match(r"^[0-9]+$", strategy):
            self._send_error_json(400, ERR_BAD_STRATEGY)
            return
        # Валидация диапазона (чтение cfg_text атомарно благодаря GIL — можно
        # вне блокировки); затем искусственная задержка apply+check.
        maxstrat = config_profile_max_strategy(int(profile), self.state.cfg_text)
        strat = int(strategy)
        if strat != 0 and not (1 <= strat <= (maxstrat or 0)):
            self._send_error_json(400, ERR_STRATEGY_RANGE)
            return
        pl = proto_list(int(profile))
        if not pl:
            self._send_error_json(400, ERR_NO_PROTO)
            return
        self._sleep_for("set-lock")
        with self.state.lock:
            ok = profile_state_set_and_apply(self.state, int(profile), pl, strategy)
            if not ok:
                self._send_error_json(500, ERR_SAVE_STATE)
                return
            # Профиль 6: restart (эмуляция)
            if int(profile) == 6:
                self.state.nfqws2_running = True
            check_json = self.state.profile_check_json(int(profile))
            self._log("{0} {1} | profile={2} strategy={3} -> ok (max={4})".format(
                self.command, parsed.path, profile, strategy, maxstrat))
            self._send_json({"ok": True, "check": check_json})

    def _handle_clear_lock(self, params, parsed):
        # api_clear_lock() — _lib.sh:232
        profile = params.get("profile", "")
        if not re.match(r"^[1-7]$", profile):
            self._send_error_json(400, ERR_BAD_PROFILE)
            return
        pl = proto_list(int(profile))
        if not pl:
            self._send_error_json(400, ERR_NO_PROTO)
            return
        self._sleep_for("clear-lock")
        with self.state.lock:
            ok = profile_state_set_and_apply(self.state, int(profile), pl, "auto")
            if not ok:
                self._send_error_json(500, ERR_RESET_STATE)
                return
            if int(profile) == 6:
                self.state.nfqws2_running = True
            self._log("{0} {1} | profile={2} -> cleared (auto)".format(
                self.command, parsed.path, profile))
            self._send_json({"ok": True})

    def _handle_settings(self, params, parsed):
        """Обработчик endpoint /cgi-bin/settings.cgi.

        GET  ?setting=wg_blob  -> настройки WireGuard (blob + repeats)
        GET  (без параметра)   -> настройки TLS-блоба (обратная совместимость)
        POST setting=tls_blob  -> смена TLS-блоба
        POST setting=wg_blob   -> смена WG-блоба
        POST setting=wg_repeats-> смена WG repeats
        """
        setting = params.get("setting", "")

        if self.command == "GET":
            with self.state.lock:
                if setting == "wg_blob":
                    self._log("GET {0} | wg_blob settings".format(parsed.path))
                    self._send_json(self.state.build_wg_blob_settings())
                else:
                    self._log("GET {0} | tls_blob settings".format(parsed.path))
                    self._send_json(self.state.build_tls_blob_settings())
            return

        if self.command == "POST":
            if setting == "tls_blob":
                blob = params.get("value", "")
                try:
                    with self.state.lock:
                        result = self.state.apply_tls_blob(blob)
                        self._log("POST {0} | tls_blob={1}".format(parsed.path, blob))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(400, str(e))
                return
            if setting == "wg_blob":
                blob = params.get("value", "")
                try:
                    with self.state.lock:
                        result = self.state.apply_wg_blob(blob)
                        self._log("POST {0} | wg_blob={1}".format(parsed.path, blob))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(400, str(e))
                return
            if setting == "wg_repeats":
                repeats = params.get("value", "")
                try:
                    with self.state.lock:
                        result = self.state.apply_wg_repeats(repeats)
                        self._log("POST {0} | wg_repeats={1}".format(parsed.path, repeats))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(400, str(e))
                return
            self._send_error_json(400, "Неизвестная настройка")
            return

        self._send_error_json(405, "Метод не поддерживается")

    # --- dev-эндпоинт (управление фейк-состоянием в рантайме) ------------

    def _handle_dev(self, parsed, params, body_raw):
        if parsed.path == "/__dev/state" and self.command == "GET":
            with self.state.lock:
                self._send_json(self.state.dev_snapshot())
            return
        if parsed.path == "/__dev/state" and self.command == "POST":
            try:
                payload = json.loads(body_raw.decode("utf-8")) if body_raw else {}
            except (ValueError, UnicodeDecodeError):
                self._send_error_json(400, "Невалидный JSON")
                return
            with self.state.lock:
                if "nfqws2_running" in payload:
                    self.state.nfqws2_running = bool(payload["nfqws2_running"])
                if "check_result" in payload:
                    self.state.check_result = payload["check_result"]
                if "provider" in payload:
                    self.state.provider = payload["provider"]
                if "simulate_error" in payload:
                    self.state.simulate_error = set(payload["simulate_error"] or [])
                if "lock_state" in payload:
                    # сброс текущих локов и применение новых
                    open(self.state.profile_lock, "w", encoding="utf-8").close()
                    open(self.state.lock_file, "w", encoding="utf-8").close()
                    self.state._apply_lock_state(payload["lock_state"])
                # Задержки: "delay" (число) задаёт service/check/set-lock/clear-lock
                # разом; "status_delay" (число) — только status; "delays" (dict)
                # — точечный перебор по категориям.
                if "delay" in payload:
                    for k in ("service", "check", "set-lock", "clear-lock"):
                        self.state.delays[k] = float(payload["delay"])
                if "status_delay" in payload:
                    self.state.delays["status"] = float(payload["status_delay"])
                if "delays" in payload and isinstance(payload["delays"], dict):
                    for k, v in payload["delays"].items():
                        if k in self.state.delays:
                            self.state.delays[k] = float(v)
                self._log("POST /__dev/state | updated -> {0}".format(
                    self.state.dev_snapshot()))
                self._send_json(self.state.dev_snapshot())
            return
        self._send_error_json(404, "Неизвестный dev-эндпоинт")

    # --- HTTP entry points ------------------------------------------------

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/__dev/state":
            self._handle_dev(parsed, {}, b"")
            return
        if path.startswith("/cgi-bin/") and path.endswith(".cgi"):
            endpoint = path[len("/cgi-bin/"):-len(".cgi")]
            self._dispatch_cgi(endpoint)
            return
        # Статика: '/' -> index.html
        relpath = path.lstrip("/")
        if relpath == "":
            relpath = "index.html"
        self._serve_static(relpath)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0) or 0)
        body_raw = self.rfile.read(length) if length else b""
        if path == "/__dev/state":
            self._handle_dev(parsed, {}, body_raw)
            return
        if path.startswith("/cgi-bin/") and path.endswith(".cgi"):
            endpoint = path[len("/cgi-bin/"):-len(".cgi")]
            self._dispatch_cgi(endpoint, body_raw)
            return
        self._send_error_json(404, "Не найдено: {0}".format(path))

    def log_message(self, fmt, *args):
        # Подавляем дефолтный шум access-лога; свой лог пишем в хендлерах.
        pass


# ===========================================================================
# CLI / main
# ===========================================================================

def _default_webui_root():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, os.pardir))


def _default_repo_root():
    return os.path.abspath(os.path.join(_default_webui_root(), os.pardir))


def _parse_args(argv):
    p = argparse.ArgumentParser(
        description="Фейковый dev-сервер zapret2 WebUI (имитация роутера). "
                    "Только stdlib. Не трогает /opt/zapret2.")
    p.add_argument("--port", type=int, default=8099,
                   help="Порт HTTP (по умолчанию 8099, НЕ 17682, чтобы не "
                        "конфликтовать с реальным WebUI на устройстве)")
    p.add_argument("--host", default="127.0.0.1", help="Адрес привязки")
    p.add_argument("--webui-root", default=None,
                   help="Каталог со статикой webui (по умолчанию ../ от скрипта)")
    p.add_argument("--config", default=None,
                   help="Путь к config.default (по умолчанию <repo>/config.default)")
    p.add_argument("--service-state", choices=["running", "stopped"],
                   default="running", help="Состояние nfqws2 при старте")
    p.add_argument("--lock-state", default="none",
                   help="Стартовые локи: 'none' или 'profile=strat,...' "
                        "(strat: N|0|auto), напр. '2=5,4=0,6=12'")
    p.add_argument("--check-result", choices=["ok", "fail", "mixed"],
                   default="ok", help="Результаты TLS-проверок в /check и set-lock")
    p.add_argument("--simulate-error", default="",
                   help="Эндпоинты, отдающие 500 (через запятую): "
                        + ",".join(sorted(SIMULATABLE)))
    p.add_argument("--provider", default="Не определён",
                   help="Строка провайдера (только для лога/dev-состояния; "
                        "в реальном WebUI этого поля нет)")
    p.add_argument("--delay", type=float, default=3.0, metavar="SECONDS",
                   help="Искусственная задержка (сек) на медленных операциях "
                        "(service/check/set-lock/clear-lock) — чтобы тестировать "
                        "спиннеры. По умолчанию 3.0")
    p.add_argument("--status-delay", type=float, default=0.0, metavar="SECONDS",
                   help="Задержка (сек) для /status (по умолчанию 0 — статус "
                        "быстрый; задайте >0 для теста спиннера «Обновление...»)")
    return p.parse_args(argv)


def main(argv=None):
    args = _parse_args(argv or sys.argv[1:])

    # На Windows консоль часто cp866/cp1251: русский текст в логах не должен
    # ронять сервер кодировкой. Переводим stdout/stderr в UTF-8 (с заменой
    # непредставимых символов). Python 3.7+.
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except (ValueError, OSError):
                pass

    webui_root = args.webui_root or _default_webui_root()
    config_path = args.config or os.path.join(_default_repo_root(), "config.default")
    fake_dir = os.path.join(_default_repo_root(), "fake")

    if not os.path.isdir(webui_root):
        sys.exit("webui-root не найден: {0}".format(webui_root))
    if not os.path.isfile(os.path.join(webui_root, "index.html")):
        sys.exit("index.html не найден в webui-root: {0}".format(webui_root))
    if not os.path.isfile(config_path):
        sys.exit("config.default не найден: {0}".format(config_path))
    if not os.path.isdir(fake_dir):
        sys.exit("Директория fake не найден: {0}".format(fake_dir))

    sim_errors = [s.strip() for s in args.simulate_error.split(",") if s.strip()]
    bad = [s for s in sim_errors if s not in SIMULATABLE]
    if bad:
        sys.exit("Неизвестные --simulate-error: {0}. Допустимо: {1}".format(
            ",".join(bad), ",".join(sorted(SIMULATABLE))))

    state = FakeRouterState(
        config_default_path=config_path,
        service_state=args.service_state,
        lock_state=args.lock_state,
        check_result=args.check_result,
        simulate_error=sim_errors,
        provider=args.provider,
        fake_dir=fake_dir,
        delay=args.delay,
        status_delay=args.status_delay,
    )

    httpd = ThreadingHTTPServer((args.host, args.port), FakeRouterHandler)
    httpd.router_state = state
    httpd.webui_root = os.path.abspath(webui_root)

    print("=" * 64, flush=True)
    print("z2r fake-router WebUI dev-server", flush=True)
    print("  Фронтенд:      http://{0}:{1}/".format(args.host, args.port), flush=True)
    print("  webui-root:    {0}".format(httpd.webui_root), flush=True)
    print("  config:        {0}".format(config_path), flush=True)
    print("  tmp-состояние: {0}".format(state.tmpdir), flush=True)
    print("  Сценарий:      service={1} check={2} locks={3!r} errors={4}".format(
        args.port, args.service_state, args.check_result,
        args.lock_state, sim_errors or "нет"), flush=True)
    print("  Задержки:      delay={1}s (service/check/set-lock/clear-lock) "
          "status={2}s".format(args.port, args.delay, args.status_delay), flush=True)
    print("  dev-API:       GET/POST http://{0}:{1}/__dev/state".format(
        args.host, args.port), flush=True)
    print("  Остановить:    Ctrl+C", flush=True)
    print("=" * 64, flush=True)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[fake-router] остановлен пользователем", flush=True)
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
