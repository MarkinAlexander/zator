#!/usr/bin/env bash

set -u

PATH="/opt/bin:/opt/sbin:$PATH"
export PATH

WEBUI_ROOT="/opt/zapret2/webui"
ZAPRET_ROOT="/opt/zapret2"
CONFIG_FILE="$ZAPRET_ROOT/config"
ORCH_DIR="$ZAPRET_ROOT/extra_strats/cache/orchestra"
LIB_DIR=""

find_runtime_libs() {
  local here dir
  here="$(cd -- "$(dirname -- "$0")" && pwd)"
  for dir in \
    "$ZAPRET_ROOT/z2r_lib" \
    "$here/../../z2r_lib" \
    "$here/../../lib" \
    "$here/../lib"; do
    if [ -f "$dir/orchestra_state.sh" ] && [ -f "$dir/config.sh" ]; then
      LIB_DIR="$dir"
      return 0
    fi
  done
  return 1
}

find_runtime_libs || { echo 'Status: 500 Internal Server Error\r'; echo; echo '{"error":"missing z2r runtime libs"}'; exit 0; }
. "$LIB_DIR/config.sh"
. "$LIB_DIR/orchestra_state.sh"
[ -f "$LIB_DIR/telemetry.sh" ] && . "$LIB_DIR/telemetry.sh"

telemetry_notify() {
  type send_stats >/dev/null 2>&1 && send_stats || true
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g; s/\n/\\n/g'
}

send_json() {
  local status="$1"
  local body="$2"
  printf 'Status: %s\r\n' "$status"
  printf 'Content-Type: application/json; charset=utf-8\r\n\r\n'
  printf '%s\n' "$body"
}

send_error() {
  local status="$1"
  local message="$2"
  send_json "$status" "{\"error\":\"$(json_escape "$message")\"}"
  exit 0
}

parse_params() {
  local raw="${QUERY_STRING:-}"
  if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
    raw="$(dd bs=1 count="${CONTENT_LENGTH:-0}" 2>/dev/null || true)"
  fi
  local part key value
  # Инициализация под set -u: все возможные PARAM_* всегда определены.
  PARAM_PROFILE=""
  PARAM_STRATEGY=""
  PARAM_ACTION=""
  PARAM_SETTING=""
  PARAM_VALUE=""
  IFS='&' read -r -a parts <<< "$raw"
  for part in "${parts[@]}"; do
    key="${part%%=*}"
    value="${part#*=}"
    value="${value//+/ }"
    printf -v value '%b' "${value//%/\\x}"
    case "$key" in
      profile) PARAM_PROFILE="$value" ;;
      strategy) PARAM_STRATEGY="$value" ;;
      action) PARAM_ACTION="$value" ;;
      setting) PARAM_SETTING="$value" ;;
      value) PARAM_VALUE="$value" ;;
    esac
  done
}

get_config_file() {
  config_get_file "$CONFIG_FILE"
}

set_zapret2_init() {
  if [ -f "$ZAPRET_ROOT/init.d/openwrt/zapret2" ]; then
    ZAPRET2_INIT="$ZAPRET_ROOT/init.d/openwrt/zapret2"
  else
    ZAPRET2_INIT="$ZAPRET_ROOT/init.d/sysv/zapret2"
  fi
}

orch_max_strategy_for_profile() {
  config_profile_max_strategy "$1" "$CONFIG_FILE"
}

profile_proto() {
  local list
  list="$(config_profile_proto_list "$1")"
  echo "${list%% *}"
}

profile_json() {
  local id="$1" label="$2" desc="$3" proto current max
  proto="$(profile_proto "$id")"
  current="$(profile_state_display "$id" "$proto")"
  max="$(orch_max_strategy_for_profile "$id")"
  printf '{"profile":%s,"label":"%s","description":"%s","current_lock":"%s","max_strategy":%s}' \
    "$id" "$(json_escape "$label")" "$(json_escape "$desc")" "$(json_escape "$current")" "${max:-0}"
}

all_profiles_json() {
  printf '['
  profile_json 1 "YouTube TCP" "Основной TCP профиль для YouTube"
  printf ','
  profile_json 2 "Googlevideo" "Видео-домены YouTube"
  printf ','
  profile_json 3 "Blocked Sites" "Основные блокировки сайтов"
  printf ','
  profile_json 4 "Discord TCP" "TCP профиль Discord"
  printf ','
  profile_json 5 "YouTube QUIC" "UDP 443 для YouTube"
  printf ','
  profile_json 6 "Voice UDP" "Discord/STUN и голосовые сервисы"
  printf ','
  profile_json_fallback 8 "Fallback TLS" "Безразборный режим TLS (profile 8)"
  printf ','
  profile_json_fallback 9 "Fallback HTTP" "Безразборный режим HTTP (profile 9)"
  printf ']'
}

