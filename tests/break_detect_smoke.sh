#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d /tmp/zator-break.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------- 1. Статика: синтаксис и разводка ----------

for f in z2r.sh lib/dpidetect.sh lua/break-validator.sh Entware/z2r-break-validator init.d/openwrt/z2r-break-validator; do
  bash -n "$REPO_DIR/$f" || fail "синтаксис $f"
done

# config.default: init модуля + горячий exclude на 10 TCP-профилях, UDP не тронут.
grep -q '^--lua-init=@/opt/zator/lua/break-detector.lua$' "$REPO_DIR/config.default" \
  || fail "config.default: нет --lua-init break-detector.lua"
n="$(grep -c 'exclude_hostlist=/opt/zator/lists/z2r_broken_hosts.txt' "$REPO_DIR/config.default" || true)"
[ "$n" = "10" ] || fail "config.default: exclude_hostlist ожидается на 10 строках, найдено $n"
while IFS= read -r line; do
  case "$line" in
    *proto=udp*) fail "config.default: exclude_hostlist попал на UDP-профиль: $line" ;;
  esac
done < <(grep 'exclude_hostlist=/opt/zator/lists/z2r_broken_hosts.txt' "$REPO_DIR/config.default")
# Ключевые TCP-профили покрыты: ручные 1-4/8/9 + роутер 3S + авто 3/4/9.
for keypat in 'circular_locked:key=1:' 'circular_locked:key=2:' 'circular_locked:key=3:' \
              'circular_locked:key=4:' 'circular_locked:key=8:' 'circular_locked:key=9:' \
              'circular_quality:key=3:' 'circular_quality:key=4:' 'circular_quality:key=9:'; do
  found="$(grep -c "${keypat}.*exclude_hostlist=/opt/zator/lists/z2r_broken_hosts.txt" "$REPO_DIR/config.default" || true)"
  [ "$found" -ge 1 ] || fail "config.default: $keypat без exclude_hostlist"
done

# Хуки в оркестраторах (guarded — старые конфиги без модуля не падают).
grep -q 'type(z2r_break_track) == "function"' "$REPO_DIR/orchestra/locked.lua" \
  || fail "locked.lua: нет guarded-вызова z2r_break_track"
grep -q 'z2r_break_track(desync, gate_host, hrec.nstrategy)' "$REPO_DIR/orchestra/locked.lua" \
  || fail "locked.lua: вызов z2r_break_track без gate_host/nstrategy"
grep -q 'type(z2r_break_note) == "function"' "$REPO_DIR/lua/combined-detector.lua" \
  || fail "combined-detector.lua: нет guarded-вызова z2r_break_note"
grep -q 'z2r_break_note(desync, hostkey, hrec.nstrategy, is_failure, is_success)' "$REPO_DIR/lua/combined-detector.lua" \
  || fail "combined-detector.lua: вызов z2r_break_note без вердиктов детекторов"
# Хук в locked.lua стоит ПОСЛЕ лок-ветвления: выключенный локом 0 профиль не считает отказы.
awk '/locked == 0 then/{z=1} /z2r_break_track\(/{if(!z) exit 1}' "$REPO_DIR/orchestra/locked.lua" \
  || fail "locked.lua: z2r_break_track вызывается до ветки locked==0"

# Модуль: ключевые элементы.
grep -q '/tmp/z2r-break-verdicts.tsv' "$REPO_DIR/lua/break-detector.lua"   || fail "break-detector.lua: нет чтения RAM-кэша вердиктов"
grep -q 'z2r_break_verdict_cooldown' "$REPO_DIR/lua/break-detector.lua"   || fail "break-detector.lua: нет переиспользования вердиктов"
grep -q 'VERDICTS_FILE=' "$REPO_DIR/lua/break-validator.sh"   || fail "break-validator.sh: нет кэша вердиктов"
grep -q 'verdict_cleanup' "$REPO_DIR/lua/break-validator.sh"   || fail "break-validator.sh: нет периодической чистки кэша"
grep -q '/tmp/z2r-break-check' "$REPO_DIR/lua/break-detector.lua" || fail "break-detector.lua: нет очереди /tmp"
grep -q 'function z2r_break_note' "$REPO_DIR/lua/break-detector.lua" || fail "break-detector.lua: нет z2r_break_note"
grep -q 'function z2r_break_track' "$REPO_DIR/lua/break-detector.lua" || fail "break-detector.lua: нет z2r_break_track"
grep -q 'os.rename' "$REPO_DIR/lua/break-detector.lua" || fail "break-detector.lua: нет атомарной записи (rename)"
grep -q 'Z2R_BREAK_STATE_CAP' "$REPO_DIR/lua/break-detector.lua" || fail "break-detector.lua: нет предела памяти"

