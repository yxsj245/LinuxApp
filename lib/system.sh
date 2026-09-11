#!/bin/sh

system_hostname() {
    hostname 2>/dev/null || uname -n 2>/dev/null || printf '未知\n'
}

system_distribution() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s\n' "${PRETTY_NAME:-${NAME:-未知系统}}"
    else
        printf '%s\n' '未知发行版'
    fi
}

system_kernel() {
    uname -sr 2>/dev/null || printf '未知内核\n'
}

system_architecture() {
    uname -m 2>/dev/null || printf '未知架构\n'
}

system_user() {
    id -un 2>/dev/null || printf '%s\n' "${USER:-未知用户}"
}

# Last updated: 2026-09-11 19:00
