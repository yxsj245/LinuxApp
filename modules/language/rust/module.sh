#!/bin/sh
# shellcheck disable=SC2034

# Rust 语言模块（通过 rustup 官方安装器管理）。
# 支持安装、更新、修复环境、卸载与状态查询；安装源可选国内镜像或官方源。
# 动作：capabilities、versions、status、install、update、repair、uninstall
# 卸载支持选择已安装的工具链，输入 a 表示卸载全部工具链。

LANG_KEY=rust
LANG_TITLE='Rust'

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

lang_cleanup() {
    if [ -n "$LINUXAPP_LANG_STAGING" ] && [ -d "$LINUXAPP_LANG_STAGING" ]; then
        rm -rf "$LINUXAPP_LANG_STAGING" 2>/dev/null || true
    fi
    LINUXAPP_LANG_STAGING=''
}

# ---------------------------------------------------------------- 环境与地址

# 目标平台三元组。
rust_triple() {
    case "$(lang_arch_kind)" in
        x64) printf '%s\n' 'x86_64-unknown-linux-gnu' ;;
        arm64) printf '%s\n' 'aarch64-unknown-linux-gnu' ;;
        *) return 1 ;;
    esac
}

# rustup-init 下载地址：$1 源，$2 三元组。
rust_init_url() {
    case "$1" in
        mirror) printf '%s/rustup/dist/%s/rustup-init\n' "$LINUXAPP_LANG_RUST_MIRROR" "$2" ;;
        *) printf '%s/rustup/dist/%s/rustup-init\n' "$LINUXAPP_LANG_RUST_OFFICIAL" "$2" ;;
    esac
}

# 导出安装或更新所需的镜像环境变量：$1 源。
rust_apply_mirror_env() {
    rust_ame_source=$1
    if [ "$rust_ame_source" = mirror ]; then
        RUSTUP_DIST_SERVER=$LINUXAPP_LANG_RUST_MIRROR
        RUSTUP_UPDATE_ROOT="$LINUXAPP_LANG_RUST_MIRROR/rustup"
        export RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT
    else
        unset RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT 2>/dev/null || true
    fi
    return 0
}

# 导出 rustup 与 cargo 的家目录变量。
rust_apply_home_env() {
    rust_ahh_root=$(lang_default_root)
    RUSTUP_HOME="$rust_ahh_root/rust"
    CARGO_HOME="$rust_ahh_root/cargo"
    export RUSTUP_HOME CARGO_HOME
    return 0
}

# 取 rustup-init 的官方校验值：镜像站不提供 .sha256，因此固定从官方站点获取。
rust_init_checksum() {
    rust_ic_triple=$1
    rust_ic_sum=$(lang_cache_fetch "rustup-init-$rust_ic_triple.sha256" \
        "$LINUXAPP_LANG_RUST_OFFICIAL/rustup/dist/$rust_ic_triple/rustup-init.sha256" 2>/dev/null \
        | awk 'NF >= 1 { print $1; exit }')
    if [ -z "$rust_ic_sum" ]; then
        rust_ic_sum=$(lang_cache_fetch "rustup-init-alt-$rust_ic_triple.sha256" \
            "$LINUXAPP_LANG_RUST_MIRROR_ALT/rustup/dist/$rust_ic_triple/rustup-init.sha256" 2>/dev/null \
            | awk 'NF >= 1 { print $1; exit }')
    fi
    [ -n "$rust_ic_sum" ] || return 1
    printf '%s\n' "$rust_ic_sum"
    return 0
}

