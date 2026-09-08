#!/usr/bin/env bash
#
# Smoke-тест tar-развёртывания zator: сборщик pack-zator-tar.mjs и функции
# lib/deploy.sh (deploy_from_tar, защиты keep-if-exists, выбор режима
# staging A/B/C, слияние version.env, целостность, сброс к эталону).
#
# Покрывает:
#   1. bash -n lib/deploy.sh; статический wiring: z2r.sh source-ит deploy.sh,
#      п.5 ведёт в deploy_update_menu с деградацией, Enter-подсказка обновлена.
#   2. Сборщик (node): три варианта одним прогоном, latest.json со схемой и
#      размерами, version.env/manifest.tsv внутри архива, sha256sum -c.
#   3. deploy_from_tar из локального full-архива (режим A): файлы установлены,
#      _root/z2r.sh и _payload разложены, symlink webui/www/cgi-bin.
#   4. Защиты: существующие netrogat.txt/TCP_Custom.txt не перезаписаны,
#      autohostlist.txt и runtime-файлы cache/ не тронуты.
#   5. Обновление поверх установки (webui-вариантом): version.env слит —
#      ZATOR_* от прежней сборки, WEBUI_* от новой.
#   6. Режим C (мок df со тесным /tmp): перестановка каталогов, runtime
#      перенесён, пользовательский netrogat.txt сохранён.
#   7. deploy_integrity_check после деплоя — все файлы совпадают.
#   8. deploy_reset_user_files: изменённый TCP_Custom.txt возвращается к
#      эталону через stdin-ответ.
#   9. --version попадает в version.env/latest.json (номер релиза).
#
# ИЗОЛЯЦИЯ: всё во временной папке /tmp (trap EXIT); ZATOR_ROOT,
# Z2R_SCRIPT_DEST переопределяются ДО source lib/deploy.sh; deploy_dest_for
# перегоняет канонические /opt/... из манифеста в тестовые пути.
#
# Возврат: 0 — успех («deploy tar smoke ok»), 1 — ошибка.
# Запуск: bash tests/deploy_tar_smoke.sh
# Требует: bash, node, tar, gzip, sha256sum, df, awk.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PASS=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() {
  PASS=$((PASS + 1))
  echo "ok $PASS: $*"
}

command -v sha256sum >/dev/null 2>&1 || fail "sha256sum не найден"

# SMOKE_DIST: каталог с готовыми zator-{core,webui,full}.tar.gz (+.sha256,
# +.manifest.tsv) — сборка пропускается, node не нужен (запуск на роутере).
WORK="$(mktemp -d /tmp/z2r_deploy_smoke.XXXXXX)" || fail "mktemp"
trap 'rm -rf "$WORK"' EXIT
export ZATOR_ROOT="$WORK/zator"
export Z2R_SCRIPT_DEST="$WORK/z2r.sh"
if [ -n "${SMOKE_DIST:-}" ]; then
  DIST="$SMOKE_DIST"
else
  DIST="$WORK/dist"
fi

# MSYS/Windows разворачивает симлинки из tar копиями — полноценную проверку
# линков делаем только на Linux, на MSYS достаточно существования пути.
check_symlink() {
  [ -L "$1" ] && return 0
  command -v cygpath >/dev/null 2>&1 && [ -e "$1" ] && return 0
  return 1
}

# --- 1. статика ---

bash -n "$REPO_DIR/lib/deploy.sh" || fail "bash -n lib/deploy.sh"
bash -n "$REPO_DIR/z2r.sh" || fail "bash -n z2r.sh"
grep -q 'source "$LIB_DIR/deploy.sh"' "$REPO_DIR/z2r.sh" || fail "z2r.sh не source-ит deploy.sh"
grep -q 'deploy_update_menu' "$REPO_DIR/z2r.sh" || fail "п.5 не ведёт в deploy_update_menu"
grep -q 'Enter (без цифр)' "$REPO_DIR/z2r.sh" && fail "Enter-подсказка не убрана: Enter должен ничего не делать"
grep -q 'DEPLOY_WANT_REINSTALL' "$REPO_DIR/z2r.sh" || fail "п.5 не запускает переустановку zapret2"
grep -q 'DEPLOY_PAYLOAD_DIR' "$REPO_DIR/z2r.sh" || fail "z2r_download_project_file без payload-источника"
ok "статика z2r.sh"

# --- 2. сборка (пропускается при SMOKE_DIST) ---

