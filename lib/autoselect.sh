#!/bin/sh
# lib/autoselect.sh — независимый быстрый подбор стратегий.
#
# Альтернатива orch_auto_sweep (полный перебор 43 стратегий × (проба+пауза),
# ~6-10 минут на профиль). Принципы ускорения:
#
#  1. Baseline-гейт: перед перебором — дифференциальная проба «без обхода»
#     (временный лок 0). Домен не блокируется → перебор не запускается
#     вообще (в авторотации это главная пустая работа).
#  2. Дешёвый отсев: на каждую стратегию — только HEAD-пробы движка
#     z2r_tls_* без докачки (Z2R_TLS_NO_DL=1): зелёность = сервер ответил.
#  3. Early-exit: стоп после K зелёных (Z2R_AUTOSELECT_K, default 3) —
#     полный прогон не нужен, «лучшую» ищем только среди финалистов.
#  4. Докачка-ранжирование только финалистов: скорость (байт/с) среди
#     зелёных, метрика та же, что у orch_auto_sweep.
#  5. Warm start: топ стратегий из кэша профиля (autoselect.tsv) —
#     первыми, свежие победы выше.
#
# Пауза между стратегиями Z2R_AUTOSELECT_PAUSE (default 3 сек) совмещена
# с TTL-ожиданием lua-кэша локов (2 сек): смена лока без неё не видна.
# Рестарт nfqws2 не нужен ни на одном шаге.
#
# Технические переменные для тестов: Z2R_AUTOSELECT_SETTLE (пауза после
# смены лока, default 3), Z2R_AUTOSELECT_PAUSE, Z2R_AUTOSELECT_K.

Z2R_AUTOSELECT_SETTLE="${Z2R_AUTOSELECT_SETTLE:-3}"
Z2R_AUTOSELECT_PAUSE="${Z2R_AUTOSELECT_PAUSE:-3}"
Z2R_AUTOSELECT_K="${Z2R_AUTOSELECT_K:-3}"
AUTOSELECT_DB="${ORCH_DIR:-/opt/zator/extra_strats/cache/orchestra}/autoselect.tsv"

autoselect_settle() {
    [ "${Z2R_AUTOSELECT_SETTLE:-0}" -gt 0 ] 2>/dev/null && sleep "$Z2R_AUTOSELECT_SETTLE"
    return 0
}

# ---- кэш побед (warm start) ----

# Топ-N стратегий профиля по числу побед (свежие выигрывают при равенстве).
autoselect_warm_list() {
    local profile="$1" count="${2:-3}"
    [ -f "$AUTOSELECT_DB" ] || return 0
    awk -F'\t' -v pr="$profile" -v n="$count" '
        $1 == pr && $2 ~ /^[1-9][0-9]*$/ { print $2, $3 + 0, $4 + 0 }
    ' "$AUTOSELECT_DB" | sort -k2,2nr -k3,3nr | head -n "$count" | awk '{ print $1 }'
}

autoselect_remember_win() {
    local profile="$1" strategy="$2" now tmp
    [ -f "$AUTOSELECT_DB" ] || : > "$AUTOSELECT_DB"
    now="$(date +%s)"
    tmp="${AUTOSELECT_DB}.tmp.$$"
    awk -F'\t' -v OFS='\t' -v pr="$profile" -v st="$strategy" -v ts="$now" '
        BEGIN { found = 0 }
        $1 == pr && $2 == st { print pr, st, $3 + 1, ts; found = 1; next }
        { print }
        END { if (!found) print pr, st, 1, ts }
    ' "$AUTOSELECT_DB" > "$tmp" && mv -f "$tmp" "$AUTOSELECT_DB" || rm -f "$tmp"
    # Кэш не растёт бесконечно: держим топ-10 на профиль.
    tmp="${AUTOSELECT_DB}.trim.$$"
    awk -F'\t' '{ print }' "$AUTOSELECT_DB" | sort -t'	' -k1,1 -k3,3nr | awk -F'\t' '!seen[$1]++ || c[$1]++ < 10' > "$tmp" \
        && mv -f "$tmp" "$AUTOSELECT_DB" || rm -f "$tmp"
    return 0
}

