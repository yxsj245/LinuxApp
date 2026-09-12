#!/bin/sh
# shellcheck disable=SC2034

# Node.js 语言模块。
# 支持安装、切换版本、更新、修复环境、卸载与状态查询；安装源可选国内镜像或官方源。
# 动作：capabilities、versions、status、install、switch [版本]、update、repair、uninstall
# 卸载支持选择已安装的版本，输入 a 表示卸载全部版本。

LANG_KEY=nodejs
LANG_TITLE='Node.js'

# 载入共享库：优先使用框架导出的仓库根目录，其次按脚本相对位置定位。
lang_module_dir=$(CDPATH='' cd "$(dirname "$0")" 2>/dev/null && pwd) || lang_module_dir='.'
lang_lib_loaded=0
for lang_lib_candidate in "${LINUXAPP_ROOT:-}/lib/lang.sh" "$lang_module_dir/../../../lib/lang.sh"; do
    if [ -n "$lang_lib_candidate" ] && [ -r "$lang_lib_candidate" ]; then
        # shellcheck disable=SC1090
        . "$lang_lib_candidate"
        lang_lib_loaded=1
        break
    fi
done
if [ "$lang_lib_loaded" -ne 1 ]; then
    printf '%s\n' '[错误] 找不到共享库 lib/lang.sh，请在 LinuxApp 仓库内运行本模块。' >&2
    exit 1
fi

LINUXAPP_LANG_STAGING=''

# 「安装」的幂等守卫：当前激活版本可用时直接视为已就绪，不再进入源选择、版本列表与确认流程。
# 软件模块的依赖联动会调用本模块的 install 动作，若每次都走进安装向导，用户会误以为"装过了又重新装"，
# 无终端场景下还会因为缺少交互输入直接失败，因此这里必须幂等。
# 需要真正重装同版本时设置 LINUXAPP_LANG_FORCE_INSTALL=1。
node_install_ready() {
    node_ir_current=$(lang_current_version nodejs 2>/dev/null || true)
    [ -n "$node_ir_current" ] || return 1
    [ -x "$(lang_home nodejs)/$node_ir_current/bin/node" ] || return 1
    lang_info "Node.js $node_ir_current 已安装且可用，无需重复安装。"
    lang_out '如需升级请选择「更新」，如需切换到其它已安装版本请选择「切换版本」；'
    lang_out '确实要重装同一版本时，请设置 LINUXAPP_LANG_FORCE_INSTALL=1 后重试。'
    return 0
}

lang_cleanup() {
    if [ -n "$LINUXAPP_LANG_STAGING" ] && [ -d "$LINUXAPP_LANG_STAGING" ]; then
        rm -rf "$LINUXAPP_LANG_STAGING" 2>/dev/null || true
    fi
    LINUXAPP_LANG_STAGING=''
}

# ---------------------------------------------------------------- 版本元数据

# 索引地址：$1 为 mirror 或 official。
node_index_url() {
    case "$1" in
        mirror) printf '%s/index.json\n' "$LINUXAPP_LANG_NODE_MIRROR" ;;
        *) printf '%s/index.json\n' "$LINUXAPP_LANG_NODE_OFFICIAL" ;;
    esac
}

# 安装包基地址。
node_base_url() {
    case "$1" in
        mirror) printf '%s\n' "$LINUXAPP_LANG_NODE_MIRROR" ;;
        *) printf '%s\n' "$LINUXAPP_LANG_NODE_OFFICIAL" ;;
    esac
}

