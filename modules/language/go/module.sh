#!/bin/sh
# shellcheck disable=SC2034

# Go 语言模块。
# 支持安装、更新、修复环境、卸载与状态查询；安装源可选国内镜像或官方源。
# 动作：capabilities、versions、status、install、update、repair、uninstall
# 卸载支持选择已安装的版本，输入 a 表示卸载全部版本。

LANG_KEY=go
LANG_TITLE='Go'

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
# 软件模块的依赖联动会调用本模块的 install 动作，重复进入安装向导会让用户误以为"装过了又重新装"，
# 无终端场景下还会因为缺少交互输入直接失败，因此这里必须幂等。
# 需要真正重装同版本时设置 LINUXAPP_LANG_FORCE_INSTALL=1。
go_install_ready() {
    go_ir_current=$(lang_current_version go 2>/dev/null || true)
    [ -n "$go_ir_current" ] || return 1
    [ -x "$(lang_home go)/$go_ir_current/bin/go" ] || return 1
    lang_info "Go $go_ir_current 已安装且可用，无需重复安装。"
    lang_out '如需升级请选择「更新」；确实要重装同一版本时，请设置 LINUXAPP_LANG_FORCE_INSTALL=1 后重试。'
    return 0
}

lang_cleanup() {
    if [ -n "$LINUXAPP_LANG_STAGING" ] && [ -d "$LINUXAPP_LANG_STAGING" ]; then
        rm -rf "$LINUXAPP_LANG_STAGING" 2>/dev/null || true
    fi
    LINUXAPP_LANG_STAGING=''
}

# ---------------------------------------------------------------- 版本元数据

# Go 官方下载包的架构命名。
go_arch() {
    case "$(lang_arch_kind)" in
        x64) printf '%s\n' 'amd64' ;;
        arm64) printf '%s\n' 'arm64' ;;
        *) return 1 ;;
    esac
}

# 下载基地址：$1 为 mirror 或 official。
go_base_url() {
    case "$1" in
        mirror) printf '%s\n' "$LINUXAPP_LANG_GO_MIRROR" ;;
        *) printf '%s\n' "$LINUXAPP_LANG_GO_OFFICIAL" ;;
    esac
}

# 拉取版本清单 JSON，写入标准输出。国内源使用 Go 官方中国站，失败后回退另一站点。
go_fetch_index() {
    go_fi_primary=''
    go_fi_secondary=''
    case "$1" in
        mirror)
            go_fi_primary="$LINUXAPP_LANG_GO_OFFICIAL_CN/dl/?mode=json"
            go_fi_secondary="$LINUXAPP_LANG_GO_OFFICIAL/dl/?mode=json"
            ;;
        *)
            go_fi_primary="$LINUXAPP_LANG_GO_OFFICIAL/dl/?mode=json"
            go_fi_secondary="$LINUXAPP_LANG_GO_OFFICIAL_CN/dl/?mode=json"
            ;;
    esac
    if lang_cache_fetch 'go-releases.json' "$go_fi_primary"; then
        return 0
    fi
    lang_cache_fetch 'go-releases.json' "$go_fi_secondary"
}

# 解析版本清单，输出去掉 go 前缀的稳定版本，顺序为先新后旧。
go_parse_versions() {
    awk 'match($0, /"version": "go[0-9][^"]*"/) {
        raw = substr($0, RSTART + 12, RLENGTH - 13);
        if (raw != prev) {
            prev = raw;
            version = raw;
            sub(/^go/, "", version);
            print version;
        }
    }' "$1"
}

