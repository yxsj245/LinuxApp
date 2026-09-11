#!/bin/sh

cache_root() {
    if [ -n "${XDG_CACHE_HOME:-}" ]; then
        printf '%s/linuxapp\n' "$XDG_CACHE_HOME"
    else
        printf '%s/.cache/linuxapp\n' "${HOME:-.}"
    fi
}

cache_key() {
    printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#_#g'
}

cache_script_path() {
    printf '%s/scripts/%s.sh\n' "$(cache_root)" "$(cache_key "$1")"
}

cache_stamp_path() {
    printf '%s/scripts/%s.stamp\n' "$(cache_root)" "$(cache_key "$1")"
}

cache_ensure_dirs() {
    mkdir -p "$(cache_root)/scripts" "$(cache_root)/state" 2>/dev/null
}

cache_now() {
    date +%s 2>/dev/null || printf '0\n'
}

cache_is_fresh() {
    cache_stamp=$(cache_stamp_path "$1")
    cache_script=$(cache_script_path "$1")
    [ -s "$cache_script" ] && [ -s "$cache_stamp" ] || return 1
    cache_time=$(sed -n '1p' "$cache_stamp" 2>/dev/null)
    now_time=$(cache_now)
    case "$cache_time:$now_time" in
        *[!0-9:]*|:) return 1 ;;
    esac
    [ $((now_time - cache_time)) -lt "${LINUXAPP_CACHE_TTL:-3600}" ] 2>/dev/null
}

cache_store_script() {
    cache_ensure_dirs || return 1
    cache_script=$(cache_script_path "$1")
    cache_stamp=$(cache_stamp_path "$1")
    source_file=$2
    tmp_script="$cache_script.tmp.$$"
    tmp_stamp="$cache_stamp.tmp.$$"
    if ! cp "$source_file" "$tmp_script" 2>/dev/null; then
        rm -f "$tmp_script" "$tmp_stamp"
        return 1
    fi
    printf '%s\n' "$(cache_now)" > "$tmp_stamp" || {
        rm -f "$tmp_script" "$tmp_stamp"
        return 1
    }
    chmod 600 "$tmp_script" "$tmp_stamp" 2>/dev/null || true
    mv "$tmp_script" "$cache_script" && mv "$tmp_stamp" "$cache_stamp"
}

# Last updated: 2026-09-11 19:00
