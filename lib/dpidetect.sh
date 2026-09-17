#!/bin/sh
# lib/dpidetect.sh — дифференциальная диагностика «кто сломал домен».
#
# Отвечает на главный вопрос: домен блокируется DPI (и обход его чинит)
# или обход сам ломает домен (без zapret2 он работает).
#
# Метод: две серии TLS-проб одним движком z2r_tls_* (lib/netcheck.sh) —
#   1) базлайн: временный лок 0 (locked.lua отдаёт VERDICT_PASS — трафик
#      ключа идёт без дезинка);
#   2) кандидат: лок N (обычно текущая или лучшая стратегия).
# Локи — это запись строки в locked.tsv (в рамках ORCH_ACTIVE_SCOPE):
# nfqws2 подхватывает их на лету за cache_ttl=2с (orchestra/locked.lua),
# рестарт не нужен. Прежний лок восстанавливается при любом исходе,
# включая Ctrl+C.
#
# Интерпретация (grade: ok=2, warn=1, fail=0):
#   базлайн fail, стратегия ok    -> blocked_fixed       (DPI блокирует, стратегия чинит)
#   базлайн fail, стратегия warn  -> blocked_improved    (DPI блокирует, помогает частично)
#   базлайн fail, стратегия fail  -> blocked_nofix       (DPI блокирует, стратегия не помогает)
#   базлайн ok,   стратегия ok    -> not_blocked         (не блокируется, обход не нужен)
#   базлайн ok,   стратегия хуже  -> broken_by_strategy  (обход ЛОМАЕТ домен)
#   DNS не отвечает в обеих фазах -> dead_domain         (домен недоступен, тест некорректен)
#
# Опциональное подтверждение разрыва на пути: DPIDETECT_TCPDUMP=1 — во время
# проб собирается tcpdump на WAN-интерфейсе (IP домена, tcp/443), считается
# число RST от сервера. RST при рабочем обходе — признак активного DPI.
#
# Технические переменные для тестов:
#   DPIDETECT_SETTLE   пауза после смены лока, сек (по умолчанию 3 — не меньше
#                      TTL кэша locked.lua; 0 допускается только в тестах)

DPIDETECT_SETTLE="${DPIDETECT_SETTLE:-3}"
DPIDETECT_TCPDUMP="${DPIDETECT_TCPDUMP:-0}"

# Вердикт из двух коротких токенов (ok|warn|fail). Эхом код вердикта.
dpidetect_classify() {
    local base="$1" strat="$2"
    local bg sg
    case "$base" in ok) bg=2 ;; warn) bg=1 ;; *) bg=0 ;; esac
    case "$strat" in ok) sg=2 ;; warn) sg=1 ;; *) sg=0 ;; esac
    if [ "$sg" -gt "$bg" ]; then
        if [ "$sg" -eq 2 ]; then echo blocked_fixed; else echo blocked_improved; fi
    elif [ "$sg" -lt "$bg" ]; then
        echo broken_by_strategy
    elif [ "$bg" -eq 0 ]; then
        echo blocked_nofix
    else
        echo not_blocked
    fi
}

dpidetect_settle() {
    [ "${DPIDETECT_SETTLE:-0}" -gt 0 ] 2>/dev/null && sleep "$DPIDETECT_SETTLE"
    return 0
}

# Предыдущее состояние лока ("auto" = строки нет).
_dpidetect_prev_state() {
    local prev
    prev="$(orch_locked_state_get "$1" "$2")"
    case "$prev" in auto|"") echo auto ;; *) echo "$prev" ;; esac
}

_dpidetect_restore_state() {
    local key="$1" proto="$2" prev="$3"
    case "$prev" in
        auto) orch_locked_clear "$key" "$proto" 2>/dev/null || true ;;
        *) orch_locked_set "$key" "$proto" "$prev" 2>/dev/null || true ;;
    esac
}