profile_json_fallback() {
  local id="$1" label="$2" desc="$3" proto current max fallback_state
  proto="$(profile_proto "$id")"
  current="$(profile_state_display "$id" "$proto")"
  max="$(orch_max_strategy_for_profile "$id")"
  fallback_state="$(_fallback_state "$CONFIG_FILE")"
  printf '{"profile":%s,"label":"%s","description":"%s","current_lock":"%s","max_strategy":%s,"is_fallback":true,"fallback_enabled":%s}' \
    "$id" "$(json_escape "$label")" "$(json_escape "$desc")" "$(json_escape "$current")" "${max:-0}" \
    "$([ "$fallback_state" = "включен" ] && echo true || echo false)"
}

service_zapret2() {
  local action="$1"
  set_zapret2_init
  [ -f "$ZAPRET2_INIT" ] || return 1
  case "$action" in
    start|stop|restart)
      "$ZAPRET2_INIT" "$action" >/dev/null 2>&1
      ;;
    *)
      return 2
      ;;
  esac
}

strategy_locks_status_text() {
  if [ -s "$ORCH_DIR/locked.tsv" ] || [ -s "$ORCH_DIR/locked.manual.tsv" ] || [ -s "$(profile_state_file)" ]; then
    echo "Есть"
  else
    echo "Нет"
  fi
}

get_yt_cluster_domain() {
  local cluster_codename converted_name="" i=0 char idx b
  local letters_map_a="u z p k f a 5 0 v q l g b 6 1 w r m h c 7 2 x s n i d 8 3 y t o j e 9 4 -"
  local letters_map_b="0 1 2 3 4 5 6 7 8 9 a b c d e f g h i j k l m n o p q r s t u v w x y z -"

  cluster_codename="$(curl -s --max-time 2 "https://redirector.xn--ngstr-lra8j.com/report_mapping?di=no" | sed -n 's/.*=>[[:space:]]*\([^ (:)]*\).*/\1/p')"
  cluster_codename="$(curl -s --max-time 2 "https://redirector.xn--ngstr-lra8j.com/report_mapping?di=no" | sed -n 's/.*=>[[:space:]]*\([^ (:)]*\).*/\1/p')"
  [ -n "$cluster_codename" ] || { echo "rr1---sn-5goeenes.googlevideo.com"; return; }

  while [ $i -lt ${#cluster_codename} ]; do
    char="$(echo "$cluster_codename" | cut -c$((i+1)))"
    idx=1
    for a in $letters_map_a; do
      [ "$a" = "$char" ] && break
      idx=$((idx+1))
    done
    b="$(echo "$letters_map_b" | cut -d' ' -f "$idx")"
    converted_name="${converted_name}${b}"
    i=$((i+1))
  done
  echo "rr1---sn-${converted_name}.googlevideo.com"
}

check_one_target_json() {
  local label="$1"
  local target="$2"
  local tls12=0 tls13=0
  curl --tls-max 1.2 --max-time 1 -s -o /dev/null "$target" && tls12=1 || true
  curl --tlsv1.3 --max-time 1 -s -o /dev/null "$target" && tls13=1 || true
  printf '{"label":"%s","target":"%s","tls12":%s,"tls13":%s}' \
    "$(json_escape "$label")" "$(json_escape "$target")" "$tls12" "$tls13"
}

profile_check_json() {
  local profile="$1" gv
  case "$profile" in
    1)
      printf '{"results":[%s]}' "$(check_one_target_json "YouTube" "https://www.youtube.com/")"
      ;;
    2)
      gv="$(get_yt_cluster_domain)"
      printf '{"results":[%s]}' "$(check_one_target_json "Googlevideo" "https://${gv}")"
      ;;
    3)
      printf '{"results":[%s]}' "$(check_one_target_json "Blocked Sites" "https://meduza.io")"
      ;;
    4)
      printf '{"results":[%s]}' "$(check_one_target_json "Discord" "https://discord.com/")"
      ;;
    5|6)
      printf '{"results":[],"message":"%s"}' "$(json_escape "Для UDP-профиля быстрая TLS-проверка неприменима. Проверьте работу в браузере или приложении.")"
      ;;
    *)
      printf '{"results":[]}'
      ;;
  esac
}