# z2r.sh: деплой модуля и демона, сервис, список, миграция.
grep -q '"lua/break-detector.lua"' "$REPO_DIR/z2r.sh" || fail "z2r.sh: break-detector.lua не скачивается"
grep -q '"lua/break-validator.sh"' "$REPO_DIR/z2r.sh" || fail "z2r.sh: break-validator.sh не скачивается"
grep -q 'break_validator_install_service' "$REPO_DIR/z2r.sh" || fail "z2r.sh: нет break_validator_install_service"
grep -q 'break_validator_remove_service' "$REPO_DIR/z2r.sh" || fail "z2r.sh: нет break_validator_remove_service"
grep -q '"lists/z2r_broken_hosts.txt"' "$REPO_DIR/z2r.sh" || fail "z2r.sh: lists/z2r_broken_hosts.txt не деплоится"
grep -q 'break-detector.lua break-validator.sh' "$REPO_DIR/z2r.sh" || fail "z2r.sh: миграция не переносит новые lua-файлы"
grep -q 'lua/break-detector.lua#/opt/zator/lua/break-detector.lua' "$REPO_DIR/z2r.sh" || fail "z2r.sh: миграция не переписывает путь break-detector"

# Сборщик релизных архивов: файлы едут, список — keep-if-exists, демоны executable.
grep -q "'lists/z2r_broken_hosts.txt'" "$REPO_DIR/webui-src/scripts/pack-zator-tar.mjs" \
  || fail "pack-zator-tar.mjs: z2r_broken_hosts.txt не в KEEP_IF_EXISTS"
grep -q "name === 'break-validator.sh'" "$REPO_DIR/webui-src/scripts/pack-zator-tar.mjs" \
  || fail "pack-zator-tar.mjs: break-validator.sh не executable"
grep -q "'Entware/z2r-break-validator'" "$REPO_DIR/webui-src/scripts/pack-zator-tar.mjs" \
  || fail "pack-zator-tar.mjs: нет payload-инита Entware/z2r-break-validator"
grep -q "'init.d/openwrt/z2r-break-validator'" "$REPO_DIR/webui-src/scripts/pack-zator-tar.mjs" \
  || fail "pack-zator-tar.mjs: нет payload-инита openwrt/z2r-break-validator"

# Иниты: очередь от nobody (nfqws2 пишет туда из Lua).
grep -q 'chown nobody' "$REPO_DIR/Entware/z2r-break-validator" || fail "Entware init: очередь не chown nobody"
grep -q 'z2r-break-check' "$REPO_DIR/init.d/openwrt/z2r-break-validator" || fail "openwrt init: нет очереди z2r-break-check"

# ---------- 2. Логика демона (мок curl, изолированные каталоги) ----------

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/curl" <<'MOCK'
#!/bin/sh
n=$(( $(cat "$BREAK_CURL_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$BREAK_CURL_COUNT"
mode="$(printf '%s\n' "$BREAK_CURL_PLAN" | cut -d' ' -f$n)"
[ -n "$mode" ] || mode=fail
case "$mode" in
  ok)  echo "403"; exit 0 ;;
  fail) echo "000"; exit 28 ;;
  dns) echo "000"; exit 6 ;;
esac
echo "000"; exit 1
MOCK
chmod +x "$TMP_DIR/bin/curl"