# 默认 toolchain，读取 rustup 的 settings.toml。
rust_default_toolchain() {
    rust_dt_settings=$(lang_default_root)/rust/settings.toml
    [ -f "$rust_dt_settings" ] || return 1
    rust_dt_value=$(sed -n 's/^default_toolchain[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$rust_dt_settings" | sed -n '1p')
    [ -n "$rust_dt_value" ] || return 1
    printf '%s\n' "$rust_dt_value"
    return 0
}

# ---------------------------------------------------------------- 安装与更新

rust_download_init() {
    rust_di_source=$1
    rust_di_triple=$2
    rust_di_url=$(rust_init_url "$rust_di_source" "$rust_di_triple")
    rust_di_file=$LINUXAPP_LANG_STAGING/rustup-init
    if ! lang_download "$rust_di_url" "$rust_di_file"; then
        lang_warn '首选源下载失败，改用备用源重试。'
        if [ "$rust_di_source" = mirror ]; then
            rust_di_url=$(rust_init_url official "$rust_di_triple")
        else
            rust_di_url=$(rust_init_url mirror "$rust_di_triple")
        fi
        if ! lang_download "$rust_di_url" "$rust_di_file"; then
            lang_fail '国内镜像与官方源都无法下载 rustup-init，请检查网络后重试。'
            return 1
        fi
    fi
    chmod 700 "$rust_di_file" 2>/dev/null || true
    rust_di_sum=$(rust_init_checksum "$rust_di_triple") || rust_di_sum=''
    if [ -n "$rust_di_sum" ]; then
        if ! lang_verify_sha256 "$rust_di_file" "$rust_di_sum"; then
            rm -f "$rust_di_file" 2>/dev/null || true
            return 1
        fi
    else
        lang_warn '未能从官方站点获取 rustup-init 校验值（镜像站不提供 .sha256 文件）。'
        if [ -n "${LINUXAPP_LANG_SKIP_CHECKSUM:-}" ]; then
            lang_warn '已按 LINUXAPP_LANG_SKIP_CHECKSUM 设置跳过校验。'
        elif lang_has_tty && lang_confirm '是否跳过校验继续安装？' n; then
            lang_warn '已跳过校验继续安装。'
        else
            lang_fail '已中止安装；确认要跳过校验时请设置 LINUXAPP_LANG_SKIP_CHECKSUM=1。'
            return 1
        fi
    fi
    return 0
}

rust_install() {
    lang_require_commands tar || return 1
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        lang_fail '系统中找不到 curl 或 wget，无法下载 rustup-init。请先安装 curl 或 wget。'
        return 1
    fi
    rust_in_triple=$(rust_triple) || {
        lang_fail '当前 CPU 架构不受支持，仅支持 x86_64 与 aarch64。'
        return 1
    }
    rust_in_root=$(lang_default_root)
    # 「安装」的幂等守卫：Rust 工具链已存在时不再进入安装向导，也不再顺手联网更新。
    # 软件模块的依赖联动会调用本模块的 install 动作，若每次都触发更新，联动会变慢且在无终端
    # 场景下会因为缺少交互输入直接失败；需要升级时请显式选择「更新」。
    # LINUXAPP_LANG_FORCE_INSTALL=1 时跳过本守卫，继续用 rustup-init 重新安装。
    if [ "${LINUXAPP_LANG_FORCE_INSTALL:-0}" != 1 ] && [ -x "$rust_in_root/cargo/bin/rustup" ]; then
        lang_info 'Rust 工具链已安装，无需重复安装。'
        lang_out '如需升级工具链请选择「更新」；确实要重装时，请设置 LINUXAPP_LANG_FORCE_INSTALL=1 后重试。'
        return 0
    fi
    mkdir -p "$rust_in_root/rust" "$rust_in_root/cargo" 2>/dev/null || {
        lang_fail "无法创建安装目录：$rust_in_root"
        return 1
    }
    LINUXAPP_LANG_STAGING=$rust_in_root/rust/.staging.$$
    rm -rf "$LINUXAPP_LANG_STAGING" 2>/dev/null || true
    mkdir -p "$LINUXAPP_LANG_STAGING" 2>/dev/null || {
        lang_fail "无法创建临时目录：$LINUXAPP_LANG_STAGING"
        return 1
    }

    lang_source_choose || return 1
    rust_in_source=$LANG_SOURCE
    rust_in_profile=${LINUXAPP_LANG_RUST_PROFILE:-default}
    rust_in_toolchain=${LINUXAPP_LANG_RUST_TOOLCHAIN:-stable}
    if [ "$rust_in_source" = mirror ]; then
        lang_out "安装源：国内镜像（$LINUXAPP_LANG_RUST_MIRROR）"
    else
        lang_out "安装源：官方源（$LINUXAPP_LANG_RUST_OFFICIAL）"
    fi
    lang_out "将安装 rustup，并安装工具链：$rust_in_toolchain（profile：$rust_in_profile）"
    lang_out '首次安装需要下载工具链，耗时较长，请耐心等待。'
    lang_confirm '确认开始安装吗？' y || {
        lang_info '已取消安装。'
        return 0
    }
    rust_download_init "$rust_in_source" "$rust_in_triple" || return 1
    rust_apply_mirror_env "$rust_in_source"
    rust_apply_home_env
    lang_info '正在执行 rustup 安装器...'
    if ! "$LINUXAPP_LANG_STAGING/rustup-init" -y --no-modify-path \
        --profile "$rust_in_profile" --default-toolchain "$rust_in_toolchain" > /dev/null 2>&1; then
        lang_fail 'rustup 安装失败，请检查上方错误信息或稍后重试。'
        lang_out '可尝试手工执行以下命令排查：'
        lang_out "  RUSTUP_HOME=$RUSTUP_HOME CARGO_HOME=$CARGO_HOME $LINUXAPP_LANG_STAGING/rustup-init -y --no-modify-path"
        return 1
    fi
    if ! lang_env_sync; then
        lang_fail '环境变量注入失败。'
        return 1
    fi
    lang_ok "Rust 工具链已安装到 $rust_in_root/cargo"
    lang_env_hint
    rust_report_version
    if [ "$rust_in_source" = mirror ]; then
        rust_ecosystem_setup
    fi
    return 0
}

rust_update() {
    rust_up_root=$(lang_default_root)
    if [ ! -x "$rust_up_root/cargo/bin/rustup" ]; then
        lang_warn 'Rust 工具链尚未安装，请先执行「安装」。'
        return 1
    fi
    lang_source_choose || return 1
    rust_up_source=$LANG_SOURCE
    if [ "$rust_up_source" = mirror ]; then
        lang_out "更新源：国内镜像（$LINUXAPP_LANG_RUST_MIRROR）"
    else
        lang_out "更新源：官方源（$LINUXAPP_LANG_RUST_OFFICIAL）"
    fi
    rust_apply_mirror_env "$rust_up_source"
    rust_apply_home_env
    lang_info '正在更新 Rust 工具链...'
    if ! "$rust_up_root/cargo/bin/rustup" update > /dev/null 2>&1; then
        lang_fail 'rustup update 执行失败，请检查网络后重试。'
        return 1
    fi
    lang_env_sync >/dev/null 2>&1 || true
    lang_ok 'Rust 工具链已更新到最新版本。'
    rust_report_version
    return 0
}

# cargo 配置文件路径：随 CARGO_HOME 一起放在安装根目录，卸载时一并清理。
rust_cargo_config_file() {
    printf '%s/cargo/config.toml\n' "$(lang_default_root)"
}

# 已安装的工具链名称列表（rustup 的 toolchains 目录名）。
rust_toolchain_list() {
    rust_tl_dir=$(lang_default_root)/rust/toolchains
    [ -d "$rust_tl_dir" ] || return 0
    for rust_tl_item in "$rust_tl_dir"/*; do
        [ -d "$rust_tl_item" ] || continue
        printf '%s\n' "${rust_tl_item##*/}"
    done
    return 0
}