api_status() {
  local running
  if zapret2_running; then running=true; else running=false; fi
  send_json "200 OK" "$(cat <<EOF
{"zapret2_running":$running,"strategy_locks_status":"$(json_escape "$(strategy_locks_status_text)")","hostlist_mode":"$(json_escape "$(config_mode_text hostlist "$CONFIG_FILE")")","fwtype":"$(json_escape "$(config_mode_text fwtype "$CONFIG_FILE")")","flowoffload":"$(json_escape "$(config_mode_text flowoffload "$CONFIG_FILE")")","tls_blob_mode":"$(json_escape "$(config_mode_text tls_blob_menu "$CONFIG_FILE")")","profiles":$(all_profiles_json)}
EOF
)"
}

api_set_lock() {
  parse_params
  [[ "${PARAM_PROFILE:-}" =~ ^[1-9]$ ]] || send_error "400 Bad Request" "Некорректный профиль"
  [[ "${PARAM_STRATEGY:-}" =~ ^[0-9]+$ ]] || send_error "400 Bad Request" "Некорректная стратегия"
  local max proto_list check_json old_udp_ports
  max="$(orch_max_strategy_for_profile "$PARAM_PROFILE")"
  if [ "${PARAM_STRATEGY}" -ne 0 ]; then
    [ "${PARAM_STRATEGY}" -ge 1 ] && [ "${PARAM_STRATEGY}" -le "${max:-0}" ] || send_error "400 Bad Request" "Стратегия вне диапазона"
  fi
  proto_list="$(config_profile_proto_list "$PARAM_PROFILE")"
  [ -n "$proto_list" ] || send_error "400 Bad Request" "Не удалось определить протокол профиля"
  old_udp_ports="$(config_get_var "$CONFIG_FILE" NFQWS2_PORTS_UDP)"
  profile_state_set_and_apply "$PARAM_PROFILE" "$proto_list" "$PARAM_STRATEGY" "$CONFIG_FILE" || send_error "500 Internal Server Error" "Не удалось сохранить состояние профиля"
  profile_config_voice_ports_changed "$PARAM_PROFILE" "$CONFIG_FILE" "$old_udp_ports" && service_zapret2 restart >/dev/null 2>&1 || true
  telemetry_notify
  check_json="$(profile_check_json "$PARAM_PROFILE")"
  send_json "200 OK" "{\"ok\":true,\"check\":$check_json}"
}

api_clear_lock() {
  parse_params
  [[ "${PARAM_PROFILE:-}" =~ ^[1-9]$ ]] || send_error "400 Bad Request" "Некорректный профиль"
  local proto_list old_udp_ports
  proto_list="$(config_profile_proto_list "$PARAM_PROFILE")"
  [ -n "$proto_list" ] || send_error "400 Bad Request" "Не удалось определить протокол профиля"
  old_udp_ports="$(config_get_var "$CONFIG_FILE" NFQWS2_PORTS_UDP)"
  profile_state_set_and_apply "$PARAM_PROFILE" "$proto_list" "auto" "$CONFIG_FILE" || send_error "500 Internal Server Error" "Не удалось сбросить состояние профиля"
  profile_config_voice_ports_changed "$PARAM_PROFILE" "$CONFIG_FILE" "$old_udp_ports" && service_zapret2 restart >/dev/null 2>&1 || true
  telemetry_notify
  send_json "200 OK" "{\"ok\":true}"
}

api_service() {
  parse_params
  case "${PARAM_ACTION:-}" in
    start|stop|restart) ;;
    *) send_error "400 Bad Request" "Некорректное действие" ;;
  esac
  service_zapret2 "$PARAM_ACTION" || send_error "500 Internal Server Error" "Не удалось выполнить команду zapret2"
  send_json "200 OK" "{\"ok\":true}"
}

api_check() {
  local gv
  gv="$(get_yt_cluster_domain)"
  send_json "200 OK" "{\"results\":[
$(check_one_target_json "YouTube" "https://www.youtube.com/")
,$(check_one_target_json "Googlevideo" "https://${gv}")
,$(check_one_target_json "Blocked Sites" "https://meduza.io")
,$(check_one_target_json "Instagram" "https://www.instagram.com/")
]}"
}