# ---- пробы ----

# HEAD-отсев без докачки: печатает "ok|warn|fail|текст" (z2r_tls_short_result).
autoselect_screen_probe() {
    local url="$1" out v12 v13 sh
    # export, а не префикс к присваиванию локальной переменной: префиксные
    # VAR=x не доезжают до дочерних процессов подстановки в bash.
    local no_dl_prev="${Z2R_TLS_NO_DL:-}"
    export Z2R_TLS_NO_DL=1 Z2R_TLS_WAIT_BOTH=1
    out="$(z2r_tls_check_target "$url")" || true
    if [ -n "$no_dl_prev" ]; then Z2R_TLS_NO_DL="$no_dl_prev"; else unset Z2R_TLS_NO_DL; fi
    v12="$(printf '%s\n' "$out" | sed -n 1p)"
    v13="$(printf '%s\n' "$out" | sed -n 2p)"
    sh="$(z2r_tls_short_result "$v12" "$v13" "skip" "any")"
    printf '%s\n' "$sh"
}

# Полная проба с докачкой для ранжирования: печатает "ok|текст" + метрику
# скорости в глобальной AUTOSELECT_SPEED (байт/с; 0 — без докачки).
autoselect_rank_probe() {
    local url="$1" out v12 v13 dl sh dlsize dltime
    unset Z2R_TLS_NO_DL
    export Z2R_TLS_WAIT_BOTH=1
    out="$(z2r_tls_check_target "$url")" || true
    v12="$(printf '%s\n' "$out" | sed -n 1p)"
    v13="$(printf '%s\n' "$out" | sed -n 2p)"
    dl="$(printf '%s\n' "$out" | sed -n 3p)"
    sh="$(z2r_tls_short_result "$v12" "$v13" "$dl" "any")"
    AUTOSELECT_SPEED=0
    if [ "$dl" != "skip" ]; then
        dlsize="$(z2r_tls_field "$dl" 3)"; dltime="$(z2r_tls_field "$dl" 4)"
        if printf '%s' "$dltime" | grep -Eq '^[0-9]+\.?[0-9]*$' && [ "$dltime" != "0" ]; then
            AUTOSELECT_SPEED="$(awk -v sz="$dlsize" -v t="$dltime" 'BEGIN { printf "%d", sz / t }')"
        fi
    fi
    # Скорость — второй строкой вывода: глобальная переменная из $(...)
    # подстановки не возвращается в вызывающую оболочку.
    printf '%s\n%s\n' "$sh" "$AUTOSELECT_SPEED"
}

# ---- ядро подбора ----