# Проба с временным локом. Результат — в глобальных DPIDETECT_V12/V13/DL/TOKEN/TXT.
# Глобалы сбрасываются в начале: старые значения фазы не должны протекать в новую.
_dpidetect_probe_locked() {
    local key="$1" proto="$2" state="$3" url="$4" out sh
    DPIDETECT_V12=""; DPIDETECT_V13=""; DPIDETECT_DL=""
    DPIDETECT_TOKEN="fail"; DPIDETECT_TXT="ошибка пробы"
    orch_locked_set "$key" "$proto" "$state" || return 1
    dpidetect_settle
    out="$(z2r_tls_check_target "$url")" || return 1
    DPIDETECT_V12="$(printf '%s\n' "$out" | sed -n 1p)"
    DPIDETECT_V13="$(printf '%s\n' "$out" | sed -n 2p)"
    DPIDETECT_DL="$(printf '%s\n' "$out" | sed -n 3p)"
    sh="$(z2r_tls_short_result "$DPIDETECT_V12" "$DPIDETECT_V13" "$DPIDETECT_DL" "any")"
    DPIDETECT_TOKEN="${sh%%|*}"
    DPIDETECT_TXT="${sh#*|}"
    return 0
}

# DNS не отвечает ни в одной из двух версий TLS фазы.
_dpidetect_phase_is_dns() {
    local v12="$1" v13="$2" s12 s13
    s12="$(z2r_tls_version_state "$(z2r_tls_field "$v12" 1)" "$(z2r_tls_field "$v12" 2)")"
    s13="$(z2r_tls_version_state "$(z2r_tls_field "$v13" 1)" "$(z2r_tls_field "$v13" 2)")"
    [ "$s12" = "dns" ] || [ "$s13" = "dns" ]
}

_dpidetect_print_phase() {
    local label="$1" v12="$2" v13="$3" token="$4" txt="$5"
    local badge btxt bst bcol line12 line13 color disp
    case "$token" in
        ok) color="$green"; disp="OK  " ;;
        warn) color="$yellow"; disp="WARN" ;;
        *) color="$red"; disp="FAIL"; token="fail" ;;
    esac
    badge="$(z2r_tls_version_badge "tls1.2" "$v12")"
    btxt="${badge%%|*}"; bst="${badge#*|}"
    case "$bst" in ok) bcol="$green" ;; http) bcol="$yellow" ;; fail) bcol="$red" ;; *) bcol="$plain" ;; esac
    line12="$(printf '%b%-17s%b' "$bcol" "$btxt" "$plain")"
    badge="$(z2r_tls_version_badge "tls1.3" "$v13")"
    btxt="${badge%%|*}"; bst="${badge#*|}"
    case "$bst" in ok) bcol="$green" ;; http) bcol="$yellow" ;; fail) bcol="$red" ;; *) bcol="$plain" ;; esac
    line13="$(printf '%b%-17s%b' "$bcol" "$btxt" "$plain")"
    printf '%-24s %b %b %b%s%b\n' "$label" "$line12" "$line13" \
        "$color" "$txt" "$plain"
}

# ---- tcpdump: опциональное подтверждение RST на пути ----

_dpidetect_tcpdump_start() {
    DPIDETECT_TCPDUMP_PID=""
    DPIDETECT_TCPDUMP_FILE=""
    [ "$DPIDETECT_TCPDUMP" = "1" ] || return 0
    command -v tcpdump >/dev/null 2>&1 || { echo -e "${yellow}tcpdump не найден — подтверждающий захват пропущен.${plain}"; return 0; }
    local ip wan
    ip="$(nslookup "$1" 2>/dev/null | awk '/Address/ {print $NF}' | grep -E '^[0-9]+\.[0-9]+\.' | grep -v '^127\.' | head -1)"
    [ -n "$ip" ] || { echo -e "${yellow}Не удалось определить IP домена — захват пропущен.${plain}"; return 0; }
    wan="$(config_keenetic_detect_default_iface 4 2>/dev/null)"
    [ -n "$wan" ] || { echo -e "${yellow}Не удалось определить WAN-интерфейс — захват пропущен.${plain}"; return 0; }
    DPIDETECT_TCPDUMP_FILE="$(mktemp "${TMPDIR:-/tmp}/dpidetect_tcpdump.XXXXXX")" || return 0
    tcpdump -i "$wan" -n -c 4000 "host $ip and tcp port 443" >"$DPIDETECT_TCPDUMP_FILE" 2>/dev/null &
    DPIDETECT_TCPDUMP_PID=$!
}

