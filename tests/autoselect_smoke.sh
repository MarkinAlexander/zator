#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d /tmp/zator-autoselect.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state" "$TMP_DIR/orch"

# ---- мок curl: фазовые планы. Проба = 2 head (TLS1.2, TLS1.3). ----
# Счётчик ПРОБ (не вызовов): каждая z2r_tls_check_target инкрементирует один
# из счётчиков: screen (без докачки) или rank (докачка). Для screen план
# задаёт токены обеих версий пробы N: SCREEN_P="<tok12,tok13>;<tok12,tok13>;..."
# Для rank: RANK_HEAD_P + RANK_DL_P (докачка идёт при 2xx/3xx).
cat > "$TMP_DIR/bin/curl" <<'MOOCK'
#!/bin/sh
cnt_dir="$AUTOK_MOCK_STATE"
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
  if [ -n "${Z2R_TLS_NO_DL:-}" ]; then kind=SCREEN; else kind=RANK; fi
  n="$(bump "$cnt_dir/head_$kind")"
  eval "plan=\${${kind}_P:-}"
  tok="$(printf '%s\n' "$plan" | awk -v n="$n" 'NR==(int((n-1)/2)+1) {print}')"
  v12="ok200"; v13="ok200"
  case "$tok" in
    pair:*) v12="${tok#pair:}" ;;
    *) v12="${tok%%,*}"; v13="${tok##*,}" ;;
  esac
  field="$v13"
  [ "$ver" = "12" ] && field="$v12"
  case "$field" in
    ok200)   [ -n "$hdr" ] && printf 'HTTP/2 200\r\n' >"$hdr"; echo "0.800 192.0.2.10"; exit 0 ;;
    code403) [ -n "$hdr" ] && printf 'HTTP/1.1 403\r\n' >"$hdr"; echo "0.900 192.0.2.10"; exit 0 ;;
    timeout) echo "8.004 -"; exit 28 ;;
    dns)     echo "- -"; exit 6 ;;
  esac
  echo "8.004 -"; exit 28
fi
# докачка: только в rank-пробах; исход по номеру rank-докачки
n="$(bump "$cnt_dir/rankdl")"
eval "mode=\${RANK_DL_P:-fail}"
m="$(printf '%s\n' "$mode" | awk -v n="$n" 'NR==(int((n-1)/2)+1) {print}')"
[ -n "$m" ] || m=fail
case "$m" in
  fast) echo "206 65536 1.000"; exit 0 ;;
  slow) echo "206 32768 4.000"; exit 0 ;;
  ok)   echo "206 65536 2.000"; exit 0 ;;
  *)    echo "000 0 10.002"; exit 28 ;;
esac
MOOCK
sed -i 's/MOOCK/MOCK/' "$TMP_DIR/bin/curl"
chmod +x "$TMP_DIR/bin/curl"

PATH="$TMP_DIR/bin:$PATH"
export PATH
export AUTOK_MOCK_STATE="$TMP_DIR/state"
# Планы мока — в окружении: их читает дочерний curl-мок.
export SCREEN_P RANK_P RANK_DL_P

for f in lib/autoselect.sh lib/netcheck.sh lib/strategies.sh z2r.sh; do
  bash -n "$REPO_DIR/$f" || fail "синтаксис $f"
done

# статика: разводка
grep -q 'strategies.sh dpidetect.sh autoselect.sh' "$REPO_DIR/z2r.sh" \
  || fail "z2r.sh: autoselect.sh не подключён"
grep -q 'F - быстрый подбор' "$REPO_DIR/lib/strategies.sh" \
  || fail "strategies.sh: нет пункта F в промпте профиля"
grep -q 'autoselect_run "domain"' "$REPO_DIR/lib/strategies.sh" \
  || fail "strategies.sh: доменный поток не вызывает autoselect_run"
grep -q 'Z2R_TLS_NO_DL' "$REPO_DIR/lib/netcheck.sh" \
  || fail "netcheck.sh: нет режима без докачки"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/netcheck.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/autoselect.sh"
plain="" green="" yellow="" red="" cyan="" Fgreen=""
Z2R_CURL_UA=smoke
export Z2R_AUTOSELECT_SETTLE=0 Z2R_AUTOSELECT_PAUSE=0

LOCK_LOG="$TMP_DIR/locklog"
: > "$LOCK_LOG"
orch_locked_state_get() { printf '%s\n' "${MOCK_PREV_LOCK:-auto}"; }
orch_locked_set() { printf 'set %s %s %s\n' "$1" "$2" "$3" >> "$LOCK_LOG"; }
orch_locked_clear() { printf 'clear %s %s\n' "$1" "$2" >> "$LOCK_LOG"; }
zapret2_running() { return 0; }
z2r_service_action() { return 0; }
date() { echo "12:00:00"; }
read() {
  # мок read: последний не-флаг аргумент — имя переменной
  local __a __v=""
  for __a in "$@"; do case "$__a" in -*) ;; *) __v="$__a" ;; esac; done
  [ -n "$__v" ] && printf -v "$__v" '%s' "$AUTOK_ANSWER"
  return 0
}

ORCH_DIR="$TMP_DIR/orch"
AUTOSELECT_DB="$ORCH_DIR/autoselect.tsv"