# 从候选工具链中挑选新的默认工具链：优先 stable，否则取第一个。
rust_pick_default() {
    rust_pd_stable=$(printf '%s\n' "$1" | grep '^stable' | sed -n '1p')
    if [ -n "$rust_pd_stable" ]; then
        printf '%s\n' "$rust_pd_stable"
        return 0
    fi
    printf '%s\n' "$1" | sed -n '1p'
    return 0
}

# 国内源安装后询问是否写入 cargo 国内源。
rust_ecosystem_setup() {
    lang_ecosystem_choose "是否把 crates.io 源设置为国内镜像（$LINUXAPP_LANG_CARGO_MIRROR）？"
    if [ "$LANG_ECOSYSTEM" != 1 ]; then
        return 0
    fi
    rust_es_file=$(rust_cargo_config_file)
    if lang_cargo_mirror_enable "$rust_es_file"; then
        lang_ok "cargo 国内源已写入：$rust_es_file"
        [ -n "${LANG_BACKUP:-}" ] && lang_out "原文件已备份为：$LANG_BACKUP"
    else
        lang_warn 'cargo 国内源写入失败，已跳过。'
    fi
    return 0
}

rust_report_version() {
    rust_rv_root=$(lang_default_root)
    if [ -x "$rust_rv_root/cargo/bin/rustc" ]; then
        rust_rv_out=$(RUSTUP_HOME="$rust_rv_root/rust" CARGO_HOME="$rust_rv_root/cargo" \
            "$rust_rv_root/cargo/bin/rustc" --version 2>&1 | sed -n '1p')
        lang_ok "验证结果：$rust_rv_out"
    else
        lang_warn "未找到可执行文件：$rust_rv_root/cargo/bin/rustc"
    fi
    return 0
}

# ---------------------------------------------------------------- 动作实现

