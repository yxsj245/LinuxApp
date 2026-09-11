#!/bin/sh

UI_RESET=''
UI_BOLD=''
UI_PRIMARY=''
UI_SECONDARY=''
UI_WARNING=''
UI_ERROR=''
UI_SUCCESS=''

ui_init() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        UI_RESET=$(printf '\033[0m')
        UI_BOLD=$(printf '\033[1m')
        UI_PRIMARY=$(printf '\033[36m')
        UI_SECONDARY=$(printf '\033[37m')
        UI_WARNING=$(printf '\033[33m')
        UI_ERROR=$(printf '\033[31m')
        UI_SUCCESS=$(printf '\033[32m')
    fi
}

ui_clear() {
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
        printf '\033[H\033[2J'
    else
        printf '\n\n\n'
    fi
}

ui_header() {
    printf '%s==============================%s\n' "$UI_PRIMARY" "$UI_RESET"
    printf '%s LinuxApp 环境管理器%s\n' "$UI_BOLD" "$UI_RESET"
    printf '%s==============================%s\n' "$UI_PRIMARY" "$UI_RESET"
}

ui_section() {
    printf '%s--- %s --- %s\n' "$UI_PRIMARY" "$1" "$UI_RESET"
}

ui_menu_item() {
    printf '%s%s%s %s%s%s\n' "$UI_PRIMARY" "$1" "$UI_RESET" "$UI_SECONDARY" "$2" "$UI_RESET"
}

ui_text() {
    printf '%s%s%s\n' "$UI_SECONDARY" "$1" "$UI_RESET"
}

ui_text_block() {
    while IFS= read -r ui_line; do
        ui_text "$ui_line"
    done
}

ui_status_color() {
    case "$1" in
        运行中|已安装) printf '%s' "$UI_SUCCESS" ;;
        已停止|未安装) printf '%s' "$UI_WARNING" ;;
        *) printf '%s' "$UI_ERROR" ;;
    esac
}

ui_ok() {
    printf '%s%s%s\n' "$UI_SUCCESS" "$1" "$UI_RESET"
}

ui_warn() {
    printf '%s警告：%s%s\n' "$UI_WARNING" "$1" "$UI_RESET" >&2
}

ui_error() {
    printf '%s错误：%s%s\n' "$UI_ERROR" "$1" "$UI_RESET" >&2
}

ui_wait_key() {
    printf '%s按任意键继续...%s' "$UI_SECONDARY" "$UI_RESET"
    read_key || return 1
    printf '\n'
}

# Last updated: 2026-09-11 19:00
