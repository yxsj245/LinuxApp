#!/bin/sh

lifecycle_status() {
    lifecycle_path=$1
    if [ ! -f "$lifecycle_path" ]; then
        printf '异常|未知|模块脚本不存在\n'
        return 1
    fi
    sh "$lifecycle_path" status
}

lifecycle_action() {
    lifecycle_path=$1
    lifecycle_type=$2
    lifecycle_action_name=$3
    case "$lifecycle_type:$lifecycle_action_name" in
        language:start|language:stop|language:update|language:status)
            ui_error '语言模块只支持安装和卸载。'
            return 2
            ;;
    esac
    sh "$lifecycle_path" "$lifecycle_action_name"
}

# Last updated: 2026-09-11 19:00