# 卸载：可选择卸载某个工具链，输入 a 表示卸载全部工具链。
rust_uninstall() {
    rust_un_root=$(lang_default_root)
    rust_un_home_file=${HOME:-.}/.cargo/config.toml
    rust_un_file=$(rust_cargo_config_file)
    rust_un_versions=$(rust_toolchain_list)
    rust_un_current=$(rust_default_toolchain 2>/dev/null || true)

    rust_un_has=0
    [ -d "$rust_un_root/rust" ] && rust_un_has=1
    [ -d "$rust_un_root/cargo" ] && rust_un_has=1
    if [ -f "$rust_un_file" ] && grep -qF "# >>> $LINUXAPP_CARGO_MARKER >>>" "$rust_un_file" 2>/dev/null; then
        rust_un_has=1
    fi
    if [ "$rust_un_has" -eq 0 ]; then
        lang_info 'Rust 工具链尚未安装，无需卸载。'
        return 0
    fi

    rust_un_scope=all
    rust_un_target=''
    if [ -n "$rust_un_versions" ]; then
        lang_uninstall_choose 'Rust 工具链' "$rust_un_versions" "$rust_un_current" || {
            lang_info '已取消卸载。'
            return 0
        }
        rust_un_scope=$LANG_UNINSTALL_SCOPE
        rust_un_target=$LANG_UNINSTALL_VERSION
    fi

    if [ "$rust_un_scope" = one ]; then
        rust_un_rest=$(printf '%s\n' "$rust_un_versions" | grep -vxF "$rust_un_target")
        lang_out "将删除工具链：$rust_un_target"
        if [ "$rust_un_target" = "$rust_un_current" ]; then
            lang_warn '该工具链是当前的默认工具链。'
            if [ -n "$rust_un_rest" ]; then
                lang_out "卸载后将把默认工具链切换为：$(rust_pick_default "$rust_un_rest")"
            fi
        fi
        if [ -z "$rust_un_rest" ]; then
            lang_out "这是最后一个工具链，卸载后将一并清理 RUSTUP_HOME（$rust_un_root/rust）与 CARGO_HOME（$rust_un_root/cargo）"
        fi
        lang_confirm "确认卸载 Rust 工具链 $rust_un_target 吗？" n || {
            lang_info '已取消卸载。'
            return 0
        }
        rust_apply_home_env
        if [ "$rust_un_target" = "$rust_un_current" ] && [ -n "$rust_un_rest" ]; then
            rust_un_new=$(rust_pick_default "$rust_un_rest")
            lang_info "先把默认工具链切换为 $rust_un_new"
            if ! "$rust_un_root/cargo/bin/rustup" default "$rust_un_new" > /dev/null 2>&1; then
                lang_warn '默认工具链切换失败，将继续卸载所选工具链。'
            fi
        fi
        if [ -x "$rust_un_root/cargo/bin/rustup" ] \
            && "$rust_un_root/cargo/bin/rustup" toolchain uninstall "$rust_un_target" > /dev/null 2>&1; then
            lang_ok "Rust 工具链 $rust_un_target 已卸载。"
        else
            rust_un_dir=$rust_un_root/rust/toolchains/$rust_un_target
            lang_warn 'rustup 卸载未成功，改为直接删除工具链目录。'
            if ! rm -rf "$rust_un_dir" 2>/dev/null; then
                lang_fail "删除失败：$rust_un_dir（请检查权限）"
                return 1
            fi
            lang_ok "Rust 工具链 $rust_un_target 已删除。"
        fi
        if [ -n "$rust_un_rest" ]; then
            lang_env_sync >/dev/null 2>&1 || true
            rust_un_now=$(rust_default_toolchain 2>/dev/null || true)
            [ -n "$rust_un_now" ] && lang_out "当前默认工具链：$rust_un_now"
            rust_report_version
            return 0
        fi
        if ! rm -rf "$rust_un_root/rust" "$rust_un_root/cargo" 2>/dev/null; then
            lang_fail "删除失败：$rust_un_root/rust 或 $rust_un_root/cargo（请检查权限）"
            return 1
        fi
        if [ -f "$rust_un_home_file" ] && grep -qF "# >>> $LINUXAPP_CARGO_MARKER >>>" "$rust_un_home_file" 2>/dev/null; then
            if lang_cargo_mirror_disable "$rust_un_home_file"; then
                lang_ok "已移除用户目录下的 cargo 国内源配置：$rust_un_home_file"
            else
                lang_warn "cargo 配置清理失败，请手工检查：$rust_un_home_file"
            fi
        fi
        lang_env_sync >/dev/null 2>&1 || true
        lang_ok 'Rust 工具链已全部卸载，安装目录已清理。'
        lang_env_hint
        return 0
    fi

    lang_out "将删除 RUSTUP_HOME：$rust_un_root/rust"
    lang_out "将删除 CARGO_HOME：$rust_un_root/cargo"
    if [ -n "$rust_un_versions" ]; then
        lang_out "包含工具链：$(printf '%s' "$rust_un_versions" | tr '\n' ',' | sed -e 's/,$//' -e 's/,/、/g')"
    fi
    if [ -f "$rust_un_file" ] && grep -qF "# >>> $LINUXAPP_CARGO_MARKER >>>" "$rust_un_file" 2>/dev/null; then
        lang_out "将移除 cargo 国内源配置：$rust_un_file"
    fi
    if [ -d "${HOME:-.}/.rustup" ] || [ -d "${HOME:-.}/.cargo" ]; then
        lang_warn '检测到用户主目录下已存在 .rustup 或 .cargo，本模块不会删除这些内容。'
    fi
    lang_confirm '确认卸载 Rust 工具链吗？' n || {
        lang_info '已取消卸载。'
        return 0
    }
    if ! rm -rf "$rust_un_root/rust" "$rust_un_root/cargo" 2>/dev/null; then
        lang_fail "删除失败：$rust_un_root/rust 或 $rust_un_root/cargo（请检查权限）"
        return 1
    fi
    if [ -f "$rust_un_home_file" ] && grep -qF "# >>> $LINUXAPP_CARGO_MARKER >>>" "$rust_un_home_file" 2>/dev/null; then
        if lang_cargo_mirror_disable "$rust_un_home_file"; then
            lang_ok "已移除用户目录下的 cargo 国内源配置：$rust_un_home_file"
        else
            lang_warn "cargo 配置清理失败，请手工检查：$rust_un_home_file"
        fi
    fi
    lang_env_sync >/dev/null 2>&1 || true
    lang_ok 'Rust 工具链已卸载。'
    lang_env_hint
    return 0
}

