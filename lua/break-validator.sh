#!/bin/sh
# break-validator: дифференциальная проверка «домен ломается самим обходом».
#
# Обработчик очереди /tmp/z2r-break-check: запросы пишет lua/break-detector.lua
# прямо из nfqws2 при накоплении отказов по хосту. Для каждого хоста делаются
# две пробы curl:
#   A (базлайн)  — хост временно добавлен в горячий exclude_hostlist
#                  (z2r_broken_hosts.txt, подхватывается за TTL 2с без
#                  рестарта) => трафик идёт БЕЗ дезинка;
#   B (стратегия)— хост убран из исключения => текущая стратегия профиля.
#
# Вердикты:
#   BROKEN              без обхода работает, с обходом нет  -> хост остаётся
#                       в исключении насовсем (проходят мимо всех TCP-профилей)
#   FIXED_BY_STRATEGY   без обхода не работает, стратегия чинит (обычный DPI)
#   BLOCKED_NOFIX       не работает ни так ни так (DPI, стратегия не помогает)
#   OK_TRANSIENT        работает в обоих режимах (ложная тревога)
#   DEAD                DNS не отвечает в обеих фазах
#   EXCLUDED            хост уже был в исключении
#
# Результат пишется в result.<id> (его забирает lua-модуль по своим пакетам).
# Обычный запуск — демон (--daemon), одиночный файл — для тестов/ручного прогона.

QUEUE_DIR="${Z2R_BREAK_QUEUE:-/tmp/z2r-break-check}"
EXCLUDE_FILE="${Z2R_BREAK_EXCLUDE:-/opt/zator/lists/z2r_broken_hosts.txt}"
LOG_FILE="${Z2R_BREAK_LOG:-/opt/zator/extra_strats/cache/orchestra/broken_hosts.tsv}"
# Кэш вердиктов в оперативной памяти (tmpfs): «хост → вердикт → время».
# Читает lua-модуль (переиспользование: свежий вердикт не гоняет повторную
# диффпробу даже после рестарта nfqws2); демон периодически чистит протухшее.
VERDICTS_FILE="${Z2R_BREAK_VERDICTS:-/tmp/z2r-break-verdicts.tsv}"
VERDICTS_TTL="${Z2R_BREAK_VERDICT_TTL:-86400}"
SETTLE="${Z2R_BREAK_SETTLE:-3}"
PROBE_MAXTIME="${Z2R_BREAK_MAXTIME:-12}"
Z2R_CURL_UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'
CURL_BIN="$(command -v curl 2>/dev/null)" || CURL_BIN=

mkdir -p "$QUEUE_DIR" 2>/dev/null || true

if [ -z "$CURL_BIN" ]; then
    echo "break-validator: curl is required" >&2
    exit 127
fi

# ---- кэш вердиктов (RAM) ----

verdict_remember() {
    # $1 hostkey, $2 verdict — атомарный upsert в TSV
    local host="$1" verdict="$2" now tmp
    touch "$VERDICTS_FILE" 2>/dev/null || return 0
    now="$(date +%s)"
    tmp="${VERDICTS_FILE}.tmp.$$"
    awk -F'\t' -v OFS='\t' -v h="$host" -v v="$verdict" -v ts="$now" '
        BEGIN { seen = 0 }
        $1 == h { print h, v, ts; seen = 1; next }
        { print }
        END { if (!seen) print h, v, ts }
    ' "$VERDICTS_FILE" 2>/dev/null > "$tmp" && mv -f "$tmp" "$VERDICTS_FILE" 2>/dev/null || rm -f "$tmp"
}

verdict_cleanup() {
    # Протухшие записи (старше VERDICTS_TTL) удаляем; BROKEN живёт в
    # постоянном exclude-файле, кэш ему не нужен.
    [ -f "$VERDICTS_FILE" ] || return 0
    local cutoff tmp
    cutoff=$(( $(date +%s) - VERDICTS_TTL ))
    tmp="${VERDICTS_FILE}.clean.$$"
    awk -F'\t' -v c="$cutoff" '$3 + 0 >= c' "$VERDICTS_FILE" 2>/dev/null > "$tmp" \
        && mv -f "$tmp" "$VERDICTS_FILE" 2>/dev/null || rm -f "$tmp"
}

# Горячий exclude-файл: атомарные add/remove через tmp+mv (его читает
# locked.lua с TTL 2с, частые записи безопасны — файл крошечный).
exclude_add() {
    touch "$EXCLUDE_FILE" 2>/dev/null || return 1
    grep -Fixq "$1" "$EXCLUDE_FILE" 2>/dev/null && return 0
    printf '%s\n' "$1" >> "$EXCLUDE_FILE"
}

exclude_remove() {
    [ -f "$EXCLUDE_FILE" ] || return 0
    tmp="${EXCLUDE_FILE}.tmp.$$"
    grep -Fxv -- "$1" "$EXCLUDE_FILE" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$EXCLUDE_FILE" 2>/dev/null || rm -f "$tmp"
}