# autoselect_run kind key proto_list test_url start max
# kind=profile|domain; key=профиль или домен. Возвращает 0 при сохранённой
# стратегии, 130 при прерывании (локи восстановлены).
autoselect_run() {
    local kind="$1" key="$2" proto_list="$3" test_url="$4" start="$5" max="$6"
    local p s out token txt verdict best="" best_speed=0
    local greens="" n_green=0 rank_speed
    local prev_str="" had_e=0 interrupted=0 svc_was_running=0
    local -A prev_map
    case "$-" in *e*) had_e=1 ;; esac

    if ! zapret2_running; then
        echo -e "${red}zapret2 не запущен — подбор невозможен.${plain}"
        return 1
    fi

    # Прежние локи — восстановить при любом исходе.
    if [ "$kind" = "domain" ]; then
        prev_str="$(_autoselect_prev "$key" "tls")"
    else
        for p in $proto_list; do
            prev_map["$p"]="$(_autoselect_prev "$key" "$p")"
        done
    fi

    # 1) Baseline-гейт: работает ли цель без обхода вообще.
    echo -e "${cyan}Шаг 1/3: проба без обхода (временный лок 0)...${plain}"
    _autoselect_lock_all "$kind" "$key" "$proto_list" 0
    autoselect_settle
    out="$(autoselect_screen_probe "$test_url")"
    token="${out%%|*}"
    if [ "$token" != "fail" ]; then
        echo -e "${green}Цель отвечает БЕЗ обхода — блокировки нет, подбор стратегий не нужен.${plain}"
        echo -e "Если сайт всё же не открывается — проблема не в DPI-блокировке (DNS, сам сайт, провайдер)."
        _autoselect_restore "$kind" "$key" "$proto_list" prev_map "$prev_str"
        return 0
    fi
    echo -e "${yellow}Без обхода цели нет (блокировка подтверждена) — перебираем стратегии.${plain}"

    # 2) Отсев: warm-start порядок + остальные, HEAD-проба, early-exit на K зелёных.
    local order="" warm s_seen
    warm="$(autoselect_warm_list "$key" 3)"
    for s in $warm; do
        [ "$s" -ge "$start" ] 2>/dev/null && [ "$s" -le "$max" ] 2>/dev/null || continue
        case " $order " in *" $s "*) continue ;; esac
        order="$order $s"
    done
    for ((s=start; s<=max; s++)); do
        case " $order " in *" $s "*) continue ;; esac
        order="$order $s"
    done

    local n_total="$(printf '%s\n' $order | wc -w)"
    echo ""
    echo -e "${cyan}Шаг 2/3: отсев ${n_total} стратегий (HEAD-пробы без докачки, стоп после ${Z2R_AUTOSELECT_K:-3} зелёных). Ctrl+C - прервать.${plain}"

    set +e
    trap 'autoselect_interrupted=1' INT
    autoselect_interrupted=0
    zapret2_running && svc_was_running=1

    for s in $order; do
        _autoselect_lock_all "$kind" "$key" "$proto_list" "$s"
        autoselect_settle
        out="$(autoselect_screen_probe "$test_url")"
        if [ "$autoselect_interrupted" = "1" ]; then break; fi
        token="${out%%|*}"; txt="${out#*|}"
        case "$token" in
            ok)   color="$green";  disp="OK  " ;;
            warn) color="$yellow"; disp="WARN" ;;
            *)    color="$red";    disp="FAIL"; token="fail" ;;
        esac
        printf '%s %3d: %b %b%s%b\n' "$(date '+%H:%M:%S')" "$s" \
            "$color$disp$plain" "$color$txt$plain" "" ""
        if [ "$token" = "ok" ]; then
            greens="$greens $s"
            n_green=$((n_green + 1))
            [ "$n_green" -ge "${Z2R_AUTOSELECT_K:-3}" ] 2>/dev/null && break
        fi
        # Пауза между переключениями против ТСПУ (совмещена с TTL-ожиданием).
        if [ "${Z2R_AUTOSELECT_PAUSE:-0}" -gt 0 ] 2>/dev/null; then
            sleep "$Z2R_AUTOSELECT_PAUSE"
        fi
        [ "$autoselect_interrupted" = "1" ] && break
    done

    if [ "$autoselect_interrupted" = "1" ]; then
        trap - INT
        [ "$had_e" = "1" ] && set -e
        echo -e "${yellow}Прервано пользователем. Локи восстановлены.${plain}"
        _autoselect_restore "$kind" "$key" "$proto_list" prev_map "$prev_str"
        _autoselect_safety_net "$svc_was_running"
        return 130
    fi
    trap - INT
    [ "$had_e" = "1" ] && set -e

    if [ "$n_green" -eq 0 ]; then
        echo ""
        echo -e "${red}Зелёных стратегий не найдено (${n_total} проверено).${plain}"
        echo -e "${yellow}Запустите полный автопрогон (A) с другой целью/версиями TLS либо проверьте сайт вручную.${plain}"
        _autoselect_restore "$kind" "$key" "$proto_list" prev_map "$prev_str"
        _autoselect_safety_net "$svc_was_running"
        return 0
    fi

    # 3) Ранжирование финалистов докачкой (скорость байт/с).
    echo ""
    echo -e "${cyan}Шаг 3/3: ранжирование зелёных (${greens# }) докачкой 64КБ...${plain}"
    best=""
    best_speed=0
    for s in $greens; do
        _autoselect_lock_all "$kind" "$key" "$proto_list" "$s"
        autoselect_settle
        out="$(autoselect_rank_probe "$test_url")"
        token="$(printf '%s\n' "$out" | sed -n 1p)"
        token="${token%%|*}"
        rank_speed="$(printf '%s\n' "$out" | sed -n 2p)"
        case "$rank_speed" in ''|*[!0-9]*) rank_speed=0 ;; esac
        printf '  стр. %3d: %s (скорость %s байт/с)\n' "$s" "$(printf '%s\n' "$out" | sed -n 1p | cut -d'|' -f2-)" "$rank_speed"
        if [ "$token" = "ok" ] && [ "$rank_speed" -gt "$best_speed" ]; then
            best="$s"
            best_speed="$rank_speed"
        fi
    done
    [ -n "$best" ] || best="$(printf '%s\n' $greens | head -1)"

    trap - INT 2>/dev/null
    _autoselect_restore "$kind" "$key" "$proto_list" prev_map "$prev_str"
    _autoselect_safety_net "$svc_was_running"

    echo ""
    echo "================================================"
    if [ -n "$best" ]; then
        echo -e " Лучшая из найденных: ${Fgreen}${best}${plain} (скорость докачки ${best_speed} байт/с)"
        read -re -p "Enter - применить стратегию ${best}, номер - другую зелёную ($greens ), 0 - отмену: " answer || answer="0"
        local pick="$best"
        if [ "$answer" = "0" ]; then
            echo "Оставлены прежние локи."
            return 0
        fi
        if [ -n "$answer" ]; then
            if printf '%s' "$answer" | grep -Eq '^[1-9][0-9]*$' \
               && case " $greens " in *" $answer "*) true;; *) false;; esac; then
                pick="$answer"
            else
                echo -e "${yellow}Неверный номер, берём лучшую (${best}).${plain}"
            fi
        fi
        _autoselect_lock_all "$kind" "$key" "$proto_list" "$pick"
        autoselect_remember_win "$key" "$pick"
        echo -e "${green}Стратегия ${pick} применена для ${key} и запомнена в warm-кэше.${plain}"
        return 0
    fi
}

