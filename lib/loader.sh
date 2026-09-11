#!/bin/sh

LOADED_MODULE_PATH=''

loader_url_for() {
    override_url=$(linuxapp_script_override_url "$1" 2>/dev/null || true)
    if [ -n "$override_url" ]; then
        printf '%s\n' "$override_url"
    elif [ -n "${LINUXAPP_BASE_URL:-}" ]; then
        printf '%s/%s\n' "${LINUXAPP_BASE_URL%/}" "$1"
    else
        printf '\n'
    fi
}

loader_download() {
    loader_url=$1
    loader_target=$2
    loader_has_local=$3
    loader_tmp="$loader_target.tmp.$$"
    mkdir -p "$(dirname "$loader_target")" 2>/dev/null || return 1

    if command -v curl >/dev/null 2>&1; then
        if [ "$loader_has_local" = 1 ]; then
            curl -fsSL --connect-timeout "${LINUXAPP_CONNECT_TIMEOUT:-10}" "$loader_url" -o "$loader_tmp" 2>/dev/null
        else
            curl -fsSL "$loader_url" -o "$loader_tmp" 2>/dev/null
        fi
        loader_status=$?
    elif command -v wget >/dev/null 2>&1; then
        if [ "$loader_has_local" = 1 ]; then
            wget -q --timeout="${LINUXAPP_CONNECT_TIMEOUT:-10}" -O "$loader_tmp" "$loader_url" 2>/dev/null
        else
            wget -q -O "$loader_tmp" "$loader_url" 2>/dev/null
        fi
        loader_status=$?
    else
        ui_warn '系统中找不到 curl 或 wget，无法在线下载。'
        return 1
    fi

    if [ "$loader_status" -eq 0 ] && [ -s "$loader_tmp" ]; then
        mv "$loader_tmp" "$loader_target"
        chmod 600 "$loader_target" 2>/dev/null || true
        return 0
    fi
    rm -f "$loader_tmp"
    return 1
}

loader_ensure_script() {
    loader_relative=$1
    loader_local="$LINUXAPP_ROOT/$loader_relative"
    loader_cache=$(cache_script_path "$loader_relative")
    loader_url=$(loader_url_for "$loader_relative")
    LOADED_MODULE_PATH=''

    if [ "${LINUXAPP_OFFLINE:-0}" -eq 1 ]; then
        if [ -f "$loader_local" ]; then
            LOADED_MODULE_PATH=$loader_local
            return 0
        fi
        ui_error "离线模式缺少脚本：$loader_relative"
        return 1
    fi

    if cache_is_fresh "$loader_relative"; then
        # shellcheck disable=SC2034
        LOADED_MODULE_PATH=$loader_cache
        return 0
    fi

    if [ -n "$loader_url" ]; then
        if [ -f "$loader_local" ]; then
            if loader_download "$loader_url" "$loader_cache" 1; then
                cache_stamp=$(cache_stamp_path "$loader_relative")
                printf '%s\n' "$(cache_now)" > "$cache_stamp" 2>/dev/null || true
                # shellcheck disable=SC2034
                LOADED_MODULE_PATH=$loader_cache
                return 0
            fi
            ui_warn "远程脚本连接超时或下载失败，改用本地脚本：$loader_relative"
        else
            if loader_download "$loader_url" "$loader_cache" 0; then
                cache_stamp=$(cache_stamp_path "$loader_relative")
                printf '%s\n' "$(cache_now)" > "$cache_stamp" 2>/dev/null || true
                # shellcheck disable=SC2034
                LOADED_MODULE_PATH=$loader_cache
                return 0
            fi
            ui_error "远程脚本下载失败且本地不存在：$loader_relative"
        fi
    elif [ ! -f "$loader_local" ]; then
        ui_warn "未配置远程地址，且本地脚本不存在：$loader_relative"
    fi

    if [ -f "$loader_local" ]; then
        LOADED_MODULE_PATH=$loader_local
        return 0
    fi
    if [ -f "$loader_cache" ]; then
        # shellcheck disable=SC2034
        LOADED_MODULE_PATH=$loader_cache
        return 0
    fi
    return 1
}

loader_validate_offline() {
    missing=0
    # shellcheck disable=SC2034
    while IFS='|' read -r module_type _ module_path _; do
        case "$module_type" in
            ''|'#'*) continue ;;
        esac
        if [ ! -f "$LINUXAPP_ROOT/$module_path" ]; then
            ui_error "离线清单缺少：$module_path"
            missing=1
        fi
    done < "$LINUXAPP_ROOT/config/modules.list"
    for required in config/source.sh config/modules.list lib/ui.sh lib/input.sh lib/cache.sh lib/loader.sh lib/lifecycle.sh lib/system.sh lib/privilege.sh lib/ssh_hook.sh; do
        if [ ! -f "$LINUXAPP_ROOT/$required" ]; then
            ui_error "离线清单缺少框架脚本：$required"
            missing=1
        fi
    done
    return "$missing"
}

# Last updated: 2026-09-11 19:00