_dpidetect_tcpdump_stop() {
    [ -n "${DPIDETECT_TCPDUMP_PID:-}" ] && {
        kill "$DPIDETECT_TCPDUMP_PID" 2>/dev/null || true
        wait "$DPIDETECT_TCPDUMP_PID" 2>/dev/null || true
        DPIDETECT_TCPDUMP_PID=""
    }
    if [ -n "${DPIDETECT_TCPDUMP_FILE:-}" ] && [ -s "$DPIDETECT_TCPDUMP_FILE" ]; then
        local rst_all rst_srv
        rst_all="$(grep -c 'Flags \[R' "$DPIDETECT_TCPDUMP_FILE" 2>/dev/null || true)"
        rst_srv="$(grep -c '\.443 > .*Flags \[R' "$DPIDETECT_TCPDUMP_FILE" 2>/dev/null || true)"
        echo ""
        echo -e "${cyan}tcpdump: RST всего: ${rst_all:-0}, от сервера (443→): ${rst_srv:-0}.${plain}"
        echo -e "${cyan}RST от сервера при зелёной пробе — активный разрыв соединения на пути (DPI).${plain}"
    fi
    [ -n "${DPIDETECT_TCPDUMP_FILE:-}" ] && rm -f "$DPIDETECT_TCPDUMP_FILE"
    DPIDETECT_TCPDUMP_FILE=""
    return 0
}