_autoselect_prev() {
    local prev
    prev="$(orch_locked_state_get "$1" "$2")"
    case "$prev" in auto|"") echo auto ;; *) echo "$prev" ;; esac
}

_autoselect_lock_all() {
    local kind="$1" key="$2" proto_list="$3" state="$4" p
    if [ "$kind" = "domain" ]; then
        orch_locked_set "$key" "tls" "$state" || return 1
    else
        for p in $proto_list; do
            orch_locked_set "$key" "$p" "$state" || return 1
        done
    fi
}

_autoselect_restore() {
    local kind="$1" key="$2" proto_list="$3" restore_map="$4" prev_str="$5" p
    if [ "$kind" = "domain" ]; then
        case "$prev_str" in
            auto) orch_locked_clear "$key" "tls" 2>/dev/null || true ;;
            *) orch_locked_set "$key" "tls" "$prev_str" 2>/dev/null || true ;;
        esac
    else
        for p in $proto_list; do
            case "${prev_map[$p]:-auto}" in
                auto) orch_locked_clear "$key" "$p" 2>/dev/null || true ;;
                *) orch_locked_set "$key" "$p" "${prev_map[$p]}" 2>/dev/null || true ;;
            esac
        done
    fi
}

# Safety net из orch_auto_sweep: если nfqws2 был жив и умер (Ctrl+C) — рестарт.
_autoselect_safety_net() {
    [ "$1" = "1" ] || return 0
    zapret2_running && return 0
    echo -e "${red}zapret2 был остановлен: процесс nfqws2 убит. Перезапускаю...${plain}"
    z2r_service_action restart >/dev/null 2>&1 || true
    if zapret2_running; then
        echo -e "${green}zapret2 снова работает.${plain}"
    else
        echo -e "${red}Не удалось перезапустить zapret2. Запустите вручную: пункт 22 главного меню.${plain}"
    fi
}
