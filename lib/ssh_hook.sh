#!/bin/sh

SSH_HOOK_START='# >>> linuxapp ssh hook >>>'
SSH_HOOK_END='# <<< linuxapp ssh hook <<<'

ssh_hook_profile() {
    if [ -n "${LINUXAPP_SSH_PROFILE:-}" ]; then
        printf '%s\n' "$LINUXAPP_SSH_PROFILE"
    elif [ -n "${HOME:-}" ]; then
        printf '%s/.profile\n' "$HOME"
    else
        printf '%s\n' '.profile'
    fi
}

ssh_hook_install() {
    profile_path=$(ssh_hook_profile)
    hook_path=$LINUXAPP_ROOT/main.sh
    mkdir -p "$(dirname "$profile_path")" 2>/dev/null || {
        ui_error "无法创建用户配置目录：$(dirname "$profile_path")"
        return 1
    }
    if [ -f "$profile_path" ] && grep -F "$SSH_HOOK_START" "$profile_path" >/dev/null 2>&1; then
        ui_warn 'SSH 登录钩子已经存在，未重复写入。'
        return 0
    fi
    {
        printf '\n%s\n' "$SSH_HOOK_START"
        # shellcheck disable=SC2016
        printf '%s\n' 'if [ -n "${SSH_CONNECTION:-}" ] && [ -t 0 ] && [ -t 1 ]; then'
        # shellcheck disable=SC2016
        printf '%s\n' '    if [ "${LINUXAPP_SSH_HOOK_ACTIVE:-0}" != 1 ]; then'
        printf '%s\n' '        export LINUXAPP_SSH_HOOK_ACTIVE=1'
        printf '        sh "%s"\n' "$hook_path"
        printf '%s\n' '    fi'
        printf '%s\n' 'fi'
        printf '%s\n' "$SSH_HOOK_END"
    } >> "$profile_path" || {
        ui_error "无法写入 SSH 配置：$profile_path"
        return 1
    }
    ui_ok "SSH 登录钩子已写入：$profile_path"
}

ssh_hook_remove() {
    profile_path=$(ssh_hook_profile)
    [ -f "$profile_path" ] || {
        ui_warn '未找到用户配置文件，未执行删除。'
        return 0
    }
    grep -F "$SSH_HOOK_START" "$profile_path" >/dev/null 2>&1 || {
        ui_warn '未找到 LinuxApp SSH 登录钩子。'
        return 0
    }
    tmp_profile="$profile_path.tmp.$$"
    awk -v start="$SSH_HOOK_START" -v end="$SSH_HOOK_END" '
        $0 == start { in_block = 1; next }
        $0 == end { in_block = 0; next }
        !in_block { print }
    ' "$profile_path" > "$tmp_profile" || {
        rm -f "$tmp_profile"
        ui_error "无法读取 SSH 配置：$profile_path"
        return 1
    }
    mv "$tmp_profile" "$profile_path" || {
        rm -f "$tmp_profile"
        ui_error "无法更新 SSH 配置：$profile_path"
        return 1
    }
    ui_ok "SSH 登录钩子已移除：$profile_path"
}

# Last updated: 2026-09-11 19:00
