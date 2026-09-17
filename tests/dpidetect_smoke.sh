#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d /tmp/zator-dpidetect.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state"

# ---- мок curl: детерминированные планы по фазам ----
# MOCK_P1 / MOCK_P2 — планы head-проб фаз (базлайн / стратегия), формат
# "токен_для_TLS1.2,токен_для_TLS1.3"; токены: ok200|code403|timeout|dns|tls.
# MOCK_DL_P1 / MOCK_DL_P2 — исход докачки фазы (ok206|fail), применяется к обеим
# параллельным докачкам фазы. Отдельный счётчик на версию убивает гонку
# порядка захвата лока между параллельными пробами.
cat > "$TMP_DIR/bin/curl" <<'MOCK'
#!/bin/sh
cnt_dir="$DPIDETECT_MOCK_STATE"
head=0
ver="x"
hdr=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-D" ] && hdr="$arg"
  [ "$arg" = "-I" ] && head=1
  case "$arg" in
    --tlsv1.2) ver=12 ;;
    --tlsv1.3) ver=13 ;;
  esac
  prev="$arg"
done
bump() {
  local f="$1" n
  while ! mkdir "$cnt_dir/lock" 2>/dev/null; do sleep 0.05; done
  n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$f"
  rmdir "$cnt_dir/lock"
  echo "$n"
}
if [ "$head" = 1 ]; then
  n="$(bump "$cnt_dir/head$ver")"
  eval "plan=\${MOCK_P$n:-}"
  field=2
  [ "$ver" = "12" ] && field=1
  mode="$(printf '%s\n' "$plan" | cut -d, -f"$field")"
  [ -n "$mode" ] || mode=timeout
  case "$mode" in
    ok200)   [ -n "$hdr" ] && printf 'HTTP/2 200\r\n' >"$hdr"; echo "0.800 192.0.2.10"; exit 0 ;;
    code403) [ -n "$hdr" ] && printf 'HTTP/1.1 403 Forbidden\r\n' >"$hdr"; echo "0.900 192.0.2.10"; exit 0 ;;
    dns)     echo "- -"; exit 6 ;;
    tls)     echo "0.500 -"; exit 35 ;;
    *)       echo "8.004 -"; exit 28 ;;
  esac
fi
# Фаза докачки = фаза текущих head-проб (докачки есть не в каждой фазе).
h12="$(cat "$cnt_dir/head12" 2>/dev/null || echo 0)"
h13="$(cat "$cnt_dir/head13" 2>/dev/null || echo 0)"
p="$h12"
[ "$h13" -gt "$p" ] && p="$h13"
eval "mode=\${MOCK_DL_P$p:-fail}"
case "$mode" in
  ok206) echo "206 65536 1.234"; exit 0 ;;
  *)     echo "000 0 10.002"; exit 28 ;;
esac
MOCK
chmod +x "$TMP_DIR/bin/curl"

# Моки для сценария tcpdump (dpidetect сам решает, звать ли их).
cat > "$TMP_DIR/bin/nslookup" <<'MOCK'
#!/bin/sh
cat <<'EOF'
Server:         192.168.1.1
Address:        192.168.1.1#53

Non-authoritative answer:
Name:   example.com
Address: 93.184.216.34
EOF
MOCK
chmod +x "$TMP_DIR/bin/nslookup"

cat > "$TMP_DIR/bin/tcpdump" <<'MOCK'
#!/bin/sh
echo "tcpdump args: $*" >> "$TCPDUMP_CALL_LOG"
cat <<'EOF'
12:00:00.100001 IP 10.0.0.1.12345 > 93.184.216.34.443: Flags [.], seq 1, ack 1
12:00:00.200001 IP 93.184.216.34.443 > 10.0.0.1.12345: Flags [R.], seq 2, ack 1
12:00:00.300001 IP 93.184.216.34.443 > 10.0.0.1.12346: Flags [R], seq 3
12:00:00.400001 IP 10.0.0.1.55555 > 93.184.216.34.443: Flags [R], seq 4
EOF
sleep 120
MOCK
chmod +x "$TMP_DIR/bin/tcpdump"

PATH="$TMP_DIR/bin:$PATH"
export PATH

for f in lib/dpidetect.sh lib/netcheck.sh lib/submenus.sh z2r.sh; do
  bash -n "$REPO_DIR/$f" || fail "синтаксис $f"
done

# ---- статическая разводка ----
grep -q 'strategies.sh dpidetect.sh submenus.sh' "$REPO_DIR/z2r.sh" \
  || fail "z2r.sh: dpidetect.sh не подключён в Z2R_LIB_FILES"
grep -q 'submenu_item "12" "Диагностика: домен ломает DPI или обход?"' "$REPO_DIR/lib/submenus.sh" \
  || fail "submenus.sh: нет пункта 12 в подменю стратегий"
grep -q '"12")' "$REPO_DIR/lib/submenus.sh" && grep -q 'dpidetect_menu' "$REPO_DIR/lib/submenus.sh" \
  || fail "submenus.sh: пункт 12 не вызывает dpidetect_menu"