api_tls_blob_get() {
  local cfg="/opt/zapret2/config"
  local fake_dir="/opt/zapret2/files/fake"
  local current_blob current_mode available_blobs

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"
  [ -d "$fake_dir" ] || send_error "500 Internal Server Error" "Директория fake не найдена"

  current_blob="$(sed -n -E 's#.*--blob=maxru:@/opt/zapret2/files/fake/([^[:space:]]+).*#\1#p' "$cfg" | head -n1)"
  [ -z "$current_blob" ] && current_blob=""
  current_mode="$(config_tls_blob_mode_value "$cfg")"

  available_blobs=""
  if sort -z </dev/null >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      f="$(basename "$f")"
      case "$f" in
        tls_*.bin|custom_tls.bin)
          available_blobs="${available_blobs}${available_blobs:+,}\"$(json_escape "$f")\""
          ;;
      esac
    done < <(find "$fake_dir" -maxdepth 1 -type f -name '*.bin' -print0 | sort -z)
  else
    while IFS= read -r f; do
      f="$(basename "$f")"
      case "$f" in
        tls_*.bin|custom_tls.bin)
          available_blobs="${available_blobs}${available_blobs:+,}\"$(json_escape "$f")\""
          ;;
      esac
    done < <(find "$fake_dir" -maxdepth 1 -type f -name '*.bin' | sort)
  fi

  send_json "200 OK" "{
    \"current_mode\":\"$(json_escape "$current_mode")\",
    \"current_blob\":\"$(json_escape "$current_blob")\",
    \"available_blobs\":[$available_blobs]
  }"
}

api_tls_blob_set() {
  local blob="$PARAM_VALUE"
  local cfg="/opt/zapret2/config"
  local fake_dir="/opt/zapret2/files/fake"
  local sed_ereg prefix

  case "$blob" in
    fake_default_tls)
      ;;
    tls_*.bin|custom_tls.bin)
      [ -f "$fake_dir/$blob" ] || send_error "400 Bad Request" "Файл блоба не существует: $blob"
      ;;
    *)
      send_error "400 Bad Request" "Некорректное значение блоба: $blob"
      ;;
  esac

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  sed_ereg="$(config_sed_ereg)"
  prefix="--blob=maxru:@/opt/zapret2/files/fake/"

  if ! grep -q -- "--blob=maxru:@/opt/zapret2/files/fake/" "$cfg"; then
    send_error "500 Internal Server Error" "Строка --blob=maxru не найдена в конфиге"
  fi

  if [ "$blob" = "fake_default_tls" ]; then
    sed -i $sed_ereg '/--lua-desync=/ { /strategy=26/! s#(--lua-desync=[^[:space:]]*blob=)maxru#\1fake_default_tls#g; }' "$cfg"
  else
    sed -i $sed_ereg '/--lua-desync=/ { /strategy=26/! s#(--lua-desync=[^[:space:]]*blob=)fake_default_tls#\1maxru#g; }' "$cfg"
    sed -i $sed_ereg "s#(${prefix})[^[:space:]]+#\\1${blob}#g" "$cfg"
  fi

  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true}"
}

api_wg_blob_get() {
  local cfg="/opt/zapret2/config"
  local fake_dir="/opt/zapret2/files/fake"
  local current_blob current_repeats available_blobs

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"
  [ -d "$fake_dir" ] || send_error "500 Internal Server Error" "Директория fake не найдена"

  current_blob="$(sed -n -E 's#.*--blob=fakewgblob:@/opt/zapret2/files/fake/([^[:space:]]+).*#\1#p' "$cfg" | head -n1)"
  [ -z "$current_blob" ] && current_blob=""
  current_repeats="$(sed -n -E 's#.*blob=fakewgblob:repeats=([0-9]+).*#\1#p' "$cfg" | head -n1)"
  [ -z "$current_repeats" ] && current_repeats=""

  # Только файлы вида wg_initial_fake_* (как в menu_action_set_wg_blob)
  available_blobs=""
  if sort -z </dev/null >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      f="$(basename "$f")"
      available_blobs="${available_blobs}${available_blobs:+,}\"$(json_escape "$f")\""
    done < <(find "$fake_dir" -maxdepth 1 -type f -name 'wg_initial_fake_*' -print0 | sort -z)
  else
    while IFS= read -r f; do
      f="$(basename "$f")"
      available_blobs="${available_blobs}${available_blobs:+,}\"$(json_escape "$f")\""
    done < <(find "$fake_dir" -maxdepth 1 -type f -name 'wg_initial_fake_*' | sort)
  fi

  send_json "200 OK" "{
    \"current_blob\":\"$(json_escape "$current_blob")\",
    \"current_repeats\":\"$(json_escape "$current_repeats")\",
    \"available_blobs\":[$available_blobs]
  }"
}

