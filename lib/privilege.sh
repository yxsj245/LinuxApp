#!/bin/sh

run_with_privilege() {
    if [ "$(id -u 2>/dev/null)" = 0 ]; then
        "$@"
        return $?
    fi
    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
        return $?
    fi
    ui_error '当前动作需要 root 权限，但系统中没有 sudo。'
    return 1
}

# Last updated: 2026-09-11 19:00
