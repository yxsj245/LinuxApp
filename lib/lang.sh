#!/bin/sh
# shellcheck disable=SC2016,SC2034,SC2094

# LinuxApp 语言模块共享库。
# 提供安装根目录、终端交互、安装源选择、下载校验、安全解包、版本比较与激活、
# 环境变量注入等通用能力，供 modules/language/*/module.sh 复用。
#
# 约定：
# 1. 只使用 POSIX sh 语法，不依赖 Bash 专有特性。
# 2. 面向用户的即时提示统一写 /dev/tty。框架通过命令替换捕获模块的标准输出和标准错误，
#    若提示写标准输出，用户会在操作结束后才看到内容，交互过程会像卡住一样没有任何反馈。
# 3. 机器可读输出（status、versions、capabilities）仍然写标准输出，保持框架解析能力。

# ---------------------------------------------------------------- 默认配置

# 各语言的镜像地址与官方地址都可以用环境变量覆盖，便于替换为私有镜像。
LINUXAPP_LANG_ADOPTIUM_API=${LINUXAPP_LANG_ADOPTIUM_API:-https://api.adoptium.net}
LINUXAPP_LANG_JAVA_MIRROR=${LINUXAPP_LANG_JAVA_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/Adoptium}

LINUXAPP_LANG_NODE_OFFICIAL=${LINUXAPP_LANG_NODE_OFFICIAL:-https://nodejs.org/dist}
LINUXAPP_LANG_NODE_MIRROR=${LINUXAPP_LANG_NODE_MIRROR:-https://registry.npmmirror.com/-/binary/node}
LINUXAPP_LANG_NODE_MIRROR_ALT=${LINUXAPP_LANG_NODE_MIRROR_ALT:-https://mirrors.huaweicloud.com/nodejs}

LINUXAPP_LANG_GO_OFFICIAL=${LINUXAPP_LANG_GO_OFFICIAL:-https://go.dev}
LINUXAPP_LANG_GO_OFFICIAL_CN=${LINUXAPP_LANG_GO_OFFICIAL_CN:-https://golang.google.cn}
LINUXAPP_LANG_GO_MIRROR=${LINUXAPP_LANG_GO_MIRROR:-https://mirrors.aliyun.com/golang}

LINUXAPP_LANG_RUST_OFFICIAL=${LINUXAPP_LANG_RUST_OFFICIAL:-https://static.rust-lang.org}
LINUXAPP_LANG_RUST_MIRROR=${LINUXAPP_LANG_RUST_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/rustup}
LINUXAPP_LANG_RUST_MIRROR_ALT=${LINUXAPP_LANG_RUST_MIRROR_ALT:-https://mirrors.ustc.edu.cn/rust-static}

# 生态加速地址，仅在用户明确同意时写入用户配置或环境文件。
LINUXAPP_LANG_GO_GOPROXY=${LINUXAPP_LANG_GO_GOPROXY:-https://goproxy.cn,direct}
LINUXAPP_LANG_NPM_REGISTRY=${LINUXAPP_LANG_NPM_REGISTRY:-https://registry.npmmirror.com}
LINUXAPP_LANG_CARGO_MIRROR=${LINUXAPP_LANG_CARGO_MIRROR:-sparse+https://mirrors.tuna.tsinghua.edu.cn/crates.io-index/}

LINUXAPP_LANG_CONNECT_TIMEOUT=${LINUXAPP_LANG_CONNECT_TIMEOUT:-15}
LINUXAPP_LANG_MARKER='linuxapp language env'
LINUXAPP_NPM_MARKER='linuxapp npm mirror'
LINUXAPP_CARGO_MARKER='linuxapp cargo mirror'
# 命令包装脚本的识别标记，用于安全清理（见 lang_bin_wrapper_is_ours）。
LINUXAPP_LANG_WRAPPER_MARK='linuxapp-lang-wrapper'

# ---------------------------------------------------------------- 终端输出

lang_has_tty() {
    # /dev/tty 的权限位始终是可读可写，但进程没有控制终端时打开会失败，
    # 因此必须真实尝试打开，不能只用 -r / -w 判断。
    if (exec 9> /dev/tty) 2>/dev/null; then
        exec 9>&-
        return 0
    fi
    return 1
}

# 输出一行提示。有终端时直接写终端，避免被框架的命令替换吞掉。
lang_out() {
    if lang_has_tty && printf '%s\n' "$1" > /dev/tty 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$1"
}

# 输出不带换行的提示，用于等待用户输入。
lang_out_raw() {
    if lang_has_tty && printf '%s' "$1" > /dev/tty 2>/dev/null; then
        return 0
    fi
    printf '%s' "$1"
}

lang_info() {
    lang_out "[信息] $1"
}

lang_ok() {
    lang_out "[完成] $1"
}

lang_warn() {
    lang_out "[警告] $1"
}

lang_fail() {
    lang_out "[错误] $1"
}

# ---------------------------------------------------------------- 终端交互

# 读取一行输入，结果写入 LANG_REPLY。优先读取终端，无终端时读取标准输入。
lang_read_line() {
    LANG_REPLY=''
    if lang_has_tty; then
        if IFS= read -r LANG_REPLY < /dev/tty; then
            return 0
        fi
        return 1
    fi
    if IFS= read -r LANG_REPLY; then
        return 0
    fi
    return 1
}

# 丢弃终端输入缓冲区中残留的按键。
# 框架菜单使用单键读取，用户习惯性多按的回车会残留到后续询问里，这里在开始询问前清理一次。
lang_flush_input() {
    lang_has_tty || return 0
    lang_fi_saved=$(stty -g < /dev/tty 2>/dev/null) || return 0
    if ! stty -icanon min 0 time 0 < /dev/tty 2>/dev/null; then
        stty "$lang_fi_saved" < /dev/tty 2>/dev/null || true
        return 0
    fi
    lang_fi_count=0
    while [ "$lang_fi_count" -lt 32 ]; do
        lang_fi_bytes=$(dd if=/dev/tty bs=1 count=1 2>/dev/null | wc -c | tr -d ' ')
        [ -n "$lang_fi_bytes" ] || break
        [ "$lang_fi_bytes" -gt 0 ] || break
        lang_fi_count=$((lang_fi_count + 1))
    done
    stty "$lang_fi_saved" < /dev/tty 2>/dev/null || true
    return 0
}

# 确认提示：$1 提示语，$2 默认值（y 或 n）。返回 0 表示确认。
lang_confirm() {
    lang_cf_prompt=$1
    lang_cf_default=${2:-n}
    if [ "${LINUXAPP_LANG_YES:-0}" = 1 ]; then
        lang_out "$lang_cf_prompt（已按自动化模式确认）"
        return 0
    fi
    case "$lang_cf_default" in
        y|Y) lang_cf_hint='[Y/n]' ;;
        *) lang_cf_hint='[y/N]' ;;
    esac
    while :; do
        lang_out_raw "$lang_cf_prompt $lang_cf_hint "
        if ! lang_read_line; then
            lang_warn '当前环境无法读取输入，已取消该操作。'
            return 1
        fi
        case "$LANG_REPLY" in
            '')
                case "$lang_cf_default" in
                    y|Y) return 0 ;;
                    *) return 1 ;;
                esac
                ;;
            y|Y|yes|YES|是) return 0 ;;
            n|N|no|NO|否) return 1 ;;
            *) lang_warn '请输入 y 或 n。' ;;
        esac
    done
}

# 数字选择：$1 提示语，$2 候选数量。结果写入 LANG_CHOICE（从 1 开始）。
lang_choose_number() {
    lang_cn_prompt=$1
    lang_cn_count=$2
    lang_flush_input
    while :; do
        lang_out_raw "$lang_cn_prompt [1-$lang_cn_count]: "
        if ! lang_read_line; then
            lang_warn '当前环境无法读取输入。'
            return 1
        fi
        case "$LANG_REPLY" in
            ''|*[!0-9]*)
                lang_warn '请输入列表中的数字编号。'
                ;;
            *)
                if [ "$LANG_REPLY" -ge 1 ] && [ "$LANG_REPLY" -le "$lang_cn_count" ]; then
                    LANG_CHOICE=$LANG_REPLY
                    return 0
                fi
                lang_warn '编号超出范围，请重新输入。'
                ;;
        esac
    done
}

# 自由输入：$1 提示语。结果写入 LANG_REPLY。
lang_read_value() {
    lang_flush_input
    lang_out_raw "$1"
    lang_read_line || return 1
    return 0
}

# 选择安装源，结果写入 LANG_SOURCE（mirror 或 official）。
# 每次安装或更新都会询问，不写入任何持久化的源偏好。
lang_source_choose() {
    if [ -n "${LINUXAPP_LANG_SOURCE:-}" ]; then
        case "$LINUXAPP_LANG_SOURCE" in
            mirror|official)
                LANG_SOURCE=$LINUXAPP_LANG_SOURCE
                return 0
                ;;
            *)
                lang_fail "环境变量 LINUXAPP_LANG_SOURCE 取值无效：$LINUXAPP_LANG_SOURCE（应为 mirror 或 official）。"
                return 1
                ;;
        esac
    fi
    if ! lang_has_tty; then
        lang_fail '当前不是交互式终端，请通过 LINUXAPP_LANG_SOURCE=mirror|official 指定安装源。'
        return 1
    fi
    lang_out '请选择安装源：'
    lang_out '  1. 国内镜像（国内网络速度更快）'
    lang_out '  2. 官方源（上游原始地址，国内网络可能较慢）'
    lang_choose_number '请输入编号' 2 || return 1
    case "$LANG_CHOICE" in
        1) LANG_SOURCE=mirror ;;
        *) LANG_SOURCE=official ;;
    esac
    return 0
}