grep -q 'submenu_item "9" "Кто сломал домен? (DPI или обход)"' "$REPO_DIR/lib/submenus.sh" \
  || fail "submenus.sh: нет пункта 9 (диагностика) в управлении доменами"
grep -q 'dpidetect_domain_ask' "$REPO_DIR/lib/submenus.sh" \
  || fail "submenus.sh: domains_submenu не вызывает dpidetect_domain_ask"
# Прерывание/сбой пробы обязаны восстанавливать лок и останавливать tcpdump.
grep -q 'return 130' "$REPO_DIR/lib/dpidetect.sh" \
  || fail "dpidetect.sh: нет кода возврата 130 на прерывание"
grep -Eq 'trap .*dpidetect_interrupted' "$REPO_DIR/lib/dpidetect.sh" \
  || fail "dpidetect.sh: нет trap на INT"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/netcheck.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/dpidetect.sh"

plain="" green="" yellow="" red="" cyan=""
Z2R_CURL_UA="${Z2R_CURL_UA:-smoke}"
export Z2R_TLS_WAIT_BOTH=1   # обе пробы каждой фазы доходят до конца -> ровно 2 head-вызова на фазу
export DPIDETECT_SETTLE=0    # без пауз в тестах (TTL-пауза проверяется логикой, не сном)

# ---- моки zator-окружения ----
LOCK_LOG="$TMP_DIR/locklog"
: > "$LOCK_LOG"
orch_locked_state_get() { printf '%s\n' "${MOCK_PREV_LOCK:-auto}"; }
orch_locked_set() { printf 'set %s %s %s\n' "$1" "$2" "$3" >> "$LOCK_LOG"; }
orch_locked_clear() { printf 'clear %s %s\n' "$1" "$2" >> "$LOCK_LOG"; }
zapret2_running() { return 0; }
pause_enter() { :; }
z2r_normalize_domain() { printf '%s\n' "$1" | tr 'A-Z' 'a-z'; }
config_keenetic_detect_default_iface() { echo "wan0"; }

export DPIDETECT_MOCK_STATE="$TMP_DIR/state"
export MOCK_P1="" MOCK_P2="" MOCK_DL_P1="" MOCK_DL_P2=""

reset_case() {
  : > "$LOCK_LOG"
  rm -rf "$TMP_DIR/state"
  mkdir -p "$TMP_DIR/state"
  MOCK_PREV_LOCK="auto"
  DPIDETECT_TCPDUMP=0
}

run_case() {
  local out rc
  out="$(dpidetect_run domain example.com https://example.com/ 2>&1)" && rc=0 || rc=$?
  printf '%s\n' "$out"
  [ "$rc" = "0" ] || return "$rc"
}

verdict_of() {
  run_case | sed -n 's/^Вердикт: //p' | tail -n 1
}

# ---- unit: классификатор ----
check() {
  [ "$2" = "$3" ] || fail "classify($1): ожидалось '$3', получено '$2'"
}
check "fail+ok"     "$(dpidetect_classify fail ok)"     "blocked_fixed"
check "fail+warn"   "$(dpidetect_classify fail warn)"   "blocked_improved"
check "fail+fail"   "$(dpidetect_classify fail fail)"   "blocked_nofix"
check "ok+ok"       "$(dpidetect_classify ok ok)"       "not_blocked"
check "ok+warn"     "$(dpidetect_classify ok warn)"     "broken_by_strategy"
check "ok+fail"     "$(dpidetect_classify ok fail)"     "broken_by_strategy"
check "warn+fail"   "$(dpidetect_classify warn fail)"   "broken_by_strategy"
check "warn+ok"     "$(dpidetect_classify warn ok)"     "blocked_fixed"
check "warn+warn"   "$(dpidetect_classify warn warn)"   "not_blocked"

# ---- интеграция: вердикты по планам мока ----
# Фаза = 2 head-пробы (TLS 1.2 и 1.3); докачка идёт только после ответа 2xx/3xx.
reset_case
MOCK_P1="timeout,timeout" MOCK_P2="ok200,ok200" MOCK_DL_P2=ok206
out="$(run_case)"
v="$(sed -n 's/^Вердикт: //p' <<<"$out" | tail -n 1)"
[ "$v" = "blocked_fixed" ] || fail "blocked_fixed: получено '$v'"
grep -q 'стратегия 1 чинит его' <<<"$out" || fail "blocked_fixed: нет человекочитаемого итога"

reset_case
MOCK_P1="ok200,ok200" MOCK_DL_P1=ok206 MOCK_P2="timeout,timeout"
v="$(verdict_of)"
[ "$v" = "broken_by_strategy" ] || fail "broken_by_strategy (ok->fail): получено '$v'"

reset_case
MOCK_P1="ok200,ok200" MOCK_DL_P1=ok206 MOCK_P2="code403,timeout"
v="$(verdict_of)"
# 4xx = транспорт пробит: единственная версия с 403 даёт ok, не warn.
[ "$v" = "not_blocked" ] || fail "403-семантика: получено '$v' (ожидался not_blocked)"

