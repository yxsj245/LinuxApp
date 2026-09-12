#!/bin/sh

# LinuxApp 运行时数据目录：模块状态、日志等写入这里，默认沿用 XDG 缓存目录（~/.cache/linuxapp），
# 可用 XDG_CACHE_HOME 覆盖，最终路径由入口导出为 LINUXAPP_STATE_DIR。
# 脚本本身不做缓存：入口在同步阶段就把全部脚本取回本地，运行期只读本地文件。

state_root() {
    if [ -n "${XDG_CACHE_HOME:-}" ]; then
        printf '%s/linuxapp\n' "$XDG_CACHE_HOME"
    else
        printf '%s/.cache/linuxapp\n' "${HOME:-.}"
    fi
}

state_dir() {
    printf '%s/state\n' "$(state_root)"
}

# Last updated: 2026-09-12 09:34