# ---------------------------------------------------------------- 目录与路径

# 安装根目录：环境变量优先，其次按当前用户权限选择。
lang_default_root() {
    if [ -n "${LINUXAPP_LANG_ROOT:-}" ]; then
        printf '%s\n' "$LINUXAPP_LANG_ROOT"
        return 0
    fi
    if [ "$(id -u 2>/dev/null)" = 0 ]; then
        printf '%s\n' '/opt/linuxapp/lang'
        return 0
    fi
    lang_dr_data=${XDG_DATA_HOME:-}
    [ -n "$lang_dr_data" ] || lang_dr_data=${HOME:-.}/.local/share
    printf '%s\n' "$lang_dr_data/linuxapp/lang"
}

# 环境变量注入的启动文件列表。
# 只写 /etc/profile.d 时，交互式非登录 shell（直接新开终端、部分面板的控制台）
# 不会加载它，会出现“装好了但新终端找不到命令”的问题，因此这里同时覆盖两类：
#   root     ：/etc/profile.d/linuxapp-lang.sh（登录 shell）
#              /etc/bash.bashrc 或 /etc/bashrc（交互式非登录 shell）
#   普通用户 ：~/.profile（登录 shell）、~/.bashrc（交互式非登录 shell）
# 系统安装了 zsh 时再补上对应的 zsh 启动文件。
lang_shell_rc_files() {
    if [ -n "${LINUXAPP_LANG_PROFILE_FILE:-}" ]; then
        printf '%s\n' "$LINUXAPP_LANG_PROFILE_FILE"
        return 0
    fi
    if [ "$(id -u 2>/dev/null)" = 0 ]; then
        printf '%s\n' '/etc/profile.d/linuxapp-lang.sh'
        if [ -f /etc/bash.bashrc ]; then
            printf '%s\n' '/etc/bash.bashrc'
        elif [ -f /etc/bashrc ]; then
            printf '%s\n' '/etc/bashrc'
        fi
        if [ -f /etc/zsh/zshrc ]; then
            printf '%s\n' '/etc/zsh/zshrc'
        elif [ -f /etc/zshrc ]; then
            printf '%s\n' '/etc/zshrc'
        fi
        return 0
    fi
    printf '%s\n' "${HOME:-.}/.profile"
    [ -f "${HOME:-.}/.bashrc" ] && printf '%s\n' "${HOME:-.}/.bashrc"
    [ -f "${HOME:-.}/.zshrc" ] && printf '%s\n' "${HOME:-.}/.zshrc"
    return 0
}

# 环境变量注入的主要（第一个）目标文件。
lang_profile_file() {
    lang_pf_first=$(lang_shell_rc_files | sed -n '1p')
    if [ -z "$lang_pf_first" ]; then
        printf '%s\n' '/etc/profile.d/linuxapp-lang.sh'
        return 0
    fi
    printf '%s\n' "$lang_pf_first"
}

# 语言环境目录，例如 <root>/java。
lang_home() {
    printf '%s/%s\n' "$(lang_default_root)" "$1"
}

# 架构标识：返回 x64、arm64 或 armv7l，供各语言映射官方命名。
lang_arch_kind() {
    case "$(uname -m 2>/dev/null)" in
        x86_64|amd64) printf '%s\n' 'x64' ;;
        aarch64|arm64) printf '%s\n' 'arm64' ;;
        armv7l|armv7) printf '%s\n' 'armv7l' ;;
        *) return 1 ;;
    esac
}