api_wg_blob_set() {
  local blob="$PARAM_VALUE"
  local cfg="/opt/zapret2/config"
  local fake_dir="/opt/zapret2/files/fake"
  local sed_ereg prefix

  # Валидация имени файла: только wg_initial_fake_* (как в CLI)
  case "$blob" in
    wg_initial_fake_*)
      [ -f "$fake_dir/$blob" ] || send_error "400 Bad Request" "Файл блоба не существует: $blob"
      ;;
    *)
      send_error "400 Bad Request" "Некорректное значение блоба: $blob"
      ;;
  esac

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  sed_ereg="$(config_sed_ereg)"
  prefix="--blob=fakewgblob:@/opt/zapret2/files/fake/"

  if ! grep -q -- "--blob=fakewgblob:@/opt/zapret2/files/fake/" "$cfg"; then
    send_error "500 Internal Server Error" "Стратегия WireGuard не найдена в конфиге (нет --blob=fakewgblob:@...)"
  fi

  sed -i $sed_ereg "s#(${prefix})[^[:space:]]+#\\1${blob}#g" "$cfg"

  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true}"
}

_fallback_current_strategy() {
  local profile="$1"
  local cfg="$2"
  local begin_marker end_marker
  if [ "$profile" = "9" ]; then
    begin_marker="#Z2R_FALLBACK_HTTP_BEGIN"
    end_marker="#Z2R_FALLBACK_HTTP_END"
  else
    begin_marker="#Z2R_FALLBACK_BEGIN"
    end_marker="#Z2R_FALLBACK_END"
  fi
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 ~ "^[[:space:]]*" begin "$" {inblk=1; next}
    $0 ~ "^[[:space:]]*" end "$" {inblk=0; exit}
    inblk && $0 ~ /^--filter-tcp=/ {
      n++
      if ($0 ~ /^--skip[[:space:]]/) next
      if ($0 ~ /--hostlist-domains= --/ || $0 ~ /--hostlist-domains=$/) {print n; found=1; exit}
    }
    END{if (!found) print 0}
  ' "$cfg"
}

_fallback_set_strategy() {
  local profile="$1"
  local strategy="$2"
  local cfg="$3"
  local begin_marker end_marker filter_pattern
  if [ "$profile" = "9" ]; then
    begin_marker="#Z2R_FALLBACK_HTTP_BEGIN"
    end_marker="#Z2R_FALLBACK_HTTP_END"
    filter_pattern="--filter-tcp=80 --filter-l7=http"
  else
    begin_marker="#Z2R_FALLBACK_BEGIN"
    end_marker="#Z2R_FALLBACK_END"
    filter_pattern="--filter-tcp=443 --filter-l7=tls"
  fi
  awk -v begin="$begin_marker" -v end="$end_marker" -v target="$strategy" -v fpattern="$filter_pattern" '
    $0 ~ "^[[:space:]]*" begin "$" {inblk=1; print; next}
    $0 ~ "^[[:space:]]*" end "$" {inblk=0; print; next}
    inblk && $0 ~ "^--filter-tcp=" {
      count++
      # Убираем --skip если есть
      sub(/^[[:space:]]*--skip[[:space:]]+/, "")
      # Сбрасываем все строки на none.dom
      sub(/--hostlist-domains= --/, "--hostlist-domains=none.dom --")
      sub(/--hostlist-domains=$/, "--hostlist-domains=none.dom")
      # Если это целевая стратегия и target > 0 — активируем
      if (target > 0 && count == target) {
        sub(/--hostlist-domains=none\.dom --/, "--hostlist-domains= --")
        sub(/--hostlist-domains=none\.dom$/, "--hostlist-domains=")
        changed=1
      }
      # Если target == 0 — добавляем --skip ко всем строкам
      if (target == 0) {
        $0 = "--skip " $0
      }
    }
    {print}
    END{exit((target==0 || changed)?0:1)}
  ' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
}

_fallback_state() {
  local cfg="$1"
  if { sed -n '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/p' "$cfg"; sed -n '/#Z2R_FALLBACK_HTTP_BEGIN/,/#Z2R_FALLBACK_HTTP_END/p' "$cfg"; } | grep -q '^[[:space:]]*--skip[[:space:]]'; then
    echo "выключен"
  else
    echo "включен"
  fi
}