if [ -n "${SMOKE_DIST:-}" ]; then
  for v in core webui full; do
    [ -f "$DIST/zator-$v.tar.gz" ] || fail "SMOKE_DIST: нет zator-$v.tar.gz"
  done
  ok "готовые архивы из SMOKE_DIST"
else
  # node под MSYS понимает только нативные пути: /tmp/... превращается в корень диска
  DIST_OUT="$DIST"
if command -v cygpath >/dev/null 2>&1; then
  DIST_OUT="$(cygpath -w "$DIST")"
fi
(cd "$REPO_DIR/webui-src" && node scripts/pack-zator-tar.mjs --version=deploy-smoke-1010 --out "$DIST_OUT") >/dev/null \
  || fail "сборщик упал"
for v in core webui full; do
  [ -f "$DIST/zator-$v.tar.gz" ] || fail "нет zator-$v.tar.gz"
  (cd "$DIST" && sha256sum -c "zator-$v.sha256") >/dev/null 2>&1 || fail "sha256 не сходится: $v"
  [ -f "$DIST/zator-$v.manifest.tsv" ] || fail "нет manifest.tsv: $v"
done
grep -q '"release": "deploy-smoke-1010"' "$DIST/latest.json" || fail "latest.json без номера версии"
grep -q '"unpackedSize"' "$DIST/latest.json" || fail "latest.json без unpackedSize"
node -e '
  const m = require(process.argv[1]);
  if (m.schemaVersion !== 1) process.exit(1);
  for (const v of ["core", "webui", "full"]) {
    const a = m.assets[v];
    if (!a || !a.size || !a.sha256 || !a.unpackedSize) process.exit(1);
  }
' "$DIST/latest.json" 2>/dev/null || fail "схема latest.json неполная"
ok "сборщик: 3 варианта, latest.json, sha256"
fi

STAGE="$WORK/unpack"
mkdir -p "$STAGE"
tar -xzf "$DIST/zator-full.tar.gz" -C "$STAGE" || fail "распаковка full"
grep -q '^ZATOR_VERSION="deploy-' "$STAGE/extra_strats/cache/deploy/version.env" || fail "version.env без версии"
grep -q 'TRACKING="latest"' "$STAGE/extra_strats/cache/deploy/version.env" || fail "version.env без TRACKING"
head -1 "$STAGE/extra_strats/cache/deploy/manifest.tsv" | grep -q '^# path|dest|class|sha256|size|exec$' || fail "заголовок manifest.tsv"
grep -q '^_root/z2r.sh|/opt/z2r.sh|auto|' "$STAGE/extra_strats/cache/deploy/manifest.tsv" || fail "manifest без _root/z2r.sh"
grep -q '^_payload/config.default|/opt/zator/.deploy-payload/config.default|payload|' "$STAGE/extra_strats/cache/deploy/manifest.tsv" || fail "manifest без payload"
grep -q '^lists/netrogat.txt|.*|keep-if-exists|' "$STAGE/extra_strats/cache/deploy/manifest.tsv" || fail "manifest без keep-if-exists у netrogat"
check_symlink "$STAGE/webui/www/cgi-bin" || fail "нет symlink webui/www/cgi-bin"
grep -q $'\r' "$STAGE/lists/netrogat.txt" 2>/dev/null && fail "CRLF в netrogat.txt"
expected_ver="$(sed -n 's/^ZATOR_VERSION="\(.*\)"$/\1/p' "$STAGE/extra_strats/cache/deploy/version.env")"
ok "архив: version.env, manifest.tsv, symlink, LF"

# --- 3-4. deploy_from_tar, режим A, защиты ---

# предустановка «старого» пользователя: изменённые netrogat.txt и TCP_Custom,
# runtime-состояние, которого нет в архиве
mkdir -p "$ZATOR_ROOT/lists" "$ZATOR_ROOT/extra_strats" "$ZATOR_ROOT/extra_strats/cache/orchestra" "$ZATOR_ROOT/webui/run"
printf 'user-domain.example\n' > "$ZATOR_ROOT/lists/netrogat.txt"
printf 'custom.example\n' > "$ZATOR_ROOT/extra_strats/TCP_Custom.txt"
printf 'autohost-runtime\n' > "$ZATOR_ROOT/lists/autohostlist.txt"
printf 'lock-runtime\n' > "$ZATOR_ROOT/extra_strats/cache/orchestra/locked.tsv"
printf 'pid\n' > "$ZATOR_ROOT/webui/run/webui.pid"

