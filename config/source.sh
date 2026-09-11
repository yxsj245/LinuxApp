#!/bin/sh

# 统一远程脚本地址。部署时可以通过环境变量覆盖。
LINUXAPP_BASE_URL=${LINUXAPP_BASE_URL:-https://linuxapp.xiaozhuhouses.asia/}
LINUXAPP_CACHE_TTL=${LINUXAPP_CACHE_TTL:-3600}
LINUXAPP_CONNECT_TIMEOUT=${LINUXAPP_CONNECT_TIMEOUT:-10}

# 返回指定脚本的单独地址；没有覆盖时返回空字符串。
linuxapp_script_override_url() {
    case "$1" in
        # 在此为单个脚本返回独立地址，例如：
        # modules/software/example/module.sh) printf '%s\n' 'https://example.com/linuxapp/example-module.sh' ;;
        *) return 0 ;;
    esac
}

# Last updated: 2026-09-11 21:08