# 检查命令是否存在，缺少时给出中文提示。参数为命令名列表。
lang_require_commands() {
    lang_rc_missing=''
    for lang_rc_cmd in "$@"; do
        if ! command -v "$lang_rc_cmd" >/dev/null 2>&1; then
            lang_rc_missing="$lang_rc_missing $lang_rc_cmd"
        fi
    done
    if [ -n "$lang_rc_missing" ]; then
        lang_fail "缺少必需的命令：$lang_rc_missing。请先安装后再执行本操作。"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- 版本处理

# 版本比较：$1 大于 $2 时返回 0。忽略前缀 v 与 +、-、_ 之后的后缀。
lang_version_gt() {
    lang_vg_a=$(printf '%s' "$1" | sed -e 's/^[vV]//' -e 's/[-+_].*$//')
    lang_vg_b=$(printf '%s' "$2" | sed -e 's/^[vV]//' -e 's/[-+_].*$//')
    [ "$lang_vg_a" = "$lang_vg_b" ] && return 1
    lang_vg_result=$(awk -v a="$lang_vg_a" -v b="$lang_vg_b" 'BEGIN {
        na = split(a, x, ".");
        nb = split(b, y, ".");
        n = (na > nb) ? na : nb;
        for (i = 1; i <= n; i++) {
            xi = (i <= na && x[i] ~ /^[0-9]+$/) ? x[i] + 0 : 0;
            yi = (i <= nb && y[i] ~ /^[0-9]+$/) ? y[i] + 0 : 0;
            if (xi > yi) { print 1; exit }
            if (xi < yi) { print 0; exit }
        }
        print 0;
    }')
    [ "$lang_vg_result" = 1 ]
}

# 从标准输入读取版本列表，按版本号从新到旧输出。
lang_sort_versions_desc() {
    awk '{
        line = $0;
        key = line;
        sub(/^[vV]/, "", key);
        n = split(key, p, ".");
        value = 0;
        for (i = 1; i <= 4; i++) {
            v = (i <= n && p[i] ~ /^[0-9]+$/) ? p[i] + 0 : 0;
            value = value * 1000 + v;
        }
        printf "%015d %s\n", value, line;
    }' | sort -rn | awk '{ $1 = ""; sub(/^ /, ""); print }'
}

# 从标准输入读取版本列表，输出与 $1 同大版本的最新版本。
lang_latest_in_major() {
    awk -F. -v m="$1" '{
        major = $1;
        sub(/^[vV]/, "", major);
        if (major == m) print;
    }' | lang_sort_versions_desc | sed -n '1p'
}

# 从标准输入读取大版本列表，输出大于 $1 的最小大版本。
lang_next_major() {
    awk -v c="$1" '{
        v = $0;
        gsub(/[^0-9]/, "", v);
        if (v != "" && v + 0 > c + 0) print v + 0;
    }' | sort -n | sed -n '1p'
}

# 列出版本目录下已安装的版本（从新到旧）。
# 跳过 current 链接与隐藏目录（如安装过程中的 .staging.<pid> 残留）。
lang_list_versions() {
    lang_lv_home=$(lang_home "$1")
    [ -d "$lang_lv_home" ] || return 0
    for lang_lv_item in "$lang_lv_home"/*; do
        [ -d "$lang_lv_item" ] || continue
        lang_lv_name=${lang_lv_item##*/}
        case "$lang_lv_name" in
            current|.*) continue ;;
        esac
        printf '%s\n' "$lang_lv_name"
    done | lang_sort_versions_desc
}

# 读取当前激活的版本，失败返回 1。
lang_current_version() {
    lang_cv_link=$(lang_home "$1")/current
    [ -e "$lang_cv_link" ] || return 1
    lang_cv_target=$(readlink "$lang_cv_link" 2>/dev/null) || lang_cv_target=''
    [ -n "$lang_cv_target" ] || return 1
    printf '%s\n' "${lang_cv_target##*/}"
}

# 判断某版本是否已安装。
lang_version_installed() {
    [ -d "$(lang_home "$1")/$2" ]
}

# 激活指定版本，写入 current 链接。
lang_link_current() {
    lang_lc_home=$(lang_home "$1")
    lang_lc_target=$2
    if [ ! -d "$lang_lc_home/$lang_lc_target" ]; then
        lang_fail "版本目录不存在：$lang_lc_home/$lang_lc_target"
        return 1
    fi
    # 先删除旧链接再创建，避免 ln -sf 在目标是目录时把新链接建到目录里面。
    rm -f "$lang_lc_home/current" 2>/dev/null || true
    if ! ln -s "$lang_lc_target" "$lang_lc_home/current" 2>/dev/null; then
        lang_fail "无法写入当前版本链接：$lang_lc_home/current"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- 多版本卸载

# 选择要卸载的版本。
# $1 显示名（如 Node.js、JDK），$2 版本列表（换行分隔，从新到旧），$3 当前激活版本（可空）。
# 结果：LANG_UNINSTALL_SCOPE=one 时 LANG_UNINSTALL_VERSION 为选中版本；
#       LANG_UNINSTALL_SCOPE=all 表示卸载全部版本。
# 返回 0 表示已选定，1 表示取消或输入不可用（此时由调用方提示“已取消卸载”）。
# 自动化：环境变量 LINUXAPP_LANG_UNINSTALL_VERSION 可指定版本号或 all，跳过交互。
lang_uninstall_choose() {
    lang_uc_label=$1
    lang_uc_versions=$2
    lang_uc_current=${3:-}
    lang_uc_count=$(printf '%s\n' "$lang_uc_versions" | grep -c .)

    lang_uc_wanted=${LINUXAPP_LANG_UNINSTALL_VERSION:-}
    if [ -n "$lang_uc_wanted" ]; then
        case "$lang_uc_wanted" in
            a|A|all|ALL)
                LANG_UNINSTALL_SCOPE=all
                LANG_UNINSTALL_VERSION=''
                lang_out '已按环境变量 LINUXAPP_LANG_UNINSTALL_VERSION 选择卸载全部版本。'
                return 0
                ;;
        esac
        if printf '%s\n' "$lang_uc_versions" | grep -qx "$lang_uc_wanted"; then
            LANG_UNINSTALL_SCOPE=one
            LANG_UNINSTALL_VERSION=$lang_uc_wanted
            lang_out "已按环境变量 LINUXAPP_LANG_UNINSTALL_VERSION 选择卸载版本：$lang_uc_wanted"
            return 0
        fi
        lang_fail "环境变量指定的版本未安装：$lang_uc_wanted。已安装：$(printf '%s' "$lang_uc_versions" | tr '\n' ' ')"
        return 1
    fi

    if ! lang_has_tty; then
        lang_fail '当前不是交互式终端，请设置环境变量 LINUXAPP_LANG_UNINSTALL_VERSION=<版本号|all> 后重试。'
        return 1
    fi

    lang_out "已安装的 $lang_uc_label："
    lang_uc_index=0
    for lang_uc_version in $lang_uc_versions; do
        lang_uc_index=$((lang_uc_index + 1))
        lang_uc_mark=''
        if [ "$lang_uc_version" = "$lang_uc_current" ]; then
            lang_uc_mark='（当前）'
        fi
        lang_out "  $lang_uc_index. $lang_uc_version$lang_uc_mark"
    done
    lang_out '  a. 卸载全部版本'
    lang_out '  0. 取消'
    lang_flush_input
    lang_uc_try=0
    while [ "$lang_uc_try" -lt 5 ]; do
        lang_uc_try=$((lang_uc_try + 1))
        lang_out_raw '请输入编号、a（全部）或 0（取消）：'
        if ! lang_read_line; then
            lang_warn '当前环境无法读取输入，已取消卸载。'
            return 1
        fi
        lang_uc_reply=$(printf '%s' "$LANG_REPLY" | tr -d ' \t')
        case "$lang_uc_reply" in
            ''|0)
                return 1
                ;;
            a|A)
                LANG_UNINSTALL_SCOPE=all
                LANG_UNINSTALL_VERSION=''
                return 0
                ;;
            *[!0-9]*)
                lang_warn '请输入列表中的编号、a（全部）或 0（取消）。'
                ;;
            *)
                if [ "$lang_uc_reply" -ge 1 ] && [ "$lang_uc_reply" -le "$lang_uc_count" ]; then
                    LANG_UNINSTALL_SCOPE=one
                    LANG_UNINSTALL_VERSION=$(printf '%s\n' "$lang_uc_versions" | sed -n "${lang_uc_reply}p")
                    return 0
                fi
                lang_warn '编号超出范围，请重新输入。'
                ;;
        esac
    done
    lang_warn '多次输入无效，已取消卸载。'
    return 1
}

