#!/bin/sh

# 探测模块自报的可选动作。语言模块通过 capabilities 动作声明是否支持切换版本、更新等能力。
lifecycle_capabilities() {
    lifecycle_cap_path=$1
    [ -f "$lifecycle_cap_path" ] || return 1
    sh "$lifecycle_cap_path" capabilities 2>/dev/null
}

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
        language:start|language:stop)
            ui_error '语言模块不支持启动和停止。'
            return 2
            ;;
    esac
    sh "$lifecycle_path" "$lifecycle_action_name"
}

# Last updated: 2026-09-12 04:40