source "$REPO_DIR/lib/deploy.sh"

# изоляция zapret2-корня для deploy_apply_config_default (эталон config.default)
export ZAPRET2_ROOT="$WORK/zapret2"

# регрессия коллизии имён: контентный webuiSha из latest.json не должен
# затираться sha256 ассета (цикл по вариантам в deploy_fetch_release_meta)
SMOKE_JSON_SRC="$DIST/latest.json"
z2r_fetch_url_to_file() { cp "$SMOKE_JSON_SRC" "$1"; }
deploy_fetch_release_meta latest
exp_webui_sha="$(grep '"webuiSha":' "$SMOKE_JSON_SRC" | head -n1 | sed 's/.*: *"//; s/".*//')"
[ -n "$exp_webui_sha" ] || fail "latest.json без webuiSha"
[ "$DEPLOY_META_WEBUI_SHA" = "$exp_webui_sha" ] || fail "DEPLOY_META_WEBUI_SHA не контентный webuiSha (коллизия с ассетом)"
[ -n "$DEPLOY_META_ASSET_WEBUI_SHA" ] || fail "DEPLOY_META_ASSET_WEBUI_SHA пуст"
[ "$DEPLOY_META_ASSET_WEBUI_SHA" != "$exp_webui_sha" ] || fail "тест не различает контентный и ассетный sha"
ok "deploy_fetch_release_meta: контентный и ассетный sha разделены"

# регрессия set -e: deploy_menu_header с отсутствующими version.env/latest.env
# не должен ронять вызывающий скрипт; без установленной панели шапка не должна
# упоминать Web-панель (поля WEBUI_* есть даже в core-сборке)
rm -rf "$WORK/empty-zator"
mkdir -p "$WORK/empty-zator"
( cd "$REPO_DIR" && ZATOR_ROOT="$WORK/empty-zator" bash -c 'set -e; source lib/deploy.sh >/dev/null 2>&1; deploy_menu_header; echo SURVIVED; echo "PART=[$MENU_WEBUI_PART]"' ) > "$WORK/hdr.out" 2>&1
grep -q SURVIVED "$WORK/hdr.out" || fail "deploy_menu_header роняет set -e при пустом окружении"
grep -q 'PART=\[\]' "$WORK/hdr.out" || fail "шапка пишет про Web-панель без установленной панели"
ok "deploy_menu_header безопасен под set -e и молчит про отсутствующую панель"

deploy_from_tar "$DIST/zator-full.tar.gz" >/dev/null 2>&1 || fail "deploy_from_tar (A) упал"
[ -f "$ZATOR_ROOT/z2r_lib/config.sh" ] || fail "z2r_lib не установлен"
[ -f "$Z2R_SCRIPT_DEST" ] || fail "_root/z2r.sh не установлен в Z2R_SCRIPT_DEST"
[ -f "$ZATOR_ROOT/.deploy-payload/config.default" ] || fail "payload config.default не разложен"
[ -f "$ZATOR_ROOT/.deploy-payload/Entware/keenetic-policy.sh" ] || fail "payload keenetic-policy.sh не разложен"
# payload config.default применяется к эталону в корне zapret2
# (живой config в standalone-контексте смоука отсутствует)
[ -f "$ZAPRET2_ROOT/config.default" ] || fail "payload config.default не скопирован в эталон zapret2"
cmp -s "$ZAPRET2_ROOT/config.default" "$ZATOR_ROOT/.deploy-payload/config.default" \
  || fail "эталон config.default отличается от payload"
[ -x "$ZATOR_ROOT/webui/run-webui.sh" ] || fail "run-webui.sh не исполняемый"
check_symlink "$ZATOR_ROOT/webui/www/cgi-bin" || fail "symlink cgi-bin не создан"
ok "deploy_from_tar A: файлы, payload, z2r.sh, symlink"

grep -q 'user-domain.example' "$ZATOR_ROOT/lists/netrogat.txt" || fail "netrogat.txt перезаписан"
grep -q 'custom.example' "$ZATOR_ROOT/extra_strats/TCP_Custom.txt" || fail "TCP_Custom.txt перезаписан"
grep -q 'autohost-runtime' "$ZATOR_ROOT/lists/autohostlist.txt" || fail "autohostlist.txt тронут"
grep -q 'lock-runtime' "$ZATOR_ROOT/extra_strats/cache/orchestra/locked.tsv" || fail "locked.tsv тронут"
grep -q 'pid' "$ZATOR_ROOT/webui/run/webui.pid" || fail "webui/run тронут"
ok "защиты keep-if-exists и runtime"

