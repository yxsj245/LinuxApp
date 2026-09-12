#!/bin/sh

# 统一脚本来源地址：入口在同步阶段用它把全部脚本取回本地副本，部署时可以用环境变量覆盖。
LINUXAPP_BASE_URL=${LINUXAPP_BASE_URL:-https://linuxapp.xiaozhuhouses.asia/}
# 本地脚本副本的有效期（秒），默认 1 小时：有效期内入口直接使用本地副本，不再联网。
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

# Last updated: 2026-09-12 09:34