rust_status() {
    rust_st_root=$(lang_default_root)
    if [ ! -d "$rust_st_root/rust/toolchains" ]; then
        printf '未安装|-|尚未安装 Rust 工具链，安装时可选择国内镜像或官方源\n'
        return 0
    fi
    rust_st_default=$(rust_default_toolchain 2>/dev/null || true)
    rust_st_list=''
    for rust_st_item in "$rust_st_root/rust/toolchains"/*; do
        [ -d "$rust_st_item" ] || continue
        rust_st_name=$(basename "$rust_st_item")
        if [ -z "$rust_st_list" ]; then
            rust_st_list=$rust_st_name
        else
            rust_st_list="$rust_st_list、$rust_st_name"
        fi
    done
    [ -n "$rust_st_list" ] || rust_st_list='未知'
    if [ -n "$rust_st_default" ]; then
        printf '已安装|%s|RUSTUP_HOME=%s/rust，toolchain：%s\n' \
            "$rust_st_default" "$rust_st_root" "$rust_st_list"
        return 0
    fi
    printf '未安装|-|RUSTUP_HOME=%s/rust 已存在但没有默认工具链\n' "$rust_st_root"
    return 0
}

rust_versions() {
    rust_vs_default=$(rust_default_toolchain 2>/dev/null || true)
    rust_toolchain_list | while IFS= read -r rust_vs_name; do
        [ -n "$rust_vs_name" ] || continue
        if [ "$rust_vs_name" = "$rust_vs_default" ]; then
            printf '%s|current\n' "$rust_vs_name"
        else
            printf '%s|installed\n' "$rust_vs_name"
        fi
    done
    return 0
}

# ---------------------------------------------------------------- 动作分发

rust_main() {
    rust_action=${1:-status}
    case "$rust_action" in
        capabilities) printf '%s\n' 'versions update repair' ;;
        versions) rust_versions ;;
        status) rust_status ;;
        install) rust_install ;;
        update) rust_update ;;
        repair) lang_env_repair ;;
        uninstall) rust_uninstall ;;
        switch)
            lang_fail 'Rust 模块不提供版本切换，请使用 rustup toolchain 或「更新」命令管理工具链。'
            return 2
            ;;
        start|stop)
            lang_fail '语言模块不支持启动和停止。'
            return 2
            ;;
        *)
            lang_fail "未知的语言动作：$rust_action"
            return 2
            ;;
    esac
}

trap 'lang_cleanup; lang_out ""; lang_warn "Rust 操作已被 Ctrl+C 中断，临时文件已清理。"; exit 130' INT
trap 'lang_cleanup' TERM HUP

rust_main "$@"
rust_exit_code=$?
lang_cleanup
exit "$rust_exit_code"

# Last updated: 2026-09-12 05:19