# 解析 index.json，输出“版本|LTS 代号”记录（文件原始顺序为从新到旧）。
node_parse_index() {
    awk '{
        ver = ""; lts = "";
        if (match($0, /"version":"[^"]*"/)) ver = substr($0, RSTART + 11, RLENGTH - 12);
        if (match($0, /"lts":"[^"]*"/)) lts = substr($0, RSTART + 7, RLENGTH - 8);
        if (ver != "") printf "%s|%s\n", ver, lts;
    }' "$1" | sed -e 's/^v//'
}

# 从记录中取 LTS 大版本列表，从新到旧。
node_lts_majors() {
    awk -F'|' '$2 != "" { split($1, p, "."); print p[1] }' | sort -rnu
}

# 从标准输入读取记录，取某大版本的全部版本，从新到旧。$1 为大版本号。
node_versions_in_major() {
    awk -F'|' -v m="$1" '{ split($1, p, "."); if (p[1] == m) print $1 }' | lang_sort_versions_desc
}

# 取某版本的 LTS 代号。
node_lts_name() {
    awk -F'|' -v v="$2" '$1 == v { print $2; exit }' "$1"
}

# 判断记录中是否存在指定版本。
node_has_version() {
    awk -F'|' -v v="$2" '$1 == v { found = 1 } END { exit(found ? 0 : 1) }' "$1"
}

# 拉取并缓存索引，写入标准输出。
node_fetch_index() {
    node_fi_url=$(node_index_url "$1")
    lang_cache_fetch 'node-index.json' "$node_fi_url"
}

# 取某版本的 SHASUMS256.txt 校验值：$1 版本，$2 文件名，$3 源。
node_fetch_checksum() {
    node_fc_base=$(node_base_url "$3")
    node_fc_file=$(lang_default_root)/cache/node-shasums-$1.txt
    if ! lang_cache_fetch "node-shasums-$1.txt" "$node_fc_base/v$1/SHASUMS256.txt" > "$node_fc_file"; then
        return 1
    fi
    awk -v n="$2" '$2 == n { print $1; exit }' "$node_fc_file"
}

# 本地缓存中的可升级提示，不联网。
node_upgrade_hint() {
    node_uh_current=$1
    node_uh_major=${node_uh_current%%.*}
    node_uh_cache=$(lang_default_root)/cache/node-index.json
    [ -s "$node_uh_cache" ] || return 0
    node_uh_target=$(node_parse_index "$node_uh_cache" | node_versions_in_major "$node_uh_major" | sed -n '1p')
    [ -n "$node_uh_target" ] || return 0
    if lang_version_gt "$node_uh_target" "$node_uh_current"; then
        printf '；本地缓存显示可升级到 %s（运行「更新」）' "$node_uh_target"
    fi
    return 0
}

# 根据当前环境选择压缩格式：有 xz 时用 tar.xz，否则用 tar.gz。
node_archive_ext() {
    if command -v xz >/dev/null 2>&1; then
        printf '%s\n' 'tar.xz'
    else
        printf '%s\n' 'tar.gz'
    fi
}

# ---------------------------------------------------------------- 选择与安装

# 选择要安装的版本，结果写入 LANG_NODE_VERSION；$1 为记录文件。
node_choose_version() {
    node_cv_records=$1
    node_cv_wanted=$(printf '%s' "${LINUXAPP_LANG_VERSION:-}" | sed -e 's/^[vV]//')
    if [ -n "$node_cv_wanted" ]; then
        case "$node_cv_wanted" in
            *.*)
                if ! node_has_version "$node_cv_records" "$node_cv_wanted"; then
                    lang_fail "找不到 Node.js 版本 $node_cv_wanted。"
                    return 1
                fi
                LANG_NODE_VERSION=$node_cv_wanted
                return 0
                ;;
            *)
                node_cv_pick=$(node_versions_in_major "$node_cv_wanted" < "$node_cv_records" | sed -n '1p')
                if [ -z "$node_cv_pick" ]; then
                    lang_fail "大版本 $node_cv_wanted 没有可用版本。"
                    return 1
                fi
                LANG_NODE_VERSION=$node_cv_pick
                return 0
                ;;
        esac
    fi
    if ! lang_has_tty; then
        lang_fail '当前不是交互式终端，请通过 LINUXAPP_LANG_VERSION=<版本或大版本号> 指定要安装的 Node.js 版本。'
        return 1
    fi
    node_cv_current=$(lang_current_version nodejs 2>/dev/null || true)
    lang_out '可安装的 Node.js LTS 版本：'
    node_cv_index=0
    for node_cv_major in $(node_lts_majors < "$node_cv_records" | sed -n '1,3p'); do
        node_cv_version=$(node_versions_in_major "$node_cv_major" < "$node_cv_records" | sed -n '1p')
        node_cv_index=$((node_cv_index + 1))
        node_cv_mark=''
        if [ "$node_cv_version" = "$node_cv_current" ]; then
            node_cv_mark='（当前）'
        fi
        lang_out "  $node_cv_index. Node.js $node_cv_version（LTS $(node_lts_name "$node_cv_records" "$node_cv_version")）$node_cv_mark"
    done
    node_cv_manual=$((node_cv_index + 1))
    lang_out "  $node_cv_manual. 手动输入其它版本"
    lang_choose_number '请输入编号' "$node_cv_manual" || return 1
    if [ "$LANG_CHOICE" -eq "$node_cv_manual" ]; then
        lang_read_value '请输入版本号（例如 20.18.1 或 20）：' || return 1
        node_cv_input=$(printf '%s' "$LANG_REPLY" | sed -e 's/^[vV]//')
        case "$node_cv_input" in
            ''|*[!0-9.]*)
                lang_fail '版本号只能包含数字和点。'
                return 1
                ;;
            *.*)
                if ! node_has_version "$node_cv_records" "$node_cv_input"; then
                    lang_fail "找不到 Node.js 版本 $node_cv_input。"
                    return 1
                fi
                LANG_NODE_VERSION=$node_cv_input
                ;;
            *)
                node_cv_pick=$(node_versions_in_major "$node_cv_input" < "$node_cv_records" | sed -n '1p')
                if [ -z "$node_cv_pick" ]; then
                    lang_fail "大版本 $node_cv_input 没有可用版本。"
                    return 1
                fi
                LANG_NODE_VERSION=$node_cv_pick
                ;;
        esac
        return 0
    fi
    node_cv_major=$(node_lts_majors < "$node_cv_records" | sed -n "${LANG_CHOICE}p")
    LANG_NODE_VERSION=$(node_versions_in_major "$node_cv_major" < "$node_cv_records" | sed -n '1p')
    return 0
}