# 删除指定版本目录。$1 语言键，其后为版本号列表。
# 只删除语言安装目录下的直接子目录，版本名含路径分隔符或隐藏目录时跳过，避免误删。
# 全部删除成功返回 0，任一失败返回 1。
lang_remove_versions() {
    lang_rv_lang=$1
    shift
    lang_rv_home=$(lang_home "$lang_rv_lang")
    lang_rv_status=0
    for lang_rv_version in "$@"; do
        [ -n "$lang_rv_version" ] || continue
        case "$lang_rv_version" in
            .*|*/*)
                lang_warn "已跳过非法版本名：$lang_rv_version"
                lang_rv_status=1
                continue
                ;;
        esac
        [ -d "$lang_rv_home/$lang_rv_version" ] || continue
        if ! rm -rf "$lang_rv_home/${lang_rv_version:?}" 2>/dev/null; then
            lang_fail "删除失败：$lang_rv_home/$lang_rv_version（请检查权限）"
            lang_rv_status=1
        fi
    done
    return "$lang_rv_status"
}

# 卸载某个版本后重新激活剩余版本中最新的一个。
# $1 语言键。返回 0 表示已激活并写入 LANG_ACTIVATED_VERSION，1 表示没有剩余版本或激活失败。
lang_reactivate_latest() {
    lang_ral_lang=$1
    lang_ral_versions=$(lang_list_versions "$lang_ral_lang")
    [ -n "$lang_ral_versions" ] || return 1
    lang_ral_target=$(printf '%s\n' "$lang_ral_versions" | sed -n '1p')
    [ -n "$lang_ral_target" ] || return 1
    lang_link_current "$lang_ral_lang" "$lang_ral_target" || return 1
    LANG_ACTIVATED_VERSION=$lang_ral_target
    return 0
}

# ---------------------------------------------------------------- 下载与校验

# 下载 $1 到 $2。成功返回 0。
lang_download() {
    lang_dl_url=$1
    lang_dl_target=$2
    lang_dl_tmp="$lang_dl_target.part.$$"
    mkdir -p "$(dirname "$lang_dl_target")" 2>/dev/null || return 1
    rm -f "$lang_dl_tmp" 2>/dev/null || true
    lang_info "开始下载：$lang_dl_url"
    lang_dl_status=1
    if command -v curl >/dev/null 2>&1; then
        if lang_has_tty; then
            curl -fL --progress-bar --connect-timeout "$LINUXAPP_LANG_CONNECT_TIMEOUT" \
                -o "$lang_dl_tmp" "$lang_dl_url" 2> /dev/tty
        else
            curl -fsSL --connect-timeout "$LINUXAPP_LANG_CONNECT_TIMEOUT" \
                -o "$lang_dl_tmp" "$lang_dl_url"
        fi
        lang_dl_status=$?
    elif command -v wget >/dev/null 2>&1; then
        if lang_has_tty; then
            wget -O "$lang_dl_tmp" "$lang_dl_url" 2> /dev/tty
        else
            wget -q -O "$lang_dl_tmp" "$lang_dl_url"
        fi
        lang_dl_status=$?
    else
        lang_fail '系统中找不到 curl 或 wget，无法下载。请先安装 curl 或 wget。'
        return 1
    fi
    if [ "$lang_dl_status" -ne 0 ] || [ ! -s "$lang_dl_tmp" ]; then
        rm -f "$lang_dl_tmp" 2>/dev/null || true
        return 1
    fi
    if ! mv "$lang_dl_tmp" "$lang_dl_target" 2>/dev/null; then
        rm -f "$lang_dl_tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}

# 计算文件 sha256，输出小写十六进制。
lang_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{ print $1 }'
        return 0
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{ print $1 }'
        return 0
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{ print $NF }'
        return 0
    fi
    return 1
}

# 校验文件 sha256：$1 文件，$2 期望值。
lang_verify_sha256() {
    lang_vs_file=$1
    lang_vs_expect=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    if [ -z "$lang_vs_expect" ]; then
        lang_fail '没有取到官方校验值，出于安全考虑已中止安装。'
        return 1
    fi
    lang_vs_actual=$(lang_sha256 "$lang_vs_file") || {
        lang_fail '系统缺少 sha256sum、shasum 或 openssl，无法校验下载文件。'
        return 1
    }
    lang_vs_actual=$(printf '%s' "$lang_vs_actual" | tr '[:upper:]' '[:lower:]')
    if [ "$lang_vs_actual" != "$lang_vs_expect" ]; then
        lang_fail "校验失败：期望 $lang_vs_expect，实际 $lang_vs_actual。"
        lang_fail '文件可能被篡改或镜像不完整，已中止安装。'
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- 缓存与索引

# 获取远端索引：$1 缓存文件名，$2 地址。成功时把内容写到标准输出。
# 网络不可用时回退到本地缓存，并明确提示内容可能不是最新。
lang_cache_fetch() {
    lang_cf_name=$1
    lang_cf_url=$2
    lang_cf_dir=$(lang_default_root)/cache
    lang_cf_file=$lang_cf_dir/$lang_cf_name
    lang_cf_tmp="$lang_cf_file.part.$$"
    mkdir -p "$lang_cf_dir" 2>/dev/null || true
    rm -f "$lang_cf_tmp" 2>/dev/null || true
    lang_cf_status=1
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "$LINUXAPP_LANG_CONNECT_TIMEOUT" \
            -o "$lang_cf_tmp" "$lang_cf_url" 2>/dev/null
        lang_cf_status=$?
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$lang_cf_tmp" "$lang_cf_url" 2>/dev/null
        lang_cf_status=$?
    fi
    if [ "$lang_cf_status" -eq 0 ] && [ -s "$lang_cf_tmp" ]; then
        if mv "$lang_cf_tmp" "$lang_cf_file" 2>/dev/null; then
            cat "$lang_cf_file"
            return 0
        fi
    fi
    rm -f "$lang_cf_tmp" 2>/dev/null || true
    if [ -s "$lang_cf_file" ]; then
        lang_warn '无法连接版本服务器，已改用本地缓存的版本列表（可能不是最新）。'
        cat "$lang_cf_file"
        return 0
    fi
    return 1
}

# 从 JSON 文件取第一个字符串字段值：$1 文件，$2 字段名。
lang_json_string() {
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | sed -n '1p'
}

# 从 JSON 文件取第一个数值字段值：$1 文件，$2 字段名。
lang_json_number() {
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$1" | sed -n '1p'
}

# ---------------------------------------------------------------- 解包

# 根据扩展名给出 tar 压缩参数。
lang_tar_flag() {
    case "$1" in
        *.tar.xz|*.txz) printf '%s\n' '-J' ;;
        *.tar.gz|*.tgz) printf '%s\n' '-z' ;;
        *.tar.bz2|*.tbz2) printf '%s\n' '-j' ;;
        *) printf '%s\n' '' ;;
    esac
}

# 列出归档内容，GNU tar 可自动识别压缩格式，失败时按扩展名重试。
lang_tar_list() {
    lang_tl_archive=$1
    if tar -tf "$lang_tl_archive" 2>/dev/null; then
        return 0
    fi
    lang_tl_flag=$(lang_tar_flag "$lang_tl_archive")
    [ -n "$lang_tl_flag" ] || return 1
    tar "$lang_tl_flag" -tf "$lang_tl_archive" 2>/dev/null
}

# 检查归档是否安全：拒绝绝对路径、上级目录逃逸。
lang_check_archive() {
    lang_ca_archive=$1
    lang_ca_list="${TMPDIR:-/tmp}/linuxapp-archive-list.$$"
    if ! lang_tar_list "$lang_ca_archive" > "$lang_ca_list" 2>/dev/null; then
        rm -f "$lang_ca_list" 2>/dev/null || true
        lang_fail "无法读取归档内容：$lang_ca_archive"
        return 1
    fi
    lang_ca_bad=''
    while IFS= read -r lang_ca_entry; do
        case "$lang_ca_entry" in
            /*|../*|*/../*|*/..|..)
                lang_ca_bad=$lang_ca_entry
                break
                ;;
        esac
    done < "$lang_ca_list"
    rm -f "$lang_ca_list" 2>/dev/null || true
    if [ -n "$lang_ca_bad" ]; then
        lang_fail "归档包含不安全的路径，已中止：$lang_ca_bad"
        return 1
    fi
    return 0
}