# 从清单中取指定文件的 sha256。
go_checksum() {
    awk -v target="$2" '
        index($0, "\"" target "\"") > 0 { found = 1; next }
        found && /"sha256"/ {
            line = $0;
            sub(/.*"sha256"[[:space:]]*:[[:space:]]*"/, "", line);
            sub(/".*/, "", line);
            if (line != "") print line;
            exit;
        }
    ' "$1"
}

# 本地缓存中的可升级提示，不联网。
go_upgrade_hint() {
    go_uh_current=$1
    go_uh_cache=$(lang_default_root)/cache/go-releases.json
    [ -s "$go_uh_cache" ] || return 0
    go_uh_target=$(go_parse_versions "$go_uh_cache" | sed -n '1p')
    [ -n "$go_uh_target" ] || return 0
    if lang_version_gt "$go_uh_target" "$go_uh_current"; then
        printf '；本地缓存显示可升级到 %s（运行「更新」）' "$go_uh_target"
    fi
    return 0
}

# ---------------------------------------------------------------- 选择与安装

# 选择要安装的版本，结果写入 LANG_GO_VERSION；$1 为清单文件。
go_choose_version() {
    go_cv_json=$1
    go_cv_wanted=$(printf '%s' "${LINUXAPP_LANG_VERSION:-}" | sed -e 's/^[gG][oO]//' -e 's/^[vV]//')
    if [ -n "$go_cv_wanted" ]; then
        if ! go_parse_versions "$go_cv_json" | grep -qx "$go_cv_wanted"; then
            lang_fail "版本清单中没有 Go $go_cv_wanted。可用版本：$(go_parse_versions "$go_cv_json" | tr '\n' ' ')"
            return 1
        fi
        LANG_GO_VERSION=$go_cv_wanted
        return 0
    fi
    if ! lang_has_tty; then
        lang_fail '当前不是交互式终端，请通过 LINUXAPP_LANG_VERSION=<版本号> 指定要安装的 Go 版本。'
        return 1
    fi
    go_cv_current=$(lang_current_version go 2>/dev/null || true)
    lang_out '可安装的 Go 版本：'
    go_cv_index=0
    for go_cv_version in $(go_parse_versions "$go_cv_json" | sed -n '1,5p'); do
        go_cv_index=$((go_cv_index + 1))
        go_cv_mark=''
        if [ "$go_cv_version" = "$go_cv_current" ]; then
            go_cv_mark='（当前）'
        fi
        if lang_version_installed go "$go_cv_version"; then
            go_cv_mark="$go_cv_mark（已安装）"
        fi
        lang_out "  $go_cv_index. Go $go_cv_version$go_cv_mark"
    done
    go_cv_manual=$((go_cv_index + 1))
    lang_out "  $go_cv_manual. 手动输入其它版本"
    lang_choose_number '请输入编号' "$go_cv_manual" || return 1
    if [ "$LANG_CHOICE" -eq "$go_cv_manual" ]; then
        lang_read_value '请输入 Go 版本号（例如 1.27.1）：' || return 1
        go_cv_input=$(printf '%s' "$LANG_REPLY" | sed -e 's/^[gG][oO]//' -e 's/^[vV]//')
        if ! go_parse_versions "$go_cv_json" | grep -qx "$go_cv_input"; then
            lang_fail "版本清单中没有 Go $go_cv_input。"
            return 1
        fi
        LANG_GO_VERSION=$go_cv_input
        return 0
    fi
    LANG_GO_VERSION=$(go_parse_versions "$go_cv_json" | sed -n "${LANG_CHOICE}p")
    return 0
}

# 下载并安装指定版本：$1 版本，$2 源，$3 清单文件。成功后写入 LANG_INSTALLED_VERSION。
go_install_version() {
    go_iv_version=$1
    go_iv_source=$2
    go_iv_json=$3
    go_iv_arch=$(go_arch) || {
        lang_fail '当前 CPU 架构不受支持，仅支持 x86_64 与 aarch64。'
        return 1
    }
    go_iv_home=$(lang_home go)
    if [ -d "$go_iv_home/$go_iv_version" ]; then
        lang_info "Go $go_iv_version 已经安装，跳过下载。"
        LANG_INSTALLED_VERSION=$go_iv_version
        return 0
    fi
    go_iv_file="go$go_iv_version.linux-$go_iv_arch.tar.gz"
    go_iv_sum=$(go_checksum "$go_iv_json" "$go_iv_file") || go_iv_sum=''
    if [ -z "$go_iv_sum" ]; then
        lang_fail "没有取到 $go_iv_file 的官方校验值，出于安全考虑已中止安装。"
        return 1
    fi
    go_iv_base=$(go_base_url "$go_iv_source")
    go_iv_url="$go_iv_base/dl/$go_iv_file"
    case "$go_iv_source" in
        mirror) go_iv_url="$go_iv_base/$go_iv_file" ;;
    esac
    mkdir -p "$LINUXAPP_LANG_STAGING" 2>/dev/null || {
        lang_fail "无法创建临时目录：$LINUXAPP_LANG_STAGING"
        return 1
    }
    go_iv_archive=$LINUXAPP_LANG_STAGING/$go_iv_file
    if ! lang_download "$go_iv_url" "$go_iv_archive"; then
        lang_warn '首选源下载失败，改用备用源重试。'
        if [ "$go_iv_source" = mirror ]; then
            go_iv_url="$LINUXAPP_LANG_GO_OFFICIAL/dl/$go_iv_file"
        else
            go_iv_url="$LINUXAPP_LANG_GO_MIRROR/$go_iv_file"
        fi
        if ! lang_download "$go_iv_url" "$go_iv_archive"; then
            lang_fail '国内镜像与官方源都无法下载，请检查网络后重试。'
            return 1
        fi
    fi
    if ! lang_verify_sha256 "$go_iv_archive" "$go_iv_sum"; then
        rm -f "$go_iv_archive" 2>/dev/null || true
        return 1
    fi
    if ! lang_check_archive "$go_iv_archive"; then
        rm -f "$go_iv_archive" 2>/dev/null || true
        return 1
    fi
    go_iv_extract=$LINUXAPP_LANG_STAGING/extract
    rm -rf "$go_iv_extract" 2>/dev/null || true
    lang_info "正在解压 Go $go_iv_version..."
    if ! lang_extract "$go_iv_archive" "$go_iv_extract" 1; then
        lang_fail '解压失败，安装已中止。'
        return 1
    fi
    if [ ! -f "$go_iv_extract/bin/go" ]; then
        lang_fail '解压结果缺少 bin/go，安装已中止。'
        return 1
    fi
    mkdir -p "$go_iv_home" 2>/dev/null || {
        lang_fail "无法创建安装目录：$go_iv_home"
        return 1
    }
    if ! mv "$go_iv_extract" "$go_iv_home/$go_iv_version" 2>/dev/null; then
        lang_fail "无法安装到 $go_iv_home/$go_iv_version"
        return 1
    fi
    rm -f "$go_iv_archive" 2>/dev/null || true
    lang_ok "Go $go_iv_version 已解压到 $go_iv_home/$go_iv_version"
    LANG_INSTALLED_VERSION=$go_iv_version
    return 0
}

# 激活版本：$1 版本，$2 默认值。
go_activate() {
    go_ac_version=$1
    go_ac_default=${2:-y}
    go_ac_current=$(lang_current_version go 2>/dev/null || true)
    if [ "$go_ac_current" = "$go_ac_version" ]; then
        lang_info "当前已经是 Go $go_ac_version。"
        return 0
    fi
    if [ -n "$go_ac_current" ]; then
        if ! lang_confirm "是否把 GOROOT 从 $go_ac_current 切换为 $go_ac_version？" "$go_ac_default"; then
            lang_info "Go $go_ac_version 已安装，当前版本仍为 $go_ac_current。"
            return 0
        fi
    fi
    lang_link_current go "$go_ac_version" || return 1
    lang_ok "当前 Go 版本已设置为 $go_ac_version。"
    return 0
}

# 执行 go version 验证安装结果。
go_report_version() {
    go_rv_bin=$(lang_home go)/$1/bin/go
    if [ -x "$go_rv_bin" ]; then
        go_rv_output=$("$go_rv_bin" version 2>&1 | sed -n '1p')
        lang_ok "验证结果：$go_rv_output"
    else
        lang_warn "未找到可执行文件：$go_rv_bin"
    fi
    return 0
}

# 国内源安装后询问是否写入国内 GOPROXY。
go_ecosystem_setup() {
    go_es_marker=$(lang_home go)/.goproxy
    if [ -s "$go_es_marker" ]; then
        lang_info "国内 GOPROXY 已配置：$LINUXAPP_LANG_GO_GOPROXY"
        return 0
    fi
    lang_ecosystem_choose "是否把 GOPROXY 设置为国内代理（$LINUXAPP_LANG_GO_GOPROXY）？"
    if [ "$LANG_ECOSYSTEM" != 1 ]; then
        return 0
    fi
    mkdir -p "$(lang_home go)" 2>/dev/null || true
    if printf '%s\n' "$LINUXAPP_LANG_GO_GOPROXY" > "$go_es_marker" 2>/dev/null; then
        # 标记文件是在安装流程的环境同步之后写入的，这里再同步一次，
        # 否则当前这次安装生成的 env.sh 不会包含 GOPROXY 导出。
        lang_env_sync >/dev/null 2>&1 || true
        lang_ok "已写入 $go_es_marker，env.sh 会导出 GOPROXY。"
        lang_out '卸载 Go 模块时会一并移除该配置。'
    else
        lang_warn "GOPROXY 配置写入失败：$go_es_marker"
    fi
    return 0
}

# ---------------------------------------------------------------- 动作实现

go_install() {
    lang_require_commands tar || return 1
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        lang_fail '系统中找不到 curl 或 wget，无法下载 Go。请先安装 curl 或 wget。'
        return 1
    fi
    if [ "${LINUXAPP_LANG_FORCE_INSTALL:-0}" != 1 ] && go_install_ready; then
        return 0
    fi
    lang_source_choose || return 1
    go_in_source=$LANG_SOURCE
    go_in_root=$(lang_default_root)
    mkdir -p "$go_in_root/go" 2>/dev/null || {
        lang_fail "无法创建安装目录：$go_in_root/go"
        return 1
    }
    LINUXAPP_LANG_STAGING=$go_in_root/go/.staging.$$
    rm -rf "$LINUXAPP_LANG_STAGING" 2>/dev/null || true
    mkdir -p "$LINUXAPP_LANG_STAGING" 2>/dev/null || {
        lang_fail "无法创建临时目录：$LINUXAPP_LANG_STAGING"
        return 1
    }

    lang_info '正在获取 Go 版本列表...'
    go_in_json=$LINUXAPP_LANG_STAGING/releases.json
    if ! go_fetch_index "$go_in_source" > "$go_in_json"; then
        lang_fail '无法获取 Go 版本列表，请检查网络连接后重试。'
        return 1
    fi
    go_choose_version "$go_in_json" || return 1

    if [ "$go_in_source" = mirror ]; then
        lang_out "安装源：国内镜像（$LINUXAPP_LANG_GO_MIRROR）"
    else
        lang_out "安装源：官方源（$LINUXAPP_LANG_GO_OFFICIAL）"
    fi
    lang_out "准备安装：Go $LANG_GO_VERSION"
    lang_confirm '确认开始安装吗？' y || {
        lang_info '已取消安装。'
        return 0
    }
    go_install_version "$LANG_GO_VERSION" "$go_in_source" "$go_in_json" || return 1
    go_activate "$LANG_INSTALLED_VERSION" y || return 1
    if ! lang_env_sync; then
        lang_fail '环境变量注入失败。'
        return 1
    fi
    lang_env_hint
    go_report_version "$LANG_INSTALLED_VERSION"
    if [ "$go_in_source" = mirror ]; then
        go_ecosystem_setup
    fi
    return 0
}

go_update() {
    lang_require_commands tar || return 1
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        lang_fail '系统中找不到 curl 或 wget，无法下载 Go。请先安装 curl 或 wget。'
        return 1
    fi
    go_up_current=$(lang_current_version go 2>/dev/null || true)
    if [ -z "$go_up_current" ]; then
        lang_warn '当前没有激活的 Go 版本，请先执行「安装」。'
        return 1
    fi
    lang_source_choose || return 1
    go_up_source=$LANG_SOURCE
    go_up_root=$(lang_default_root)
    mkdir -p "$go_up_root/go" 2>/dev/null || return 1
    LINUXAPP_LANG_STAGING=$go_up_root/go/.staging.$$
    rm -rf "$LINUXAPP_LANG_STAGING" 2>/dev/null || true
    mkdir -p "$LINUXAPP_LANG_STAGING" 2>/dev/null || {
        lang_fail "无法创建临时目录：$LINUXAPP_LANG_STAGING"
        return 1
    }
    lang_info "正在检查 Go 最新版本（当前 $go_up_current）..."
    go_up_json=$LINUXAPP_LANG_STAGING/releases.json
    if ! go_fetch_index "$go_up_source" > "$go_up_json"; then
        lang_fail '无法获取 Go 版本列表，请检查网络连接后重试。'
        return 1
    fi
    go_up_target=$(go_parse_versions "$go_up_json" | sed -n '1p')
    if [ -z "$go_up_target" ]; then
        lang_fail 'Go 版本列表解析失败。'
        return 1
    fi
    if ! lang_version_gt "$go_up_target" "$go_up_current"; then
        lang_ok "当前已是最新版本（Go $go_up_current），无需更新。"
        return 0
    fi
    lang_out "检测到新版本：Go $go_up_target（当前 $go_up_current）"
    lang_confirm "是否升级到 Go $go_up_target？" y || {
        lang_info '已取消更新。'
        return 0
    }
    go_install_version "$go_up_target" "$go_up_source" "$go_up_json" || return 1
    go_activate "$LANG_INSTALLED_VERSION" y || return 1
    if ! lang_env_sync; then
        lang_fail '环境变量注入失败。'
        return 1
    fi
    lang_ok "升级完成：Go $go_up_current -> $LANG_INSTALLED_VERSION"
    lang_out "旧版本 $go_up_current 仍然保留在安装目录中。"
    lang_env_hint
    go_report_version "$LANG_INSTALLED_VERSION"
    return 0
}

# 卸载：可选择卸载某个已安装版本，输入 a 表示卸载全部版本。
go_uninstall() {
    go_un_home=$(lang_home go)
    go_un_versions=$(lang_list_versions go)
    go_un_current=$(lang_current_version go 2>/dev/null || true)
    go_un_goproxy=0
    if [ -s "$go_un_home/.goproxy" ]; then
        go_un_goproxy=1
    fi
    if [ -z "$go_un_versions" ] && [ ! -d "$go_un_home" ]; then
        lang_info 'Go 环境尚未安装，无需卸载。'
        return 0
    fi

    go_un_scope=all
    go_un_target=''
    if [ -n "$go_un_versions" ]; then
        lang_uninstall_choose 'Go 版本' "$go_un_versions" "$go_un_current" || {
            lang_info '已取消卸载。'
            return 0
        }
        go_un_scope=$LANG_UNINSTALL_SCOPE
        go_un_target=$LANG_UNINSTALL_VERSION
    fi

    if [ "$go_un_scope" = one ]; then
        go_un_rest=$(printf '%s\n' "$go_un_versions" | grep -vxF "$go_un_target")
        lang_out "将删除版本目录：$go_un_home/$go_un_target"
        if [ "$go_un_target" = "$go_un_current" ]; then
            lang_warn '该版本当前正在使用。'
        fi
        if [ -z "$go_un_rest" ]; then
            lang_out "这是最后一个 Go 版本，卸载后将一并清理安装目录：$go_un_home"
            if [ "$go_un_goproxy" -eq 1 ]; then
                lang_out "以及国内 GOPROXY 配置：$go_un_home/.goproxy"
            fi
        fi
        lang_confirm "确认卸载 Go $go_un_target 吗？" n || {
            lang_info '已取消卸载。'
            return 0
        }
        lang_remove_versions go "$go_un_target" || {
            lang_fail "删除失败：$go_un_home/$go_un_target（请检查权限）"
            return 1
        }
        if [ -n "$go_un_rest" ]; then
            lang_ok "Go $go_un_target 已卸载。"
            if [ "$go_un_goproxy" -eq 1 ]; then
                lang_out "国内 GOPROXY 配置保留：$go_un_home/.goproxy（仍有其它版本在使用）"
            fi
            if ! lang_reactivate_latest go; then
                lang_warn '剩余版本重新激活失败，请重新执行「安装」或手工重建 current 链接。'
                lang_env_sync >/dev/null 2>&1 || true
                return 1
            fi
            if [ "$go_un_target" = "$go_un_current" ]; then
                lang_out "当前 Go 版本已切换为 $LANG_ACTIVATED_VERSION。"
            fi
            lang_env_sync >/dev/null 2>&1 || true
            lang_env_hint
            return 0
        fi
        if ! rm -rf "$go_un_home" 2>/dev/null; then
            lang_fail "删除失败：$go_un_home（请检查权限）"
            return 1
        fi
        lang_env_sync >/dev/null 2>&1 || true
        lang_ok 'Go 已全部卸载，安装目录已清理。'
        lang_env_hint
        return 0
    fi

    lang_out "将删除 Go 安装目录：$go_un_home"
    if [ -n "$go_un_versions" ]; then
        lang_out "包含版本：$(printf '%s' "$go_un_versions" | tr '\n' ',' | sed -e 's/,$//' -e 's/,/、/g')"
    fi
    if [ "$go_un_goproxy" -eq 1 ]; then
        lang_out "将一并移除国内 GOPROXY 配置：$go_un_home/.goproxy"
    fi
    lang_confirm '确认卸载 Go 环境吗？' n || {
        lang_info '已取消卸载。'
        return 0
    }
    if ! rm -rf "$go_un_home" 2>/dev/null; then
        lang_fail "删除失败：$go_un_home（请检查权限）"
        return 1
    fi
    lang_env_sync >/dev/null 2>&1 || true
    lang_ok 'Go 环境已卸载。'
    lang_env_hint
    return 0
}

go_status() {
    go_st_root=$(lang_default_root)
    go_st_current=$(lang_current_version go 2>/dev/null || true)
    go_st_versions=$(lang_list_versions go)
    if [ -z "$go_st_current" ]; then
        if [ -z "$go_st_versions" ]; then
            printf '未安装|-|尚未安装 Go 环境，安装时可选择国内镜像或官方源\n'
            return 0
        fi
        printf '未安装|-|安装根 %s 已有解包目录但未激活，请重新安装一次\n' "$go_st_root"
        return 0
    fi
    go_st_count=$(printf '%s\n' "$go_st_versions" | grep -c .)
    go_st_list=$(printf '%s' "$go_st_versions" | tr '\n' ',' | sed -e 's/,$//' -e 's/,/、/g')
    go_st_goproxy=''
    if [ -s "$go_st_root/go/.goproxy" ]; then
        go_st_goproxy='；已配置国内 GOPROXY'
    fi
    go_st_hint=$(go_upgrade_hint "$go_st_current")
    printf '已安装|%s|GOROOT=%s/go/current，共 %s 个版本：%s%s%s\n' \
        "$go_st_current" "$go_st_root" "$go_st_count" "$go_st_list" "$go_st_goproxy" "$go_st_hint"
    return 0
}

go_versions() {
    go_vs_current=$(lang_current_version go 2>/dev/null || true)
    lang_list_versions go | while IFS= read -r go_vs_version; do
        [ -n "$go_vs_version" ] || continue
        if [ "$go_vs_version" = "$go_vs_current" ]; then
            printf '%s|current\n' "$go_vs_version"
        else
            printf '%s|installed\n' "$go_vs_version"
        fi
    done
    return 0
}

# ---------------------------------------------------------------- 动作分发

go_main() {
    go_action=${1:-status}
    case "$go_action" in
        capabilities) printf '%s\n' 'versions update repair' ;;
        versions) go_versions ;;
        status) go_status ;;
        install) go_install ;;
        update) go_update ;;
        repair) lang_env_repair ;;
        uninstall) go_uninstall ;;
        switch)
            lang_fail 'Go 模块不提供版本切换，请使用「更新」安装最新版本；如需手工切换，可重建安装目录下的 current 链接。'
            return 2
            ;;
        start|stop)
            lang_fail '语言模块不支持启动和停止。'
            return 2
            ;;
        *)
            lang_fail "未知的语言动作：$go_action"
            return 2
            ;;
    esac
}

trap 'lang_cleanup; lang_out ""; lang_warn "Go 操作已被 Ctrl+C 中断，临时文件已清理。"; exit 130' INT
trap 'lang_cleanup' TERM HUP

go_main "$@"
go_exit_code=$?
lang_cleanup
exit "$go_exit_code"

# Last updated: 2026-09-12 05:19