# 下载并安装指定版本：$1 版本，$2 源。成功后写入 LANG_INSTALLED_VERSION。
node_install_version() {
    node_iv_version=$1
    node_iv_source=$2
    node_iv_arch=$(lang_arch_kind) || {
        lang_fail '当前 CPU 架构不受支持，仅支持 x86_64、aarch64 与 armv7l。'
        return 1
    }
    node_iv_home=$(lang_home nodejs)
    if [ -d "$node_iv_home/$node_iv_version" ]; then
        lang_info "Node.js $node_iv_version 已经安装，跳过下载。"
        LANG_INSTALLED_VERSION=$node_iv_version
        return 0
    fi
    node_iv_ext=$(node_archive_ext)
    node_iv_file="node-v$node_iv_version-linux-$node_iv_arch.$node_iv_ext"
    node_iv_base=$(node_base_url "$node_iv_source")
    node_iv_url="$node_iv_base/v$node_iv_version/$node_iv_file"
    lang_info "正在获取 $node_iv_file 的校验值..."
    node_iv_sum=$(node_fetch_checksum "$node_iv_version" "$node_iv_file" "$node_iv_source") || node_iv_sum=''
    if [ -z "$node_iv_sum" ]; then
        if [ "$node_iv_ext" = tar.xz ]; then
            # 少数镜像可能缺少 xz 包，退回 tar.gz 重试一次。
            node_iv_ext=tar.gz
            node_iv_file="node-v$node_iv_version-linux-$node_iv_arch.tar.gz"
            node_iv_url="$node_iv_base/v$node_iv_version/$node_iv_file"
            node_iv_sum=$(node_fetch_checksum "$node_iv_version" "$node_iv_file" "$node_iv_source") || node_iv_sum=''
        fi
    fi
    if [ -z "$node_iv_sum" ]; then
        lang_fail '没有取到官方校验值，出于安全考虑已中止安装。'
        return 1
    fi
    mkdir -p "$LINUXAPP_LANG_STAGING" 2>/dev/null || {
        lang_fail "无法创建临时目录：$LINUXAPP_LANG_STAGING"
        return 1
    }
    node_iv_archive=$LINUXAPP_LANG_STAGING/$node_iv_file
    if ! lang_download "$node_iv_url" "$node_iv_archive"; then
        lang_warn '首选源下载失败，改用备用源重试。'
        node_iv_alt=official
        [ "$node_iv_source" = official ] && node_iv_alt=mirror
        node_iv_base=$(node_base_url "$node_iv_alt")
        node_iv_url="$node_iv_base/v$node_iv_version/$node_iv_file"
        if ! lang_download "$node_iv_url" "$node_iv_archive"; then
            lang_fail '国内镜像与官方源都无法下载，请检查网络后重试。'
            return 1
        fi
    fi
    if ! lang_verify_sha256 "$node_iv_archive" "$node_iv_sum"; then
        rm -f "$node_iv_archive" 2>/dev/null || true
        return 1
    fi
    if ! lang_check_archive "$node_iv_archive"; then
        rm -f "$node_iv_archive" 2>/dev/null || true
        return 1
    fi
    node_iv_extract=$LINUXAPP_LANG_STAGING/extract
    rm -rf "$node_iv_extract" 2>/dev/null || true
    lang_info "正在解压 Node.js $node_iv_version..."
    if ! lang_extract "$node_iv_archive" "$node_iv_extract" 1; then
        lang_fail '解压失败，安装已中止。'
        return 1
    fi
    if [ ! -f "$node_iv_extract/bin/node" ]; then
        lang_fail '解压结果缺少 bin/node，安装已中止。'
        return 1
    fi
    mkdir -p "$node_iv_home" 2>/dev/null || {
        lang_fail "无法创建安装目录：$node_iv_home"
        return 1
    }
    if ! mv "$node_iv_extract" "$node_iv_home/$node_iv_version" 2>/dev/null; then
        lang_fail "无法安装到 $node_iv_home/$node_iv_version"
        return 1
    fi
    rm -f "$node_iv_archive" 2>/dev/null || true
    lang_ok "Node.js $node_iv_version 已解压到 $node_iv_home/$node_iv_version"
    LANG_INSTALLED_VERSION=$node_iv_version
    return 0
}