# 把目录内唯一的顶层目录内容上移一层，兼容不支持 --strip-components 的 tar。
lang_flatten_dir() {
    lang_fd_dir=$1
    lang_fd_count=0
    lang_fd_only=''
    for lang_fd_item in "$lang_fd_dir"/*; do
        [ -e "$lang_fd_item" ] || continue
        lang_fd_count=$((lang_fd_count + 1))
        lang_fd_only=$lang_fd_item
        [ "$lang_fd_count" -le 1 ] || break
    done
    if [ "$lang_fd_count" -ne 1 ] || [ ! -d "$lang_fd_only" ]; then
        lang_fail '归档结构异常：顶层不是单一目录。'
        return 1
    fi
    for lang_fd_item in "$lang_fd_only"/* "$lang_fd_only"/.[!.]*; do
        [ -e "$lang_fd_item" ] || continue
        if ! mv "$lang_fd_item" "$lang_fd_dir/" 2>/dev/null; then
            lang_fail "无法整理解包结果：$lang_fd_item"
            return 1
        fi
    done
    rmdir "$lang_fd_only" 2>/dev/null || true
    return 0
}

# 解包归档：$1 归档，$2 目标目录，$3 需要剥离的顶层目录层数。
lang_extract() {
    lang_ex_archive=$1
    lang_ex_dest=$2
    lang_ex_strip=${3:-0}
    mkdir -p "$lang_ex_dest" 2>/dev/null || return 1
    lang_ex_flag=$(lang_tar_flag "$lang_ex_archive")
    if [ "$lang_ex_strip" -gt 0 ] 2>/dev/null; then
        if tar -xf "$lang_ex_archive" -C "$lang_ex_dest" --strip-components="$lang_ex_strip" 2>/dev/null; then
            return 0
        fi
        if [ -n "$lang_ex_flag" ]; then
            if tar "$lang_ex_flag" -xf "$lang_ex_archive" -C "$lang_ex_dest" \
                --strip-components="$lang_ex_strip" 2>/dev/null; then
                return 0
            fi
        fi
        # 兜底：整包解包后手工上移唯一个顶层目录。
        if [ -n "$lang_ex_flag" ]; then
            tar "$lang_ex_flag" -xf "$lang_ex_archive" -C "$lang_ex_dest" 2>/dev/null || return 1
        else
            tar -xf "$lang_ex_archive" -C "$lang_ex_dest" 2>/dev/null || return 1
        fi
        lang_flatten_dir "$lang_ex_dest" || return 1
        return 0
    fi
    if tar -xf "$lang_ex_archive" -C "$lang_ex_dest" 2>/dev/null; then
        return 0
    fi
    [ -n "$lang_ex_flag" ] || return 1
    tar "$lang_ex_flag" -xf "$lang_ex_archive" -C "$lang_ex_dest" 2>/dev/null
}

# ---------------------------------------------------------------- 命令链接

# 各语言需要在 PATH 中暴露的核心命令。
lang_core_commands() {
    case "$1" in
        java) printf '%s\n' java javac jar javadoc javap jshell keytool ;;
        nodejs) printf '%s\n' node npm npx corepack ;;
        go) printf '%s\n' go gofmt ;;
        rust) printf '%s\n' rustup cargo rustc rustdoc rustfmt cargo-clippy clippy-driver ;;
        *) return 1 ;;
    esac
}

# 语言当前生效版本的命令目录。Rust 由 rustup 管理，命令位于 CARGO_HOME/bin。
lang_active_bin_dir() {
    case "$1" in
        rust) printf '%s/cargo/bin\n' "$(lang_default_root)" ;;
        *) printf '%s/%s/current/bin\n' "$(lang_default_root)" "$1" ;;
    esac
}

# 命令链接目录：root 使用 /usr/local/bin（所有 shell 的默认 PATH 都包含它），
# 普通用户使用 ~/.local/bin。
lang_bin_dir() {
    if [ -n "${LINUXAPP_LANG_BIN_DIR:-}" ]; then
        printf '%s\n' "$LINUXAPP_LANG_BIN_DIR"
        return 0
    fi
    if [ "$(id -u 2>/dev/null)" = 0 ]; then
        printf '%s\n' '/usr/local/bin'
        return 0
    fi
    printf '%s\n' "${HOME:-.}/.local/bin"
}

# 判断文件是否为指向安装根目录的链接（即由本程序创建）。
lang_bin_link_is_ours() {
    [ -L "$1" ] || return 1
    command -v readlink >/dev/null 2>&1 || return 1
    lang_blio_target=$(readlink "$1" 2>/dev/null) || return 1
    [ -n "$lang_blio_target" ] || return 1
    case "$lang_blio_target" in
        "$(lang_default_root)"/*) return 0 ;;
    esac
    return 1
}

# 创建或更新命令链接；遇到非本程序管理的同名文件时跳过并给出中文提示。
lang_bin_link_install() {
    lang_bli_dir=$1
    lang_bli_cmd=$2
    lang_bli_src=$3
    lang_bli_dst="$lang_bli_dir/$lang_bli_cmd"
    if [ -L "$lang_bli_dst" ]; then
        if ! lang_bin_link_is_ours "$lang_bli_dst"; then
            lang_warn "已存在同名命令链接 $lang_bli_dst，为不影响其他程序已跳过。"
            return 1
        fi
    elif [ -e "$lang_bli_dst" ]; then
        lang_warn "已存在同名命令 $lang_bli_dst（非本程序管理），已跳过；如需使用本程序的版本，请先自行处理后重试。"
        return 1
    fi
    if ! ln -sfn "$lang_bli_src" "$lang_bli_dst" 2>/dev/null; then
        lang_warn "无法创建命令链接：$lang_bli_dst"
        return 1
    fi
    return 0
}

# 判断文件是否为本程序生成的命令包装脚本。
# Rust 的命令是 rustup 代理，必须依赖 RUSTUP_HOME、CARGO_HOME 才能工作，
# 因此这类命令不建符号链接，而是写入带环境变量的包装脚本，保证任何 shell 都能直接调用。
lang_bin_wrapper_is_ours() {
    [ -f "$1" ] || return 1
    [ -L "$1" ] && return 1
    grep -qF "$LINUXAPP_LANG_WRAPPER_MARK" "$1" 2>/dev/null
}

# 写入命令包装脚本；遇到非本程序管理的同名文件时跳过并给出中文提示。
lang_bin_wrapper_install() {
    lang_bwi_dir=$1
    lang_bwi_cmd=$2
    lang_bwi_src=$3
    lang_bwi_dst="$lang_bwi_dir/$lang_bwi_cmd"
    if [ -L "$lang_bwi_dst" ]; then
        if ! lang_bin_link_is_ours "$lang_bwi_dst"; then
            lang_warn "已存在同名命令链接 $lang_bwi_dst，为不影响其他程序已跳过。"
            return 1
        fi
        rm -f "$lang_bwi_dst" 2>/dev/null || true
    elif [ -e "$lang_bwi_dst" ]; then
        if ! lang_bin_wrapper_is_ours "$lang_bwi_dst"; then
            lang_warn "已存在同名命令 $lang_bwi_dst（非本程序管理），已跳过；如需使用本程序的版本，请先自行处理后重试。"
            return 1
        fi
    fi
    lang_bwi_root=$(lang_default_root)
    lang_bwi_tmp="$lang_bwi_dst.linuxapp.$$"
    if ! {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' "# $LINUXAPP_LANG_WRAPPER_MARK：由 LinuxApp 语言模块生成，卸载时自动删除。"
        printf '%s\n' '# 作用：在未加载环境变量（如 ssh 单条命令、定时任务）的 shell 中也能直接使用该命令。'
        printf 'RUSTUP_HOME="%s/rust"\nexport RUSTUP_HOME\n' "$lang_bwi_root"
        printf 'CARGO_HOME="%s/cargo"\nexport CARGO_HOME\n' "$lang_bwi_root"
        printf 'exec "%s" "$@"\n' "$lang_bwi_src"
    } > "$lang_bwi_tmp" 2>/dev/null; then
        rm -f "$lang_bwi_tmp" 2>/dev/null || true
        lang_warn "无法创建命令包装：$lang_bwi_dst"
        return 1
    fi
    chmod 755 "$lang_bwi_tmp" 2>/dev/null || true
    if ! mv "$lang_bwi_tmp" "$lang_bwi_dst" 2>/dev/null; then
        rm -f "$lang_bwi_tmp" 2>/dev/null || true
        lang_warn "无法创建命令包装：$lang_bwi_dst"
        return 1
    fi
    return 0
}

# 删除本程序创建的命令链接或命令包装；不属于本程序的文件不动。
lang_bin_link_remove() {
    if lang_bin_link_is_ours "$1"; then
        rm -f "$1" 2>/dev/null || return 1
        return 0
    fi
    if lang_bin_wrapper_is_ours "$1"; then
        rm -f "$1" 2>/dev/null || return 1
    fi
    return 0
}

# 按当前安装状态同步命令链接：已激活的语言建立链接，未激活的清理链接。
# 该步骤只影响“命令能否直接调用”，失败不阻断安装（环境变量注入仍然有效）。
lang_bin_links_sync() {
    lang_bls_dir=$(lang_bin_dir)
    lang_bls_created=0
    lang_bls_skipped=0
    if ! mkdir -p "$lang_bls_dir" 2>/dev/null; then
        lang_warn "无法创建命令链接目录：$lang_bls_dir，已跳过命令链接。"
        LANG_BIN_CREATED=0
        LANG_BIN_SKIPPED=0
        return 0
    fi
    for lang_bls_name in java nodejs go rust; do
        lang_bls_bin=$(lang_active_bin_dir "$lang_bls_name")
        for lang_bls_cmd in $(lang_core_commands "$lang_bls_name"); do
            lang_bls_dst="$lang_bls_dir/$lang_bls_cmd"
            if [ -e "$lang_bls_bin/$lang_bls_cmd" ]; then
                lang_bls_ok=0
                case "$lang_bls_name" in
                    rust)
                        lang_bin_wrapper_install "$lang_bls_dir" "$lang_bls_cmd" "$lang_bls_bin/$lang_bls_cmd" && lang_bls_ok=1
                        ;;
                    *)
                        lang_bin_link_install "$lang_bls_dir" "$lang_bls_cmd" "$lang_bls_bin/$lang_bls_cmd" && lang_bls_ok=1
                        ;;
                esac
                if [ "$lang_bls_ok" -eq 1 ]; then
                    lang_bls_created=$((lang_bls_created + 1))
                else
                    lang_bls_skipped=$((lang_bls_skipped + 1))
                fi
            else
                lang_bin_link_remove "$lang_bls_dst" || true
            fi
        done
    done
    LANG_BIN_CREATED=$lang_bls_created
    LANG_BIN_SKIPPED=$lang_bls_skipped
    return 0
}

# ---------------------------------------------------------------- 环境注入

# 输出 PATH 前置语句：同一 shell 重复加载同一目录时不会重复叠加。
lang_env_path_expr() {
    printf 'case ":$PATH:" in *":%s:"*) ;; *) PATH="%s:$PATH"; export PATH ;; esac\n' "$1" "$1"
}

# 重新生成 <root>/env.sh，按当前已激活的版本导出环境变量。
lang_env_regenerate() {
    lang_er_root=$(lang_default_root)
    mkdir -p "$lang_er_root" 2>/dev/null || return 1
    lang_er_tmp="$lang_er_root/env.sh.tmp.$$"
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' '# 本文件由 LinuxApp 语言模块自动生成，手工修改会在下次安装、切换或更新时被覆盖。'
        if [ -e "$lang_er_root/java/current" ]; then
            printf 'JAVA_HOME="%s/java/current"\nexport JAVA_HOME\n' "$lang_er_root"
            lang_env_path_expr "$lang_er_root/java/current/bin"
        fi
        if [ -e "$lang_er_root/nodejs/current" ]; then
            lang_env_path_expr "$lang_er_root/nodejs/current/bin"
        fi
        if [ -e "$lang_er_root/go/current" ]; then
            printf 'GOROOT="%s/go/current"\nexport GOROOT\n' "$lang_er_root"
            lang_env_path_expr "$lang_er_root/go/current/bin"
            # 未显式设置 GOPATH 时使用默认工作区，并把 go install 的产物目录加入 PATH。
            printf 'GOPATH="${GOPATH:-$HOME/go}"\nexport GOPATH\n'
            printf 'case ":$PATH:" in *":$GOPATH/bin:"*) ;; *) PATH="$GOPATH/bin:$PATH"; export PATH ;; esac\n'
        fi
        if [ -s "$lang_er_root/go/.goproxy" ]; then
            printf 'GOPROXY="%s"\nexport GOPROXY\n' "$LINUXAPP_LANG_GO_GOPROXY"
        fi
        if [ -d "$lang_er_root/rust" ] && [ -d "$lang_er_root/cargo" ]; then
            printf 'RUSTUP_HOME="%s/rust"\nexport RUSTUP_HOME\n' "$lang_er_root"
            printf 'CARGO_HOME="%s/cargo"\nexport CARGO_HOME\n' "$lang_er_root"
            lang_env_path_expr "$lang_er_root/cargo/bin"
        fi
    } > "$lang_er_tmp" 2>/dev/null || {
        rm -f "$lang_er_tmp" 2>/dev/null || true
        return 1
    }
    chmod 644 "$lang_er_tmp" 2>/dev/null || true
    if ! mv "$lang_er_tmp" "$lang_er_root/env.sh" 2>/dev/null; then
        rm -f "$lang_er_tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}

# 删除文件中的受控标记块（含起止标记行本身）。
lang_block_remove() {
    lang_br_file=$1
    lang_br_begin=$2
    lang_br_end=$3
    [ -f "$lang_br_file" ] || return 0
    grep -qF "$lang_br_begin" "$lang_br_file" 2>/dev/null || return 0
    lang_br_tmp="$lang_br_file.linuxapp.$$"
    if ! awk -v b="$lang_br_begin" -v e="$lang_br_end" '
        index($0, b) == 1 { skip = 1; next }
        index($0, e) == 1 { skip = 0; next }
        skip == 1 { next }
        { lines[++n] = $0 }
        END {
            last = n;
            while (last > 0 && lines[last] == "") last--;
            for (i = 1; i <= last; i++) print lines[i];
        }
    ' "$lang_br_file" > "$lang_br_tmp" 2>/dev/null; then
        rm -f "$lang_br_tmp" 2>/dev/null || true
        return 1
    fi
    if ! cat "$lang_br_tmp" > "$lang_br_file" 2>/dev/null; then
        rm -f "$lang_br_tmp" 2>/dev/null || true
        return 1
    fi
    rm -f "$lang_br_tmp" 2>/dev/null || true
    return 0
}

# 追加受控标记块，块内容从标准输入读取。
lang_block_append() {
    lang_ba_file=$1
    lang_ba_begin=$2
    lang_ba_end=$3
    mkdir -p "$(dirname "$lang_ba_file")" 2>/dev/null || true
    if [ ! -e "$lang_ba_file" ]; then
        : > "$lang_ba_file" 2>/dev/null || {
            lang_fail "无法创建文件：$lang_ba_file"
            return 1
        }
    fi
    if ! {
        [ -s "$lang_ba_file" ] && printf '\n'
        printf '%s\n' "$lang_ba_begin"
        cat
        printf '%s\n' "$lang_ba_end"
    } >> "$lang_ba_file" 2>/dev/null; then
        lang_fail "无法写入文件：$lang_ba_file"
        return 1
    fi
    return 0
}

# 移除全部启动文件中的环境注入标记块。
lang_profile_block_remove() {
    for lang_pbr_file in $(lang_shell_rc_files); do
        lang_block_remove "$lang_pbr_file" \
            "# >>> $LINUXAPP_LANG_MARKER >>>" "# <<< $LINUXAPP_LANG_MARKER <<<" || return 1
    done
    # 专用文件（/etc/profile.d/linuxapp-lang.sh）清空后直接删除，避免残留空文件。
    lang_pbr_primary=$(lang_profile_file)
    case "$lang_pbr_primary" in
        */linuxapp-lang.sh)
            if [ -f "$lang_pbr_primary" ] && [ ! -s "$lang_pbr_primary" ]; then
                rm -f "$lang_pbr_primary" 2>/dev/null || true
            fi
            ;;
    esac
    LANG_PROFILE_FILES=''
    return 0
}

