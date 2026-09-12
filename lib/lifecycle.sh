#!/bin/sh

# 探测模块自报的可选动作。语言模块通过 capabilities 动作声明是否支持切换版本、更新等能力。
lifecycle_capabilities() {
    lifecycle_cap_path=$1
    [ -f "$lifecycle_cap_path" ] || return 1
    sh "$lifecycle_cap_path" capabilities 2>/dev/null
}

# 探测软件模块按当前状态自报的附加动作（可选动作 extras，每行「动作键|中文名」）。
# 与 capabilities 的区别：capabilities 是静态能力声明，extras 会随模块状态变化，
# 例如只在服务异常时才出现的「回滚」项。该动作必须是只读且快速的，框架每次渲染菜单都会调用。
lifecycle_extras() {
    lifecycle_ex_path=$1
    [ -f "$lifecycle_ex_path" ] || return 1
    sh "$lifecycle_ex_path" extras 2>/dev/null
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

# Last updated: 2026-09-12 06:10