# 激活版本：$1 版本，$2 默认值。
node_activate() {
    node_ac_version=$1
    node_ac_default=${2:-y}
    node_ac_current=$(lang_current_version nodejs 2>/dev/null || true)
    if [ "$node_ac_current" = "$node_ac_version" ]; then
        lang_info "当前已经是 Node.js $node_ac_version。"
        return 0
    fi
    if [ -n "$node_ac_current" ]; then
        if ! lang_confirm "是否把当前版本从 $node_ac_current 切换为 $node_ac_version？" "$node_ac_default"; then
            lang_info "Node.js $node_ac_version 已安装，当前版本仍为 $node_ac_current，稍后可执行「切换版本」。"
            return 0
        fi
    fi
    lang_link_current nodejs "$node_ac_version" || return 1
    lang_ok "当前 Node.js 版本已设置为 $node_ac_version。"
    return 0
}

# 执行 node -v 与 npm -v 验证安装结果。
node_report_version() {
    node_rv_bin=$(lang_home nodejs)/$1/bin
    if [ -x "$node_rv_bin/node" ]; then
        node_rv_node=$("$node_rv_bin/node" -v 2>&1 | sed -n '1p')
        lang_ok "验证结果：node $node_rv_node"
        if [ -x "$node_rv_bin/npm" ]; then
            node_rv_npm=$(PATH="$node_rv_bin:$PATH" "$node_rv_bin/npm" --version 2>/dev/null | sed -n '1p')
            [ -n "$node_rv_npm" ] && lang_out "npm 版本：$node_rv_npm"
        fi
    else
        lang_warn "未找到可执行文件：$node_rv_bin/node"
    fi
    return 0
}

# 国内源安装后询问是否写入 npm 国内源。
node_ecosystem_setup() {
    lang_ecosystem_choose "是否把 npm 默认源设置为国内镜像（$LINUXAPP_LANG_NPM_REGISTRY）？"
    if [ "$LANG_ECOSYSTEM" != 1 ]; then
        return 0
    fi
    node_es_npmrc=${HOME:-.}/.npmrc
    if lang_npm_mirror_enable "$node_es_npmrc"; then
        lang_ok "npm 国内源已写入：$node_es_npmrc"
        [ -n "${LANG_BACKUP:-}" ] && lang_out "原文件已备份为：$LANG_BACKUP"
    else
        lang_warn 'npm 国内源写入失败，已跳过。'
    fi
    return 0
}

# ---------------------------------------------------------------- 动作实现