# 写入各启动文件的标记块，重复调用不会产生重复内容；至少成功写入一个才算成功。
lang_profile_block_install() {
    lang_pi_root=$(lang_default_root)
    lang_pi_done=0
    lang_pi_files=''
    # 先移除旧标记块，保证重复调用不会产生重复内容。
    lang_profile_block_remove || return 1
    for lang_pi_file in $(lang_shell_rc_files); do
        mkdir -p "$(dirname "$lang_pi_file")" 2>/dev/null || true
        if printf 'if [ -r "%s/env.sh" ]; then . "%s/env.sh"; fi\n' "$lang_pi_root" "$lang_pi_root" \
            | lang_block_append "$lang_pi_file" \
                "# >>> $LINUXAPP_LANG_MARKER >>>" "# <<< $LINUXAPP_LANG_MARKER <<<"; then
            lang_pi_done=$((lang_pi_done + 1))
            lang_pi_files="$lang_pi_files $lang_pi_file"
        else
            lang_warn "环境变量注入失败：$lang_pi_file"
        fi
    done
    LANG_PROFILE_FILES=${lang_pi_files# }
    if [ "$lang_pi_done" -eq 0 ]; then
        lang_fail '环境变量注入失败：没有可写入的 shell 启动文件。'
        return 1
    fi
    return 0
}

# 根据当前安装状态同步 env.sh、启动文件标记块与命令链接；没有任何语言时清理全部注入内容。
lang_env_sync() {
    lang_es_root=$(lang_default_root)
    lang_es_has=0
    for lang_es_name in java nodejs go rust cargo; do
        if [ -d "$lang_es_root/$lang_es_name" ]; then
            lang_es_has=1
            break
        fi
    done
    if [ "$lang_es_has" -eq 1 ]; then
        lang_env_regenerate || return 1
        lang_profile_block_install || return 1
        lang_bin_links_sync
        return 0
    fi
    rm -f "$lang_es_root/env.sh" 2>/dev/null || true
    lang_profile_block_remove || return 1
    lang_bin_links_sync
    return 0
}

# 环境生效提示。既用于安装/切换/修复之后，也用于卸载之后（此时会说明清理结果）。
lang_env_hint() {
    if [ -z "${LANG_PROFILE_FILES:-}" ]; then
        lang_out "已清理环境变量注入（$(lang_profile_file)）与命令入口（$(lang_bin_dir)）。"
        return 0
    fi
    lang_out "环境变量已写入：$LANG_PROFILE_FILES"
    if [ "${LANG_BIN_CREATED:-0}" -gt 0 ] 2>/dev/null; then
        lang_out "命令入口：$(lang_bin_dir)（$LANG_BIN_CREATED 个命令，任何 shell 都能直接调用）"
    else
        lang_out "命令入口目录：$(lang_bin_dir)"
    fi
    if [ "${LANG_BIN_SKIPPED:-0}" -gt 0 ] 2>/dev/null; then
        lang_warn "有 $LANG_BIN_SKIPPED 个同名命令未建立入口（见上方提示），这些命令请用绝对路径或环境变量调用。"
    fi
    lang_out '新开终端会自动生效；当前终端可执行：. '"$(lang_default_root)/env.sh"
}

# 重建环境注入与命令链接，用于修复“命令找不到”或注入内容被误删的情况。
lang_env_repair() {
    lang_env_sync || return 1
    lang_env_hint
    return 0
}

# ---------------------------------------------------------------- 生态源配置

# 备份用户配置文件，返回备份路径到 LANG_BACKUP。
lang_config_backup() {
    lang_cb_file=$1
    if [ -e "$lang_cb_file" ]; then
        if [ -e "$lang_cb_file.linuxapp.bak" ]; then
            LANG_BACKUP="$lang_cb_file.linuxapp.bak"
            return 0
        fi
        if cp "$lang_cb_file" "$lang_cb_file.linuxapp.bak" 2>/dev/null; then
            LANG_BACKUP="$lang_cb_file.linuxapp.bak"
            return 0
        fi
        return 1
    fi
    LANG_BACKUP=''
    return 0
}

# 询问是否使用国内生态源：结果写入 LANG_ECOSYSTEM（1 使用，0 不使用）。
lang_ecosystem_choose() {
    if [ -n "${LINUXAPP_LANG_ECOSYSTEM_MIRROR:-}" ]; then
        case "$LINUXAPP_LANG_ECOSYSTEM_MIRROR" in
            1) LANG_ECOSYSTEM=1; return 0 ;;
            *) LANG_ECOSYSTEM=0; return 0 ;;
        esac
    fi
    LANG_ECOSYSTEM=0
    if ! lang_has_tty; then
        return 0
    fi
    if lang_confirm "$1" n; then
        LANG_ECOSYSTEM=1
    fi
    return 0
}