reset_case
MOCK_P1="ok200,ok200" MOCK_P2="ok200,ok200" MOCK_DL_P1=ok206 MOCK_DL_P2=ok206
v="$(verdict_of)"
[ "$v" = "not_blocked" ] || fail "not_blocked: получено '$v'"

reset_case
MOCK_P1="timeout,timeout" MOCK_P2="timeout,timeout"
v="$(verdict_of)"
[ "$v" = "blocked_nofix" ] || fail "blocked_nofix: получено '$v'"

# blocked_improved покрыт юнит-тестами классификатора: честный warn движка
# (retry-докачка) недетерминирован в моке из-за параллельных проб.

reset_case
MOCK_P1="dns,dns" MOCK_P2="dns,dns"
v="$(verdict_of)"
[ "$v" = "dead_domain" ] || fail "dead_domain: получено '$v'"

# ---- восстановление локов ----
reset_case
MOCK_P1="ok200,ok200" MOCK_P2="ok200,ok200" MOCK_DL_P1=ok206 MOCK_DL_P2=ok206
run_case >/dev/null
grep -q 'set example.com tls 0' "$LOCK_LOG" || fail "восстановление: нет базлайн-лока 0"
grep -q 'set example.com tls 1' "$LOCK_LOG" || fail "восстановление: нет лока кандидата 1"
[ "$(tail -n 1 "$LOCK_LOG")" = "clear example.com tls" ] || fail "восстановление auto: последняя операция должна быть clear"

reset_case
MOCK_PREV_LOCK=5
MOCK_P1="ok200,ok200" MOCK_P2="ok200,ok200" MOCK_DL_P1=ok206 MOCK_DL_P2=ok206
run_case >/dev/null
grep -q 'set example.com tls 5' "$LOCK_LOG" || fail "восстановление: прежний лок 5 не возвращён"
[ "$(tail -n 1 "$LOCK_LOG")" = "set example.com tls 5" ] || fail "восстановление 5: последняя операция должна быть set 5"

# Кандидат из аргумента сильнее прежнего лока.
reset_case
MOCK_PREV_LOCK=5
MOCK_P1="timeout,timeout" MOCK_P2="ok200,ok200" MOCK_DL_P2=ok206
out="$(dpidetect_run domain example.com https://example.com/ 2 2>&1)"
v="$(sed -n 's/^Вердикт: //p' <<<"$out" | tail -n 1)"
[ "$v" = "blocked_fixed" ] || fail "кандидат=2: вердикт '$v'"
grep -q 'set example.com tls 2' "$LOCK_LOG" || fail "кандидат=2: лок 2 не применялся"

# ---- zapret2 не запущен: отказ без записей в локи ----
reset_case
zapret2_running() { return 1; }
out="$(dpidetect_run domain example.com https://example.com/ 2>&1)" && rc=0 || rc=$?
zapret2_running() { return 0; }
[ "$rc" = "1" ] || fail "zapret2 не запущен: ожидался rc=1, получен $rc"
grep -q 'zapret2 не запущен' <<<"$out" || fail "нет сообщения о незапущенном zapret2"
[ ! -s "$LOCK_LOG" ] || fail "при незапущенном zapret2 локи не должны меняться"

# ---- сбой пробы: восстановление лока и rc=1 ----
reset_case
MOCK_P1="ok200,ok200"
DPIDETECT_MOCK_STATE_BAK="$DPIDETECT_MOCK_STATE"
out="$(TMPDIR="$TMP_DIR/nodir" dpidetect_run domain example.com https://example.com/ 2>&1)" && rc=0 || rc=$?
[ "$rc" = "1" ] || fail "сбой пробы: ожидался rc=1, получен $rc"
grep -q 'Проба базлайна не удалась' <<<"$out" || fail "сбой пробы: нет сообщения"
[ "$(tail -n 1 "$LOCK_LOG")" = "clear example.com tls" ] || fail "сбой пробы: лок не восстановлен"

# ---- tcpdump-подтверждение RST ----
reset_case
TCPDUMP_CALL_LOG="$TMP_DIR/tcpdumplog"
: > "$TCPDUMP_CALL_LOG"
export TCPDUMP_CALL_LOG
DPIDETECT_TCPDUMP=1
MOCK_P1="timeout,timeout" MOCK_P2="ok200,ok200" MOCK_DL_P2=ok206
out="$(dpidetect_run domain example.com https://example.com/ 2>&1)"
grep -q 'RST всего: 3, от сервера (443→): 2' <<<"$out" || fail "tcpdump: неверный подсчёт RST: $(grep 'RST всего' <<<"$out" || true)"
grep -q 'wan0' "$TCPDUMP_CALL_LOG" || fail "tcpdump: не вызван с WAN-интерфейсом wan0"
DPIDETECT_TCPDUMP=0

echo "dpidetect smoke ok"