node_install() {
    lang_require_commands tar || return 1
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        lang_fail '系统中找不到 curl 或 wget，无法下载 Node.js。请先安装 curl 或 wget。'
        return 1
    fi
    if [ "${LINUXAPP_LANG_FORCE_INSTALL:-0}" != 1 ] && node_install_ready; then
        return 0
    fi
    lang_source_choose || return 1
    node_in_source=$LANG_SOURCE
    node_in_root=$(lang_default_root)
    mkdir -p "$node_in_root/nodejs" 2>/dev/null || {
        lang_fail "无法创建安装目录：$node_in_root/nodejs"
        return 1
    }
    LINUXAPP_LANG_STAGING=$node_in_root/nodejs/.staging.$$
    rm -rf "$LINUXAPP_LANG_STAGING" 2>/dev/null || true
    mkdir -p "$LINUXAPP_LANG_STAGING" 2>/dev/null || {
        lang_fail "无法创建临时目录：$LINUXAPP_LANG_STAGING"
        return 1
    }

    lang_info '正在获取 Node.js 版本列表...'
    node_in_index=$LINUXAPP_LANG_STAGING/index.json
    node_in_records=$LINUXAPP_LANG_STAGING/records.txt
    if ! node_fetch_index "$node_in_source" > "$node_in_index"; then
        lang_fail '无法获取 Node.js 版本列表，请检查网络连接后重试。'
        return 1
    fi
    node_parse_index "$node_in_index" > "$node_in_records"
    if [ ! -s "$node_in_records" ]; then
        lang_fail 'Node.js 版本列表解析失败，请稍后重试。'
        return 1
    fi
    node_choose_version "$node_in_records" || return 1

    if [ "$node_in_source" = mirror ]; then
        lang_out "安装源：国内镜像（$LINUXAPP_LANG_NODE_MIRROR）"
    else
        lang_out "安装源：官方源（$LINUXAPP_LANG_NODE_OFFICIAL）"
    fi
    lang_out "准备安装：Node.js $LANG_NODE_VERSION"
    lang_confirm '确认开始安装吗？' y || {
        lang_info '已取消安装。'
        return 0
    }
    node_install_version "$LANG_NODE_VERSION" "$node_in_source" || return 1
    node_activate "$LANG_INSTALLED_VERSION" y || return 1
    if ! lang_env_sync; then
        lang_fail '环境变量注入失败。'
        return 1
    fi
    lang_env_hint
    node_report_version "$LANG_INSTALLED_VERSION"
    if [ "$node_in_source" = mirror ]; then
        node_ecosystem_setup
    fi
    return 0
}

node_switch() {
    node_sw_wanted=$(printf '%s' "${1:-${LINUXAPP_LANG_VERSION:-}}" | sed -e 's/^[vV]//')
    node_sw_versions=$(lang_list_versions nodejs)
    if [ -z "$node_sw_versions" ]; then
        lang_warn '尚未安装任何 Node.js 版本，请先执行「安装」。'
        return 1
    fi
    node_sw_current=$(lang_current_version nodejs 2>/dev/null || true)
    if [ -n "$node_sw_wanted" ]; then
        if ! printf '%s\n' "$node_sw_versions" | grep -qx "$node_sw_wanted"; then
            lang_fail "版本 $node_sw_wanted 尚未安装。已安装：$(printf '%s' "$node_sw_versions" | tr '\n' ' ')"
            return 1
        fi
        node_sw_target=$node_sw_wanted
    else
        if ! lang_has_tty; then
            lang_fail '当前不是交互式终端，请使用：module.sh switch <版本>'
            return 1
        fi
        lang_out '已安装的 Node.js 版本：'
        node_sw_index=0
        for node_sw_version in $node_sw_versions; do
            node_sw_index=$((node_sw_index + 1))
            node_sw_mark=''
            if [ "$node_sw_version" = "$node_sw_current" ]; then
                node_sw_mark='（当前）'
            fi
            lang_out "  $node_sw_index. $node_sw_version$node_sw_mark"
        done
        node_sw_more=$((node_sw_index + 1))
        lang_out "  $node_sw_more. 安装或升级到其它版本（等同于「更新」）"
        lang_choose_number '请输入编号' "$node_sw_more" || return 1
        if [ "$LANG_CHOICE" -eq "$node_sw_more" ]; then
            node_update
            return $?
        fi
        node_sw_target=$(printf '%s\n' "$node_sw_versions" | sed -n "${LANG_CHOICE}p")
    fi
    if [ "$node_sw_target" = "$node_sw_current" ]; then
        lang_info "当前已经是 Node.js $node_sw_target，无需切换。"
        return 0
    fi
    lang_link_current nodejs "$node_sw_target" || return 1
    lang_env_sync >/dev/null 2>&1 || true
    lang_ok "已切换：Node.js $node_sw_current -> $node_sw_target"
    lang_env_hint
    node_report_version "$node_sw_target"
    return 0
}

