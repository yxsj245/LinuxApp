#!/bin/sh

# 统一远程脚本地址。部署时可以通过环境变量覆盖。
LINUXAPP_BASE_URL=${LINUXAPP_BASE_URL:-https://linuxapp.xiaozhuhouses.asia/}
LINUXAPP_CACHE_TTL=${LINUXAPP_CACHE_TTL:-3600}
LINUXAPP_CONNECT_TIMEOUT=${LINUXAPP_CONNECT_TIMEOUT:-10}

# 语言模块的镜像地址默认值定义在 lib/lang.sh，可用环境变量覆盖。
# 需要在本文件中定制时，请取消对应注释并按需修改；这些变量必须导出才能传递给模块子进程。
# LINUXAPP_LANG_JAVA_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/Adoptium
# LINUXAPP_LANG_ADOPTIUM_API=https://api.adoptium.net
# LINUXAPP_LANG_NODE_MIRROR=https://registry.npmmirror.com/-/binary/node
# LINUXAPP_LANG_NODE_MIRROR_ALT=https://mirrors.huaweicloud.com/nodejs
# LINUXAPP_LANG_NODE_OFFICIAL=https://nodejs.org/dist
# LINUXAPP_LANG_GO_MIRROR=https://mirrors.aliyun.com/golang
# LINUXAPP_LANG_GO_OFFICIAL=https://go.dev
# LINUXAPP_LANG_GO_OFFICIAL_CN=https://golang.google.cn
# LINUXAPP_LANG_RUST_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/rustup
# LINUXAPP_LANG_RUST_OFFICIAL=https://static.rust-lang.org
# export LINUXAPP_LANG_JAVA_MIRROR LINUXAPP_LANG_ADOPTIUM_API
# export LINUXAPP_LANG_NODE_MIRROR LINUXAPP_LANG_NODE_MIRROR_ALT LINUXAPP_LANG_NODE_OFFICIAL
# export LINUXAPP_LANG_GO_MIRROR LINUXAPP_LANG_GO_OFFICIAL LINUXAPP_LANG_GO_OFFICIAL_CN
# export LINUXAPP_LANG_RUST_MIRROR LINUXAPP_LANG_RUST_OFFICIAL

# 返回指定脚本的单独地址；没有覆盖时返回空字符串。
linuxapp_script_override_url() {
    case "$1" in
        # 在此为单个脚本返回独立地址，例如：
        # modules/software/example/module.sh) printf '%s\n' 'https://example.com/linuxapp/example-module.sh' ;;
        *) return 0 ;;
    esac
}

# Last updated: 2026-09-12 04:40