# Проба: ok = сервер ответил любым HTTP-кодом (4xx/5xx тоже «транспорт пробит»,
# как в движке z2r_tls_*), dns = не резолвится, fail = нет ответа.
# Один повтор: DPI режет выборочно, одиночный срез — не приговор.
probe_once() {
    url="$1"
    code="$("$CURL_BIN" -4 -sS -o /dev/null -I -k --http1.1 -A "$Z2R_CURL_UA" \
        --connect-timeout 5 --max-time "$PROBE_MAXTIME" \
        -w '%{http_code}' "$url" 2>/dev/null)"
    rc=$?
    case "$rc" in
        6) echo dns; return ;;
    esac
    case "$code" in
        ''|000)
            code="$("$CURL_BIN" -4 -sS -o /dev/null -I -k --http1.1 -A "$Z2R_CURL_UA" \
                --connect-timeout 5 --max-time "$PROBE_MAXTIME" \
                -w '%{http_code}' "$url" 2>/dev/null)"
            rc=$?
            case "$rc" in
                6) echo dns; return ;;
            esac
            case "$code" in
                ''|000) echo fail ;;
                *) echo ok ;;
            esac
            ;;
        *) echo ok ;;
    esac
}

log_broken() {
    # date \t host \t strategy — только подтверждённые BROKEN, для меню
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null || true
}

process_request() {
    req=$1
    case "$req" in "$QUEUE_DIR"/request.[0-9]*) ;; *) return 1 ;; esac
    id=${req##*.}
    case "$id" in ''|*[!0-9]*) return 1 ;; esac
    work=$req.work
    mv "$req" "$work" 2>/dev/null || return 0

    IFS='	' read -r rid hostkey hostname proto strategy extra < "$work"
    if [ -n "$extra" ] || [ "$rid" != "$id" ]; then rm -f "$work"; return 1; fi
    case "$hostkey" in ''|*[!A-Za-z0-9_.-]*) rm -f "$work"; return 1; esac
    case "$hostname" in ''|.*|*.|*..*|*[!A-Za-z0-9.-]*) rm -f "$work"; return 1; esac
    case "$proto" in tls|http) ;; *) rm -f "$work"; return 1; esac
    case "$strategy" in ''|*[!0-9]*) rm -f "$work"; return 1; esac

    if [ -f "$EXCLUDE_FILE" ] && grep -Fixq "$hostname" "$EXCLUDE_FILE" 2>/dev/null; then
        verdict=EXCLUDED
    else
        scheme=https
        [ "$proto" = "http" ] && scheme=http

        # A: базлайн — домен без обхода.
        exclude_add "$hostname"
        sleep "$SETTLE"
        a="$(probe_once "$scheme://$hostname/")"
        exclude_remove "$hostname"

        # B: домен под текущей стратегией профиля.
        sleep "$SETTLE"
        b="$(probe_once "$scheme://$hostname/")"

        if [ "$a" = "dns" ] && [ "$b" = "dns" ]; then
            verdict=DEAD
        elif [ "$a" = "ok" ] && [ "$b" != "ok" ]; then
            verdict=BROKEN
        elif [ "$a" != "ok" ] && [ "$b" = "ok" ]; then
            verdict=FIXED_BY_STRATEGY
        elif [ "$a" = "ok" ]; then
            verdict=OK_TRANSIENT
        else
            verdict=BLOCKED_NOFIX
        fi
    fi

    if [ "$verdict" = "BROKEN" ]; then
        exclude_add "$hostname"
        log_broken "$hostname" "$strategy"
    fi

    # Вердикт — в RAM-кэш: lua-модуль переиспользует его (кулдаун переживает
    # рестарт nfqws2), чистка протухшего — в цикле демона.
    verdict_remember "$hostkey" "$verdict"

    result=$QUEUE_DIR/result.$id
    tmp=$result.tmp.$$
    printf '%s\t%s\t%s\t%s\n' "$id" "$verdict" "$hostkey" "$strategy" > "$tmp" \
        && mv -f "$tmp" "$result"
    logger -t break-validator "id=$id host=$hostname strategy=$strategy verdict=$verdict" 2>/dev/null || true
    rm -f "$work"
}

if [ "$1" = "--daemon" ]; then
    mkdir -p "$QUEUE_DIR" || exit 1
    verdict_cleanup
    while :; do
        for req in "$QUEUE_DIR"/request.[0-9]*; do
            [ -f "$req" ] && process_request "$req"
        done
        # Периодическая чистка кэша вердиктов: раз в час, протухшее (старше
        # VERDICTS_TTL) удаляется — хост позже проверится заново.
        CLEAN_COUNTER=$(( ${CLEAN_COUNTER:-0} + 1 ))
        if [ "$CLEAN_COUNTER" -ge 1800 ]; then
            verdict_cleanup
            CLEAN_COUNTER=0
        fi
        sleep 2
    done
fi

if [ -n "$1" ]; then
    process_request "$1"
fi