node_update() {
    lang_require_commands tar || return 1
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        lang_fail '系统中找不到 curl 或 wget，无法下载 Node.js。请先安装 curl 或 wget。'
        return 1
    fi
    node_up_current=$(lang_current_version nodejs 2>/dev/null || true)
    if [ -z "$node_up_current" ]; then
        lang_warn '当前没有激活的 Node.js 版本，请先执行「安装」。'
        return 1
    fi
    node_up_major=${node_up_current%%.*}
    node_up_mode=${LINUXAPP_LANG_UPDATE:-patch}
    case "$node_up_mode" in
        patch|major|latest) ;;
        *)
            lang_fail "环境变量 LINUXAPP_LANG_UPDATE 取值无效：$node_up_mode（应为 patch、major 或 latest）。"
            return 1
            ;;
    esac
    lang_source_choose || return 1
    node_up_source=$LANG_SOURCE
    node_up_root=$(lang_default_root)
    mkdir -p "$node_up_root/nodejs" 2>/dev/null || return 1
    LINUXAPP_LANG_STAGING=$node_up_root/nodejs/.staging.$$
    rm -rf "$LINUXAPP_LANG_STAGING" 2>/dev/null || true
    mkdir -p "$LINUXAPP_LANG_STAGING" 2>/dev/null || {
        lang_fail "无法创建临时目录：$LINUXAPP_LANG_STAGING"
        return 1
    }
    lang_info "正在检查 Node.js $node_up_major 的最新补丁版本（当前 $node_up_current）..."
    node_up_index=$LINUXAPP_LANG_STAGING/index.json
    node_up_records=$LINUXAPP_LANG_STAGING/records.txt
    if ! node_fetch_index "$node_up_source" > "$node_up_index"; then
        lang_fail '无法获取 Node.js 版本列表，请检查网络连接后重试。'
        return 1
    fi
    node_parse_index "$node_up_index" > "$node_up_records"
    if [ ! -s "$node_up_records" ]; then
        lang_fail 'Node.js 版本列表解析失败，请稍后重试。'
        return 1
    fi

    node_up_target=''
    if [ "$node_up_mode" != major ]; then
        node_up_latest=$(node_versions_in_major "$node_up_major" < "$node_up_records" | sed -n '1p')
        if [ -n "$node_up_latest" ] && lang_version_gt "$node_up_latest" "$node_up_current"; then
            node_up_target=$node_up_latest
        else
            lang_info "Node.js $node_up_major 的补丁版本已是最新（$node_up_current）。"
        fi
    fi

    if [ -z "$node_up_target" ]; then
        case "$node_up_mode" in
            latest)
                node_up_target_major=$(node_lts_majors < "$node_up_records" | sort -rn | sed -n '1p')
                ;;
            *)
                node_up_target_major=$(node_lts_majors < "$node_up_records" | lang_next_major "$node_up_major")
                ;;
        esac
        if [ -z "$node_up_target_major" ] || [ "$node_up_target_major" = "$node_up_major" ]; then
            lang_ok '当前已是最新版本，无需更新。'
            return 0
        fi
        node_up_target=$(node_versions_in_major "$node_up_target_major" < "$node_up_records" | sed -n '1p')
        if [ -z "$node_up_target" ]; then
            lang_fail "大版本 $node_up_target_major 没有可用版本。"
            return 1
        fi
        if [ "$node_up_mode" = patch ]; then
            if [ "${LINUXAPP_LANG_YES:-0}" = 1 ]; then
                lang_info '非交互模式默认不做大版本升级；如需升级请设置 LINUXAPP_LANG_UPDATE=major 或 latest。'
                return 0
            fi
            if ! lang_confirm "补丁已是最新；是否升级到更新的 LTS 大版本 Node.js $node_up_target？" n; then
                lang_ok '当前补丁已是最新，未做大版本升级。'
                return 0
            fi
        fi
    fi

    lang_out "检测到新版本：Node.js $node_up_target（当前 $node_up_current）"
    if [ "$node_up_source" = mirror ]; then
        lang_out "安装源：国内镜像（$LINUXAPP_LANG_NODE_MIRROR）"
    else
        lang_out "安装源：官方源（$LINUXAPP_LANG_NODE_OFFICIAL）"
    fi
    lang_confirm "是否升级到 Node.js $node_up_target？" y || {
        lang_info '已取消更新。'
        return 0
    }
    node_install_version "$node_up_target" "$node_up_source" || return 1
    node_activate "$LANG_INSTALLED_VERSION" y || return 1
    if ! lang_env_sync; then
        lang_fail '环境变量注入失败。'
        return 1
    fi
    lang_ok "升级完成：Node.js $node_up_current -> $LANG_INSTALLED_VERSION"
    lang_out "旧版本 $node_up_current 仍然保留，可用「切换版本」随时回退。"
    lang_env_hint
    node_report_version "$LANG_INSTALLED_VERSION"
    return 0
}