run_case() {
  # $1 план проб (ok|fail|dns по вызовам curl), $2 вердикт, $3 хост в exclude после (1/0)
  local plan="$1" want="$2" want_excluded="$3"
  rm -rf "$TMP_DIR/queue" "$TMP_DIR/exclude" "$TMP_DIR/logdir"
  mkdir -p "$TMP_DIR/queue" "$TMP_DIR/logdir"
  : > "$TMP_DIR/exclude"
  : > "$TMP_DIR/curlcount"
  local id="1700000001"
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "example.com" "sub.example.com" "tls" "7" \
    > "$TMP_DIR/queue/request.$id"
  BREAK_CURL_COUNT="$TMP_DIR/curlcount" BREAK_CURL_PLAN="$plan" \
  Z2R_BREAK_QUEUE="$TMP_DIR/queue" Z2R_BREAK_EXCLUDE="$TMP_DIR/exclude" \
  Z2R_BREAK_LOG="$TMP_DIR/logdir/broken.tsv" Z2R_BREAK_SETTLE=0 \
  PATH="$TMP_DIR/bin:$PATH" \
    sh "$REPO_DIR/lua/break-validator.sh" "$TMP_DIR/queue/request.$id" >/dev/null 2>&1

  local result verdict excluded
  result="$TMP_DIR/queue/result.$id"
  [ -f "$result" ] || fail "нет result-файла для плана '$plan'"
  verdict="$(cut -f2 "$result")"
  [ "$verdict" = "$want" ] || fail "план '$plan': вердикт '$verdict', ожидался '$want'"
  excluded=0
  grep -Fixq "sub.example.com" "$TMP_DIR/exclude" && excluded=1
  [ "$excluded" = "$want_excluded" ] \
    || fail "план '$plan': хост в exclude=$excluded, ожидался $want_excluded"

  # Формат result: id \t verdict \t hostkey \t strategy
  [ "$(cut -f1 "$result")" = "$id" ] || fail "result: неверный id"
  [ "$(cut -f3 "$result")" = "example.com" ] || fail "result: неверный hostkey"
  [ "$(cut -f4 "$result")" = "7" ] || fail "result: неверный strategy"

  if [ "$want" = "BROKEN" ]; then
    grep -q "sub.example.com" "$TMP_DIR/logdir/broken.tsv" || fail "BROKEN: нет записи в логе"
  fi
}

# A=ok (1 вызов), B=fail+retry-fail (2 вызова) -> обход ломает домен.
run_case "ok fail fail"  BROKEN 1
# A=fail+retry-ok -> baseline внезапно ответил: рассматриваем как ok -> обе ok.
run_case "fail ok ok"    OK_TRANSIENT 0
# A=fail,fail; B=ok -> DPI блокирует, стратегия чинит.
run_case "fail fail ok"  FIXED_BY_STRATEGY 0
# Обе фазы падают (4 вызова) -> DPI, стратегия не помогает.
run_case "fail fail fail fail" BLOCKED_NOFIX 0
# Обе фазы ок.
run_case "ok ok"         OK_TRANSIENT 0
# DNS мёртв в обеих фазах (по 1 вызову — dns не ретраится).
run_case "dns dns"       DEAD 0
# Хост уже исключён — пробы не делаются вообще.
rm -rf "$TMP_DIR/queue" "$TMP_DIR/exclude" "$TMP_DIR/logdir"
mkdir -p "$TMP_DIR/queue" "$TMP_DIR/logdir"
printf 'sub.example.com\n' > "$TMP_DIR/exclude"
: > "$TMP_DIR/curlcount"
id="1700000002"
printf '%s\t%s\t%s\t%s\t%s\n' "$id" "example.com" "sub.example.com" "tls" "7" \
  > "$TMP_DIR/queue/request.$id"