# --- 4b. payload config.default применяется к живому конфигу ---
# мокаем окружение меню: живой config есть, функции применителя доступны;
# проверяем связку stop -> apply -> restart внутри deploy_from_tar
mkdir -p "$ZAPRET2_ROOT"
printf 'LIVE-CONFIG\n' > "$ZAPRET2_ROOT/config"
APPLY_MARK="$WORK/apply.mark" RESTART_MARK="$WORK/restart.mark"
export APPLY_MARK RESTART_MARK
config_apply_from_default() { echo applied >> "$APPLY_MARK"; }
z2r_service_action() { echo "$1" >> "$RESTART_MARK"; }
backup_helper_ask_and_create() { BACKUP_HELPER_CREATED=0; return 0; }
deploy_from_tar "$DIST/zator-full.tar.gz" >/dev/null 2>&1 || fail "deploy_from_tar (apply) упал"
[ -s "$APPLY_MARK" ] || fail "config_apply_from_default не вызван при живом config"
grep -q '^stop$' "$RESTART_MARK" || fail "нет stop перед применением config.default"
grep -q '^restart$' "$RESTART_MARK" || fail "нет restart после применения config.default"
ok "payload config.default применяется к живому конфигу (stop -> apply -> restart)"
unset -f config_apply_from_default z2r_service_action backup_helper_ask_and_create

# --- 5. обновление webui-вариантом: слияние version.env ---

# подменяем даты в текущем version.env, чтобы увидеть слияние полей
sed -i 's/^ZATOR_DATE=.*/ZATOR_DATE="2000-01-01 00:00"/' "$ZATOR_ROOT/extra_strats/cache/deploy/version.env"
deploy_from_tar "$DIST/zator-webui.tar.gz" >/dev/null 2>&1 || fail "deploy_from_tar (webui) упал"
grep -q '^ZATOR_DATE="2000-01-01 00:00"$' "$ZATOR_ROOT/extra_strats/cache/deploy/version.env" || fail "webui-деплой затёр ZATOR_*"
grep -q "^WEBUI_VERSION=\"$expected_ver\"$" "$ZATOR_ROOT/extra_strats/cache/deploy/version.env" || fail "webui-деплой не обновил WEBUI_*"
[ -f "$ZATOR_ROOT/extra_strats/cache/deploy/manifest.webui.tsv" ] || fail "нет manifest.webui.tsv"
[ -f "$ZATOR_ROOT/extra_strats/cache/deploy/manifest.core.tsv" ] || fail "нет manifest.core.tsv"
grep -q '^webui/' "$ZATOR_ROOT/extra_strats/cache/deploy/manifest.webui.tsv" || fail "manifest.webui без webui-строк"
! grep -q '^webui/' "$ZATOR_ROOT/extra_strats/cache/deploy/manifest.core.tsv" || fail "manifest.core содержит webui-строки"
ok "слияние version.env по компонентам, манифесты по компонентам"

# --- 6. режим C: тесный /tmp, перестановка каталогов ---

# мок df с параметрами: TMP_FREE_KB/OPT_FREE_KB (по умолчанию тесный /tmp)
mkdir -p "$WORK/bin"
cat > "$WORK/bin/df" <<'EOF'
#!/bin/sh
hdr="Filesystem 1024-blocks Used Available Capacity Mounted"
case " $* " in
  *" /tmp "*) echo "$hdr"; echo "/dev/tmp 1000 900 ${TMP_FREE_KB:-100} 90% /tmp" ;;
  *) echo "$hdr"; echo "/dev/opt 1000000 900000 ${OPT_FREE_KB:-100000} 10% /opt" ;;
esac
EOF
chmod +x "$WORK/bin/df"

# A: просторный /tmp; C: /tmp тесный, /opt хватает на базу, но не на staging с архивом
DEPLOY_MODE=""
TMP_FREE_KB=100000 OPT_FREE_KB=100000 PATH="$WORK/bin:$PATH" deploy_space_mode_select 5000 3000 >/dev/null 2>&1 \
  && [ "$DEPLOY_MODE" = "A" ] || fail "режим не A при просторном /tmp ($DEPLOY_MODE)"
DEPLOY_MODE=""
TMP_FREE_KB=100 OPT_FREE_KB=13000 PATH="$WORK/bin:$PATH" deploy_space_mode_select 900 3000 >/dev/null 2>&1 \
  || fail "space_select упал на тесном /tmp"