# 卸载：可选择卸载某个已安装版本，输入 a 表示卸载全部版本。
node_uninstall() {
    node_un_home=$(lang_home nodejs)
    node_un_npmrc=${HOME:-.}/.npmrc
    node_un_versions=$(lang_list_versions nodejs)
    node_un_current=$(lang_current_version nodejs 2>/dev/null || true)
    node_un_npmrc_has=0
    if lang_npm_mirror_enabled "$node_un_npmrc"; then
        node_un_npmrc_has=1
    fi
    if [ -z "$node_un_versions" ] && [ "$node_un_npmrc_has" -eq 0 ]; then
        lang_info 'Node.js 环境尚未安装，无需卸载。'
        return 0
    fi

    node_un_scope=all
    node_un_target=''
    if [ -n "$node_un_versions" ]; then
        lang_uninstall_choose 'Node.js 版本' "$node_un_versions" "$node_un_current" || {
            lang_info '已取消卸载。'
            return 0
        }
        node_un_scope=$LANG_UNINSTALL_SCOPE
        node_un_target=$LANG_UNINSTALL_VERSION
    fi

    if [ "$node_un_scope" = one ]; then
        node_un_rest=$(printf '%s\n' "$node_un_versions" | grep -vxF "$node_un_target")
        lang_out "将删除版本目录：$node_un_home/$node_un_target"
        if [ "$node_un_target" = "$node_un_current" ]; then
            lang_warn '该版本当前正在使用。'
        fi
        if [ -z "$node_un_rest" ]; then
            lang_out "这是最后一个 Node.js 版本，卸载后将一并清理安装目录：$node_un_home"
            if [ "$node_un_npmrc_has" -eq 1 ]; then
                lang_out "以及 npm 国内源配置：$node_un_npmrc（由本模块写入的标记块）"
            fi
        fi
        lang_confirm "确认卸载 Node.js $node_un_target 吗？" n || {
            lang_info '已取消卸载。'
            return 0
        }
        lang_remove_versions nodejs "$node_un_target" || {
            lang_fail "删除失败：$node_un_home/$node_un_target（请检查权限）"
            return 1
        }
        if [ -n "$node_un_rest" ]; then
            lang_ok "Node.js $node_un_target 已卸载。"
            if [ "$node_un_npmrc_has" -eq 1 ]; then
                lang_out "npm 国内源配置保留：$node_un_npmrc（仍有其它版本在使用）"
            fi
            if ! lang_reactivate_latest nodejs; then
                lang_warn '剩余版本重新激活失败，请执行「切换版本」手工选择。'
                lang_env_sync >/dev/null 2>&1 || true
                return 1
            fi
            if [ "$node_un_target" = "$node_un_current" ]; then
                lang_out "当前 Node.js 版本已切换为 $LANG_ACTIVATED_VERSION。"
            fi
            lang_env_sync >/dev/null 2>&1 || true
            lang_env_hint
            return 0
        fi
        if ! rm -rf "$node_un_home" 2>/dev/null; then
            lang_fail "删除失败：$node_un_home（请检查权限）"
            return 1
        fi
        if [ "$node_un_npmrc_has" -eq 1 ]; then
            if lang_npm_mirror_disable "$node_un_npmrc"; then
                lang_ok "已移除 npm 国内源配置：$node_un_npmrc"
            else
                lang_warn "npm 配置清理失败，请手工检查：$node_un_npmrc"
            fi
        fi
        lang_env_sync >/dev/null 2>&1 || true
        lang_ok 'Node.js 已全部卸载，安装目录已清理。'
        lang_env_hint
        return 0
    fi

    if [ -d "$node_un_home" ]; then
        lang_out "将删除 Node.js 安装目录：$node_un_home"
        if [ -n "$node_un_versions" ]; then
            lang_out "包含版本：$(printf '%s' "$node_un_versions" | tr '\n' ',' | sed -e 's/,$//' -e 's/,/、/g')"
        fi
    fi
    if [ "$node_un_npmrc_has" -eq 1 ]; then
        lang_out "将移除 npm 国内源配置：$node_un_npmrc（由本模块写入的标记块）"
    fi
    lang_confirm '确认卸载 Node.js 环境吗？' n || {
        lang_info '已取消卸载。'
        return 0
    }
    if [ -d "$node_un_home" ]; then
        if ! rm -rf "$node_un_home" 2>/dev/null; then
            lang_fail "删除失败：$node_un_home（请检查权限）"
            return 1
        fi
    fi
    if [ "$node_un_npmrc_has" -eq 1 ]; then
        if lang_npm_mirror_disable "$node_un_npmrc"; then
            lang_ok "已移除 npm 国内源配置：$node_un_npmrc"
        else
            lang_warn "npm 配置清理失败，请手工检查：$node_un_npmrc"
        fi
    fi
    lang_env_sync >/dev/null 2>&1 || true
    lang_ok 'Node.js 环境已卸载。'
    lang_env_hint
    return 0
}