# 写入 npm 国内源，带受控标记，可安全移除。
lang_npm_mirror_enable() {
    lang_nm_file=${1:-${HOME:-.}/.npmrc}
    lang_config_backup "$lang_nm_file" || {
        lang_warn "无法备份 $lang_nm_file，已跳过 npm 源设置。"
        return 1
    }
    lang_npm_mirror_disable "$lang_nm_file" || true
    printf 'registry=%s\n' "$LINUXAPP_LANG_NPM_REGISTRY" \
        | lang_block_append "$lang_nm_file" \
            "# >>> $LINUXAPP_NPM_MARKER >>>" "# <<< $LINUXAPP_NPM_MARKER <<<" || return 1
    return 0
}

# 移除 npm 国内源标记块。
lang_npm_mirror_disable() {
    lang_block_remove "${1:-${HOME:-.}/.npmrc}" \
        "# >>> $LINUXAPP_NPM_MARKER >>>" "# <<< $LINUXAPP_NPM_MARKER <<<"
}

# 判断 npm 国内源标记块是否存在。
lang_npm_mirror_enabled() {
    [ -f "${1:-${HOME:-.}/.npmrc}" ] && grep -qF "# >>> $LINUXAPP_NPM_MARKER >>>" "$1" 2>/dev/null
}