[ "$DEPLOY_MODE" = "C" ] || fail "режим не C при тесном /tmp (получили $DEPLOY_MODE)"
DEPLOY_MODE=""
TMP_FREE_KB=100 OPT_FREE_KB=100000 PATH="$WORK/bin:$PATH" deploy_space_mode_select 900 3000 >/dev/null 2>&1 \
  && [ "$DEPLOY_MODE" = "B" ] || fail "режим не B при тесном /tmp и просторном /opt ($DEPLOY_MODE)"
ok "выбор режима A/B/C по df"

printf 'user-domain-2.example\n' > "$ZATOR_ROOT/lists/netrogat.txt"
TMP_FREE_KB=100 OPT_FREE_KB=13000 PATH="$WORK/bin:$PATH" deploy_from_tar "$DIST/zator-full.tar.gz" >/dev/null 2>&1 \
  || fail "deploy_from_tar (C) упал"
[ -f "$ZATOR_ROOT/z2r_lib/config.sh" ] || fail "режим C: z2r_lib не на месте"
[ ! -d "$ZATOR_ROOT.old.$$" ] || fail "старый каталог не убран"
[ ! -d "$ZATOR_ROOT.deploy.new.$$" ] || fail "новый каталог не перенесён"
grep -q 'user-domain-2.example' "$ZATOR_ROOT/lists/netrogat.txt" || fail "режим C: netrogat.txt перезаписан"
grep -q 'lock-runtime' "$ZATOR_ROOT/extra_strats/cache/orchestra/locked.tsv" || fail "режим C: locked.tsv не перенесён"
grep -q 'autohost-runtime' "$ZATOR_ROOT/lists/autohostlist.txt" || fail "режим C: autohostlist не перенесён"
ok "режим C: перестановка каталогов, переносы runtime и защит"

# --- 7. целостность ---

integrity_out="$(deploy_integrity_check 2>/dev/null)" || fail "integrity_check упал"
printf '%s\n' "$integrity_out" | grep -q 'отсутствует: ' && fail "integrity_check: есть отсутствующие файлы ($integrity_out)"
printf 'tampered\n' >> "$ZATOR_ROOT/lua/dns-clone.lua"
integrity_out="$(deploy_integrity_check 2>/dev/null)" || fail "integrity_check упал после изменения"
printf '%s\n' "$integrity_out" | grep -q 'lua/dns-clone.lua' || fail "integrity_check не заметил изменение"
ok "integrity_check замечает изменения"

# --- 8. сброс к эталону ---

# сначала получаем список изменённых (ответ 0 = отмена), выбираем номер TCP_Custom.txt
reset_list="$(deploy_reset_user_files "$DIST/zator-full.tar.gz" <<< "0" 2>/dev/null)" || fail "reset_user_files (список) упал"
custom_num="$(printf '%s\n' "$reset_list" | sed -n 's/^\([0-9]*\)\. extra_strats\/TCP_Custom.txt$/\1/p' | head -1)"
[ -n "$custom_num" ] || fail "TCP_Custom.txt не попал в список изменённых"

deploy_reset_user_files "$DIST/zator-full.tar.gz" <<< "all" >/dev/null 2>&1 || fail "reset_user_files (all) упал"
grep -q 'custom.example' "$ZATOR_ROOT/extra_strats/TCP_Custom.txt" && fail "TCP_Custom не сброшен к эталону (all)"
grep -q 'user-domain-2.example' "$ZATOR_ROOT/lists/netrogat.txt" && fail "netrogat не сброшен к эталону (all)"

printf 'user-domain-3.example\n' > "$ZATOR_ROOT/lists/netrogat.txt"
printf 'custom-2.example\n' > "$ZATOR_ROOT/extra_strats/TCP_Custom.txt"
deploy_reset_user_files "$DIST/zator-full.tar.gz" <<< "$custom_num" >/dev/null 2>&1 || fail "reset_user_files (выборочный) упал"
grep -q 'user-domain-3.example' "$ZATOR_ROOT/lists/netrogat.txt" || fail "выборочный reset тронул не выбранный файл"
grep -q 'custom-2.example' "$ZATOR_ROOT/extra_strats/TCP_Custom.txt" && fail "выбранный файл не сброшен"
ok "reset_user_files: all и выборочный"

echo
echo "deploy tar smoke ok"