_fallback_set_state() {
  local cfg="$1"
  local want_on="$2"
  if [ "$want_on" = "1" ]; then
    sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^[[:space:]]*--skip[[:space:]]\+//' "$cfg"
    sed -i '/#Z2R_FALLBACK_HTTP_BEGIN/,/#Z2R_FALLBACK_HTTP_END/ s/^[[:space:]]*--skip[[:space:]]\+//' "$cfg"
  else
    sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^[[:space:]]*--filter-tcp=443 --filter-l7=tls/--skip --filter-tcp=443 --filter-l7=tls/' "$cfg"
    sed -i '/#Z2R_FALLBACK_BEGIN/,/#Z2R_FALLBACK_END/ s/^[[:space:]]*--filter-tcp=443$/--skip --filter-tcp=443/' "$cfg"
    sed -i '/#Z2R_FALLBACK_HTTP_BEGIN/,/#Z2R_FALLBACK_HTTP_END/ s/^[[:space:]]*--filter-tcp=80 --filter-l7=http/--skip --filter-tcp=80 --filter-l7=http/' "$cfg"
  fi
}

api_fallback_get() {
  local cfg="/opt/zapret2/config"
  local state tls_strat http_strat tls_max http_max

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  state="$(_fallback_state "$cfg")"
  tls_strat="$(profile_state_display 8 tls)"
  http_strat="$(profile_state_display 9 http)"
  tls_max="$(config_profile_max_strategy 8 "$cfg")"
  http_max="$(config_profile_max_strategy 9 "$cfg")"

  send_json "200 OK" "{
    \"state\":\"$(json_escape "$state")\",
    \"tls_strategy\":\"$(json_escape "$tls_strat")\",
    \"http_strategy\":\"$(json_escape "$http_strat")\",
    \"tls_max\":${tls_max:-0},
    \"http_max\":${http_max:-0}
  }"
}

api_fallback_state_set() {
  local value="$PARAM_VALUE"
  local cfg="/opt/zapret2/config"

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  case "$value" in
    0|1) ;;
    *) send_error "400 Bad Request" "Некорректное значение: $value" ;;
  esac

  _fallback_set_state "$cfg" "$value"
  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true}"
}

api_fallback_strategy_set() {
  local profile="$1"
  local strategy="$2"
  local cfg="/opt/zapret2/config"
  local max proto_list

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  case "$profile" in
    8|9) ;;
    *) send_error "400 Bad Request" "Некорректный профиль: $profile" ;;
  esac

  case "$strategy" in
    ''|*[!0-9]*) send_error "400 Bad Request" "Некорректная стратегия: $strategy" ;;
  esac

  max="$(config_profile_max_strategy "$profile" "$cfg")"
  if [ "$strategy" -ne 0 ] && [ "$strategy" -gt "${max:-0}" ]; then
    send_error "400 Bad Request" "Стратегия вне диапазона (макс: $max)"
  fi

  proto_list="$(config_profile_proto_list "$profile")"
  [ -n "$proto_list" ] || send_error "400 Bad Request" "Не удалось определить протокол профиля"
  profile_state_set_and_apply "$profile" "$proto_list" "$strategy" "$cfg" ||
    send_error "500 Internal Server Error" "Не удалось сохранить стратегию"
  telemetry_notify

  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true}"
}

api_wg_repeats_set() {
  local repeats="$PARAM_VALUE"
  local cfg="/opt/zapret2/config"
  local sed_ereg

  [ -f "$cfg" ] || send_error "500 Internal Server Error" "Config не найден"

  case "$repeats" in
    ''|*[!0-9]*)
      send_error "400 Bad Request" "Некорректное значение repeats: $repeats"
      ;;
  esac
  [ "$repeats" -ge 2 ] 2>/dev/null && [ "$repeats" -le 99 ] 2>/dev/null ||
    send_error "400 Bad Request" "Значение repeats должно быть от 2 до 99"

  if ! grep -q 'blob=fakewgblob:repeats=' "$cfg"; then
    send_error "500 Internal Server Error" "Стратегия WireGuard не найдена в конфиге (нет blob=fakewgblob:repeats=)"
  fi

  sed_ereg="$(config_sed_ereg)"
  sed -i $sed_ereg "s#(blob=fakewgblob:repeats=)[0-9]+#\\1${repeats}#g" "$cfg"

  send_json "200 OK" "{\"ok\":true,\"reboot_required\":true}"
}