# Ядро: kind=profile|domain, key=номер профиля или домен, url — цель проб,
# candidate — номер стратегии (пусто = текущий лок или 1).
# Вердикт печатается человекочитаемо, последняя строка: "Вердикт: <code>".
dpidetect_run() {
    local kind="$1" key="$2" url="$3" candidate="${4:-}"
    local proto="tls" prev base_state label_base label_strat
    local base_token strat_token verdict base_txt strat_txt
    local base_v12 base_v13 strat_v12 strat_v13
    local had_e=0
    case "$-" in *e*) had_e=1 ;; esac

    if ! zapret2_running; then
        echo -e "${red}zapret2 не запущен — дифференциальная диагностика невозможна (обе пробы пойдут мимо дезинка).${plain}"
        echo -e "${yellow}Запустите zapret2 и повторите.${plain}"
        return 1
    fi

    prev="$(_dpidetect_prev_state "$key" "$proto")"
    if printf '%s' "$candidate" | grep -Eq '^[1-9][0-9]*$'; then
        base_state="$candidate"
    elif printf '%s' "$prev" | grep -Eq '^[1-9][0-9]*$'; then
        base_state="$prev"
    else
        base_state=1
    fi

    case "$kind" in
        profile) label_base="Без профиля $key:"; label_strat="Профиль $key, стр. $base_state:" ;;
        *)       label_base="Без обхода ($key):"; label_strat="Стратегия $base_state:" ;;
    esac

    echo -e "${cyan}Дифференциальная проба: две серии TLS-проверок $url${plain}"
    echo -e "${cyan}(ключ временно переводится на лок 0, затем на лок $base_state; прежний лок восстанавливается)${plain}"
    echo ""

    set +e
    trap 'dpidetect_interrupted=1' INT
    dpidetect_interrupted=0
    _dpidetect_tcpdump_start "$url"

    # Фаза 1: базлайн — трафик ключа проходит без дезинка (лок 0).
    if ! _dpidetect_probe_locked "$key" "$proto" 0 "$url"; then
        trap - INT
        _dpidetect_tcpdump_stop
        _dpidetect_restore_state "$key" "$proto" "$prev"
        [ "$had_e" = "1" ] && set -e
        echo -e "${red}Проба базлайна не удалась. Лок $key восстановлен (${prev}).${plain}"
        return 1
    fi
    base_token="$DPIDETECT_TOKEN"; base_txt="$DPIDETECT_TXT"
    base_v12="$DPIDETECT_V12"; base_v13="$DPIDETECT_V13"

    if [ "${dpidetect_interrupted:-0}" = "1" ]; then
        trap - INT
        _dpidetect_tcpdump_stop
        _dpidetect_restore_state "$key" "$proto" "$prev"
        [ "$had_e" = "1" ] && set -e
        echo -e "${yellow}Прервано пользователем. Лок $key восстановлен (${prev}).${plain}"
        return 130
    fi

    # Фаза 2: кандидат — та же проба под локом стратегии.
    _dpidetect_probe_locked "$key" "$proto" "$base_state" "$url"
    strat_token="$DPIDETECT_TOKEN"; strat_txt="$DPIDETECT_TXT"
    strat_v12="$DPIDETECT_V12"; strat_v13="$DPIDETECT_V13"

    trap - INT
    _dpidetect_tcpdump_stop
    _dpidetect_restore_state "$key" "$proto" "$prev"
    [ "$had_e" = "1" ] && set -e

    echo ""
    _dpidetect_print_phase "$label_base" "$base_v12" "$base_v13" "$base_token" "$base_txt"
    _dpidetect_print_phase "$label_strat" "$strat_v12" "$strat_v13" "$strat_token" "$strat_txt"
    echo ""

    if _dpidetect_phase_is_dns "$base_v12" "$base_v13" && _dpidetect_phase_is_dns "$strat_v12" "$strat_v13"; then
        echo -e "${red}DNS не отвечает в обеих фазах — домен недоступен, о DPI-блокировке судить нельзя.${plain}"
        echo -e "${yellow}Проверьте, что домен написан верно, и что DNS работает (п.7 главного меню).${plain}"
        echo "Вердикт: dead_domain"
        return 0
    fi

    verdict="$(dpidetect_classify "$base_token" "$strat_token")"
    case "$verdict" in
        blocked_fixed)
            echo -e "${green}Домен блокируется DPI: без обхода не работает, стратегия $base_state чинит его.${plain}"
            echo -e "Лок $key = $base_state — рабочий обход. Локи возвращены к прежнему состоянию."
            ;;
        blocked_improved)
            echo -e "${yellow}Домен блокируется DPI: без обхода не работает, стратегия $base_state помогает частично.${plain}"
            echo -e "${yellow}Стоит подобрать другую стратегию (автопрогон, A в подборе стратегии).${plain}"
            ;;
        blocked_nofix)
            echo -e "${red}Домен блокируется DPI, стратегия $base_state не помогает.${plain}"
            echo -e "${yellow}Запустите автопрогон стратегий для этого ключа (A в подборе стратегии).${plain}"
            ;;
        not_blocked)
            echo -e "${green}Домен НЕ блокируется: работает и без обхода, и со стратегией $base_state.${plain}"
            echo -e "Специальный обход для него не нужен."
            ;;
        broken_by_strategy)
            echo -e "${red}Стратегия $base_state ЛОМАЕТ домен: без обхода работает, с обходом — нет.${plain}"
            echo -e "${yellow}Смените стратегию для ключа или исключите домен из профиля (netrogat, п.6).${plain}"
            ;;
    esac
    echo "Вердикт: $verdict"
    return 0
}