node_status() {
    node_st_root=$(lang_default_root)
    node_st_current=$(lang_current_version nodejs 2>/dev/null || true)
    node_st_versions=$(lang_list_versions nodejs)
    if [ -z "$node_st_current" ]; then
        if [ -z "$node_st_versions" ]; then
            printf '未安装|-|尚未安装 Node.js 环境，安装时可选择国内镜像或官方源\n'
            return 0
        fi
        printf '未安装|-|安装根 %s 已有解包目录但未激活，请执行「切换版本」\n' "$node_st_root"
        return 0
    fi
    node_st_count=$(printf '%s\n' "$node_st_versions" | grep -c .)
    node_st_list=$(printf '%s' "$node_st_versions" | tr '\n' ',' | sed -e 's/,$//' -e 's/,/、/g')
    node_st_hint=$(node_upgrade_hint "$node_st_current")
    printf '已安装|%s|安装根 %s，共 %s 个版本：%s%s\n' \
        "$node_st_current" "$node_st_root" "$node_st_count" "$node_st_list" "$node_st_hint"
    return 0
}

node_versions() {
    node_vs_current=$(lang_current_version nodejs 2>/dev/null || true)
    lang_list_versions nodejs | while IFS= read -r node_vs_version; do
        [ -n "$node_vs_version" ] || continue
        if [ "$node_vs_version" = "$node_vs_current" ]; then
            printf '%s|current\n' "$node_vs_version"
        else
            printf '%s|installed\n' "$node_vs_version"
        fi
    done
    return 0
}

# ---------------------------------------------------------------- 动作分发

node_main() {
    node_action=${1:-status}
    case "$node_action" in
        capabilities) printf '%s\n' 'versions switch update repair' ;;
        versions) node_versions ;;
        status) node_status ;;
        install) node_install ;;
        switch)
            node_dispatch_arg=''
            if [ "$#" -gt 1 ]; then
                shift
                node_dispatch_arg=$1
            fi
            node_switch "$node_dispatch_arg"
            ;;
        update) node_update ;;
        repair) lang_env_repair ;;
        uninstall) node_uninstall ;;
        start|stop)
            lang_fail '语言模块不支持启动和停止。'
            return 2
            ;;
        *)
            lang_fail "未知的语言动作：$node_action"
            return 2
            ;;
    esac
}

trap 'lang_cleanup; lang_out ""; lang_warn "Node.js 操作已被 Ctrl+C 中断，临时文件已清理。"; exit 130' INT
trap 'lang_cleanup' TERM HUP

node_main "$@"
node_exit_code=$?
lang_cleanup
exit "$node_exit_code"

# Last updated: 2026-09-12 05:19