reset_case() {
  : > "$LOCK_LOG"
  rm -rf "$TMP_DIR/state"
  mkdir -p "$TMP_DIR/state"
  rm -f "$AUTOSELECT_DB"
  : > "$TMP_DIR/state/head_SCREEN"
  : > "$TMP_DIR/state/head_RANK"
  : > "$TMP_DIR/state/rankdl"
  SCREEN_P=""; RANK_P=""; RANK_DL_P=""
  AUTOK_ANSWER=""
  MOCK_PREV_LOCK="auto"
}

n_probes() { cat "$TMP_DIR/state/head_SCREEN" 2>/dev/null || echo 0; }
n_rankdl() { cat "$TMP_DIR/state/rankdl" 2>/dev/null || echo 0; }
n_rankheads() { cat "$TMP_DIR/state/head_RANK" 2>/dev/null || echo 0; }

# ---- сценарий 1: baseline ok -> подбор не запускается ----
reset_case
SCREEN_P="ok200,ok200"
out="$(autoselect_run domain example.com tls https://example.com/ 1 5 2>&1)" && rc=0 || rc=$?
[ "$rc" = "0" ] || fail "baseline-ok: rc=$rc"
grep -q 'подбор стратегий не нужен' <<<"$out" || fail "baseline-ok: нет сообщения"
[ "$(n_probes)" = "2" ] || fail "baseline-ok: должно быть 2 screen-вызова, было $(n_probes)"
# пробы-отсев не делались: лок стратегии не применялся
! grep -q 'set example.com tls [1-9]' "$LOCK_LOG" || fail "baseline-ok: отсев не должен стартовать"
[ "$(tail -n 1 "$LOCK_LOG")" = "clear example.com tls" ] || fail "baseline-ok: лок не восстановлен"

# ---- сценарий 2: блокируется; отсев находит 2 зелёных, ранжирование выбирает быстрейшую ----
reset_case
# пробы: 1=baseline(fail,fail) 2..6=отсев (5 стратегий), затем rank
SCREEN_P="timeout,timeout
timeout,timeout
ok200,ok200
timeout,timeout
ok200,ok200"
RANK_P="ok200,ok200
ok200,ok200"
RANK_DL_P="slow
fast"
export Z2R_AUTOSELECT_K=2
AUTOK_ANSWER=""
out="$(autoselect_run domain example.com tls https://example.com/ 1 5 2>&1)" && rc=0 || rc=$?
[ "$rc" = "0" ] || fail "main: rc=$rc"
grep -q 'Стратегия 4 применена' <<<"$out" || fail "main: нет применения стратегии 4: $(grep Стратегия <<<"$out" || true)"
# early-exit: отсев остановился на 2 зелёных — 5-я стратегия не проверялась
[ "$(n_probes)" = "10" ] || fail "main: screen-вызовов должно быть 10 (2+8), было $(n_probes)"
[ "$(n_rankheads)" = "4" ] || fail "main: rank-вызовов должно быть 4, было $(n_rankheads)"
[ "$(n_rankdl)" = "4" ] || fail "main: rank-докачек должно быть 4, было $(n_rankdl)"
grep -q 'set example.com tls 0' "$LOCK_LOG" || fail "main: нет базлайн-лока 0"
grep -q 'set example.com tls 4' "$LOCK_LOG" || fail "main: нет сохранения стратегии 4"
grep -q "$(printf '%s\t%s' example.com 4)" "$AUTOSELECT_DB" || fail "main: победа не в warm-кэше"
unset Z2R_AUTOSELECT_K

# ---- сценарий 3: зелёных нет -> полный проход, восстановление ----
reset_case
SCREEN_P="timeout,timeout
timeout,timeout
timeout,timeout
timeout,timeout"
out="$(autoselect_run profile 2 tls https://gv.test/ 1 3 2>&1)" && rc=0 || rc=$?
[ "$rc" = "0" ] || fail "nogreen: rc=$rc"
grep -q 'Зелёных стратегий не найдено' <<<"$out" || fail "nogreen: нет итога"
[ "$(tail -n 1 "$LOCK_LOG")" = "clear 2 tls" ] || fail "nogreen: локи профиля не восстановлены"

# ---- сценарий 4: warm-start порядок из кэша ----
reset_case
printf 'example.com\t9\t5\t1700\nexample.com\t2\t1\t1600\n' > "$AUTOSELECT_DB"
SCREEN_P="timeout,timeout
ok200,ok200
timeout,timeout"
RANK_P="ok200,ok200"
RANK_DL_P="ok"
AUTOK_ANSWER="0"
out="$(autoselect_run domain example.com tls https://example.com/ 1 9 2>&1)" && rc=0 || rc=$?
# первой проверена стратегия 9 (warm), второй 1, затем 2: лок 9 до лока 1
first_two="$(grep '^set example.com tls' "$LOCK_LOG" | head -2 | awk '{print $4}' | paste -sd, -)"
case "$first_two" in
  "9,1"|"0,9"|"0,1") ;;
  *) fail "warm: порядок локов '$first_two', ожидался 9 раньше 1" ;;
esac
grep -q 'Оставлены прежние локи' <<<"$out" || fail "warm: нет отмены"

# ---- сценарий 5: netcheck-патч — Z2R_TLS_NO_DL реально режет докачку ----
reset_case
SCREEN_P="ok200,ok200"
Z2R_TLS_NO_DL=1 out="$(z2r_tls_check_target https://x.test/)"
printf '%s\n' "$out" | sed -n 3p | grep -q '^skip$' || fail "NO_DL: докачка не отключилась"
unset Z2R_TLS_NO_DL

echo "autoselect smoke ok"