# Список авто-исключённых «ломались обходом» доменов (break-validator)
# с возможностью убрать домен из исключения.
dpidetect_broken_list() {
    local file="${ZATOR_ROOT:-/opt/zator}/lists/z2r_broken_hosts.txt"
    local log="${ZATOR_ROOT:-/opt/zator}/extra_strats/cache/orchestra/broken_hosts.tsv"
    local domains=() line ans i
    if [ -f "$file" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && ! printf '%s' "$line" | grep -Eq '^[[:space:]]*#' || continue
            domains+=("$line")
        done < "$file"
    fi
    echo -e "${cyan}--- Домены, исключённые из обхода (ломались им) ---${plain}"
    echo ""
    if [ "${#domains[@]}" -eq 0 ]; then
        echo -e "${green}Пусто: доменов, которые ломались бы обходом, не найдено.${plain}"
        pause_enter
        return 0
    fi
    i=1
    for line in "${domains[@]}"; do
        echo -e "  ${Fcyan}${i}.${plain} ${yellow}${line}${plain}"
        i=$((i + 1))
    done
    if [ -f "$log" ]; then
        echo ""
        echo -e "${cyan}Последние подтверждения (дата / домен / стратегия):${plain}"
        tail -n 5 "$log" 2>/dev/null || true
    fi
    echo ""
    read -re -p "Номер домена для возврата в обход (пусто/0 - выход): " ans
    case "$ans" in
        ""|0) return 0 ;;
    esac
    if ! printf '%s' "$ans" | grep -Eq '^[0-9]+$' || [ "$ans" -lt 1 ] || [ "$ans" -gt "${#domains[@]}" ]; then
        echo -e "${yellow}Неверный номер.${plain}"
        pause_enter
        return 0
    fi
    line="${domains[$((ans - 1))]}"
    domain_list_remove "$file" "$line"
    echo -e "${green}Домен ${line} возвращён в обход (исключение снято, подхватится за ~2 сек).${plain}"
    pause_enter
}

# Одноразовый запрос домена и запуск диагностики (для п.6 «Управление доменами»).
dpidetect_domain_ask() {
    local key
    read -re -p "Домен для диагностики (например, example.com): " key
    if [ -z "$key" ]; then
        echo "Ввод пустой."
        pause_enter
        return 0
    fi
    key="$(z2r_normalize_domain "$key" 2>/dev/null || echo "$key")"
    dpidetect_run "domain" "$key" "https://$key/"
    pause_enter
}

# Меню диагностики: домен или профиль.
dpidetect_menu() {
    local ans url key
    while true; do
        clear -x
        echo -e "${cyan}--- Диагностика: кто сломал домен? ---${plain}"
        echo ""
        echo "Определяет дифференциальной пробой (без обхода / со стратегией):"
        echo "  - домен блокируется DPI и обход его чинит;"
        echo "  - домен блокируется, но стратегия не помогает;"
        echo "  - домен не блокируется (обход не нужен);"
        echo "  - обход сам ломает домен (без zapret2 работает)."
        echo ""
        submenu_item "1" "Проверить домен (по SNI/Host)"
        submenu_item "2" "Проверить профиль (TCP TLS)"
        submenu_item "3" "Домены, исключённые автоматически (ломались обходом)"
        submenu_item "0" "Назад"
        echo ""
        read -re -p "Ваш выбор: " ans
        case "$ans" in
            1)
                read -re -p "Домен (например, example.com): " key
                if [ -z "$key" ]; then
                    echo "Ввод пустой."
                    pause_enter
                    continue
                fi
                key="$(z2r_normalize_domain "$key" 2>/dev/null || echo "$key")"
                url="https://$key/"
                dpidetect_run "domain" "$key" "$url"
                pause_enter
                ;;
            2)
                read -re -p "Номер профиля (1-4, 8): " key
                case "$key" in
                    1) url="https://www.youtube.com/" ;;
                    2) url="https://$(get_yt_cluster_domain 2>/dev/null || echo 'rr1---sn-example.googlevideo.com')" ;;
                    3) url="https://meduza.io" ;;
                    4) url="https://discord.com/" ;;
                    8) url="https://www.youtube.com/" ;;
                    *) echo "Профиль должен быть 1-4 или 8 (TLS)."; pause_enter; continue ;;
                esac
                dpidetect_run "profile" "$key" "$url"
                pause_enter
                ;;
            3)
                dpidetect_broken_list
                ;;
            0|"") return 0 ;;
            *) ui_invalid_input ;;
        esac
    done
}