# 写入 cargo（crates.io）国内源，带受控标记，可安全移除。
lang_cargo_mirror_enable() {
    lang_cm_file=${1:-${HOME:-.}/.cargo/config.toml}
    lang_config_backup "$lang_cm_file" || {
        lang_warn "无法备份 $lang_cm_file，已跳过 cargo 源设置。"
        return 1
    }
    lang_cargo_mirror_disable "$lang_cm_file" || true
    {
        printf '%s\n' '[source.crates-io]'
        printf '%s\n' "replace-with = 'linuxapp-mirror'"
        printf '\n'
        printf '%s\n' '[source.linuxapp-mirror]'
        printf 'registry = "%s"\n' "$LINUXAPP_LANG_CARGO_MIRROR"
    } | lang_block_append "$lang_cm_file" \
        "# >>> $LINUXAPP_CARGO_MARKER >>>" "# <<< $LINUXAPP_CARGO_MARKER <<<" || return 1
    return 0
}

# 移除 cargo 国内源标记块。
lang_cargo_mirror_disable() {
    lang_block_remove "${1:-${HOME:-.}/.cargo/config.toml}" \
        "# >>> $LINUXAPP_CARGO_MARKER >>>" "# <<< $LINUXAPP_CARGO_MARKER <<<"
}

# Last updated: 2026-09-12 05:19