BREAK_CURL_COUNT="$TMP_DIR/curlcount" BREAK_CURL_PLAN="ok ok" \
Z2R_BREAK_QUEUE="$TMP_DIR/queue" Z2R_BREAK_EXCLUDE="$TMP_DIR/exclude" \
Z2R_BREAK_LOG="$TMP_DIR/logdir/broken.tsv" Z2R_BREAK_SETTLE=0 \
PATH="$TMP_DIR/bin:$PATH" \
  sh "$REPO_DIR/lua/break-validator.sh" "$TMP_DIR/queue/request.$id" >/dev/null 2>&1
[ -z "$(cat "$TMP_DIR/curlcount")" ] || fail "EXCLUDED: curl не должен вызываться"
[ "$(cut -f2 "$TMP_DIR/queue/result.$id")" = "EXCLUDED" ] || fail "EXCLUDED: неверный вердикт"

# ---- кэш вердиктов: пишется, чистится ----
V="$TMP_DIR/verdicts.tsv"
rm -rf "$TMP_DIR/queue" "$TMP_DIR/exclude" "$TMP_DIR/logdir"
mkdir -p "$TMP_DIR/queue" "$TMP_DIR/logdir"
: > "$TMP_DIR/exclude"
id="1700000010"
printf '%s	%s	%s	%s	%s
' "$id" "vhost.example.com" "vhost.example.com" "tls" "3"   > "$TMP_DIR/queue/request.$id"
BREAK_CURL_COUNT="$TMP_DIR/curlcount" BREAK_CURL_PLAN="ok fail fail" Z2R_BREAK_QUEUE="$TMP_DIR/queue" Z2R_BREAK_EXCLUDE="$TMP_DIR/exclude" Z2R_BREAK_LOG="$TMP_DIR/logdir/broken.tsv" Z2R_BREAK_VERDICTS="$V" Z2R_BREAK_SETTLE=0 PATH="$TMP_DIR/bin:$PATH"   sh "$REPO_DIR/lua/break-validator.sh" "$TMP_DIR/queue/request.$id" >/dev/null 2>&1 || true
[ -s "$V" ] || fail "кэш вердиктов: файл не создан"
awk -F'	' '$1=="vhost.example.com" && $2=="BROKEN" && $3+0>0 {found=1} END{exit !found}' "$V"   || fail "кэш вердиктов: нет строки host/BROKEN/ts"
# чистка: протухшая запись уходит, свежая остаётся
now="$(date +%s)"
stale=$(( now - 100000 ))
printf 'old.example.com	OK_TRANSIENT	%s
' "$stale" >> "$V"
# чистим прямым вызовом функции демона с подменёнными переменными
(
  VERDICTS_FILE="$V"
  VERDICTS_TTL=86400
  eval "$(sed -n '/^verdict_cleanup()/,/^}/p' "$REPO_DIR/lua/break-validator.sh")"
  verdict_cleanup
)
grep -q 'old.example.com' "$V" && fail "чистка: протухшая запись не удалена"
grep -q 'vhost.example.com' "$V" || fail "чистка: свежая запись удалена"

# Битый TSV (недопустимые символы в hostname) — запрос молча удаляется.
rm -rf "$TMP_DIR/queue"
mkdir -p "$TMP_DIR/queue"
id="1700000003"
printf '%s\t%s\t%s\t%s\t%s\n' "$id" "example.com" "sub;rm -rf" "tls" "7" \
  > "$TMP_DIR/queue/request.$id"
Z2R_BREAK_QUEUE="$TMP_DIR/queue" Z2R_BREAK_EXCLUDE="$TMP_DIR/exclude" \
Z2R_BREAK_LOG="$TMP_DIR/logdir/broken.tsv" Z2R_BREAK_SETTLE=0 \
PATH="$TMP_DIR/bin:$PATH" \
  sh "$REPO_DIR/lua/break-validator.sh" "$TMP_DIR/queue/request.$id" >/dev/null 2>&1 || true
[ ! -f "$TMP_DIR/queue/result.$id" ] || fail "битый TSV: не должен давать result"
[ ! -f "$TMP_DIR/queue/request.$id" ] || fail "битый TSV: request не удалён"

echo "break detect smoke ok"
