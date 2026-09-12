#!/bin/sh
# shellcheck disable=SC2034,SC2016

# DeepSeek Harness 软件模块。
#
# 作用：把 DeepSeek Harness Web GUI 注册为 systemd 系统服务并保证开机自启。
# 版本策略：安装与更新使用 npm 获取「指定的精确版本或最新版本」，但服务始终以绝对路径调用
#           某个精确版本，因此不会随上游发布自动升级；只有手动执行「更新」才会切换版本。
# 状态来源：应用状态直接取 systemd 的服务状态（is-active / is-enabled），不做额外探活。
# 失败语义：更新或启动失败时不自动回滚，打印报错与日志摘要，状态标记为「异常」，
#           并在菜单中额外提供「回滚到上一版本」；应用启动成功后清理历史版本与回滚点。
# 语言联动：声明依赖 nodejs，框架在安装、更新、启动前会先确保 Node.js 语言环境就绪。
#
# 动作：requires、extras、status、install [版本|标签]、start、stop、update [版本|标签]、
#       rollback、url、repair、log、uninstall

APP_TITLE='DeepSeek Harness'
APP_UNIT='linuxapp-deepseek-harness.service'
APP_MIN_NODE_MAJOR=20
APP_WRAPPER_MARK='linuxapp-dsh-wrapper'
DSH_PACKAGE='@deepseek-ai/dsh'

# 载入共享库：优先使用框架导出的仓库根目录，其次按脚本相对位置定位。
dsh_module_dir=$(CDPATH='' cd "$(dirname "$0")" 2>/dev/null && pwd) || dsh_module_dir='.'
APP_MODULE_PATH="$dsh_module_dir/module.sh"

dsh_lib_loaded=0
for dsh_lib_candidate in "${LINUXAPP_ROOT:-}/lib/lang.sh" "$dsh_module_dir/../../../lib/lang.sh"; do
    if [ -n "$dsh_lib_candidate" ] && [ -r "$dsh_lib_candidate" ]; then
        # shellcheck disable=SC1090
        . "$dsh_lib_candidate"
        dsh_lib_loaded=1
        break
    fi
done
if [ "$dsh_lib_loaded" -ne 1 ]; then
    printf '%s\n' '[错误] 找不到共享库 lib/lang.sh，请在 LinuxApp 仓库内运行本模块。' >&2
    exit 1
fi

# 语言依赖联动库属于可选项：缺少时只跳过「自动安装依赖语言」，模块自身仍会检查 Node.js。
dsh_dep_loaded=0
for dsh_dep_candidate in "${LINUXAPP_ROOT:-}/lib/dependency.sh" "$dsh_module_dir/../../../lib/dependency.sh"; do
    if [ -n "$dsh_dep_candidate" ] && [ -r "$dsh_dep_candidate" ]; then
        # shellcheck disable=SC1090
        . "$dsh_dep_candidate"
        dsh_dep_loaded=1
        break
    fi
done

DSH_STAGING=''

dsh_cleanup() {
    if [ -n "$DSH_STAGING" ] && [ -d "$DSH_STAGING" ]; then
        rm -rf "$DSH_STAGING" 2>/dev/null || true
    fi
    DSH_STAGING=''
}

# ---------------------------------------------------------------- 路径与配置

dsh_root() {
    printf '%s\n' "${LINUXAPP_DSH_ROOT:-/opt/linuxapp/apps/deepseek-harness}"
}

dsh_versions_dir() {
    printf '%s/versions\n' "$(dsh_root)"
}

dsh_version_dir() {
    printf '%s/%s\n' "$(dsh_versions_dir)" "$1"
}

dsh_bin_js() {
    printf '%s/node_modules/%s/lib/bin.js\n' "$(dsh_version_dir "$1")" "$DSH_PACKAGE"
}

dsh_state_file() {
    printf '%s/state\n' "$(dsh_root)"
}

dsh_cache_dir() {
    printf '%s/cache\n' "$(dsh_root)"
}

dsh_log_dir() {
    printf '%s/logs\n' "$(dsh_root)"
}

dsh_unit_dir() {
    printf '%s\n' "${LINUXAPP_DSH_UNIT_DIR:-/etc/systemd/system}"
}

dsh_unit_path() {
    printf '%s/%s\n' "$(dsh_unit_dir)" "$APP_UNIT"
}

dsh_systemctl() {
    printf '%s\n' "${LINUXAPP_DSH_SYSTEMCTL:-systemctl}"
}

dsh_journalctl() {
    printf '%s\n' "${LINUXAPP_DSH_JOURNALCTL:-journalctl}"
}

dsh_wrapper_path() {
    printf '%s\n' "${LINUXAPP_DSH_WRAPPER:-/usr/local/bin/linuxapp-dsh}"
}

# Node.js 运行时目录：默认使用语言模块安装的当前版本，可用环境变量覆盖（测试与自建环境）。
dsh_node_bin() {
    if [ -n "${LINUXAPP_DSH_NODE_BIN:-}" ]; then
        printf '%s\n' "$LINUXAPP_DSH_NODE_BIN"
        return 0
    fi
    printf '%s/nodejs/current/bin\n' "$(lang_default_root)"
}

dsh_npm_bin() {
    if [ -n "${LINUXAPP_DSH_NPM_BIN:-}" ]; then
        printf '%s\n' "$LINUXAPP_DSH_NPM_BIN"
        return 0
    fi
    printf '%s/npm\n' "$(dsh_node_bin)"
}

# 安装源：环境变量优先，交互环境下询问是否使用国内 npm 镜像。
dsh_source_choose() {
    if [ -n "${LINUXAPP_DSH_NPM_SOURCE:-}" ]; then
        case "$LINUXAPP_DSH_NPM_SOURCE" in
            mirror|official)
                DSH_SOURCE=$LINUXAPP_DSH_NPM_SOURCE
                return 0
                ;;
            *)
                lang_fail "环境变量 LINUXAPP_DSH_NPM_SOURCE 取值无效：$LINUXAPP_DSH_NPM_SOURCE（应为 mirror 或 official）。"
                return 1
                ;;
        esac
    fi
    if [ -n "${LINUXAPP_DSH_NPM_REGISTRY:-}" ]; then
        DSH_SOURCE=custom
        return 0
    fi
    if ! lang_has_tty; then
        DSH_SOURCE=official
        return 0
    fi
    if dsh_confirm '是否使用国内 npm 镜像（https://registry.npmmirror.com）？' y; then
        DSH_SOURCE=mirror
    else
        DSH_SOURCE=official
    fi
    return 0
}

# 实际使用的 npm registry 地址。
dsh_registry() {
    if [ -n "${LINUXAPP_DSH_NPM_REGISTRY:-}" ]; then
        printf '%s\n' "$LINUXAPP_DSH_NPM_REGISTRY"
        return 0
    fi
    case "${DSH_SOURCE:-official}" in
        mirror) printf '%s\n' 'https://registry.npmmirror.com' ;;
        *) printf '%s\n' 'https://registry.npmjs.org' ;;
    esac
}

# ---------------------------------------------------------------- 状态文件

dsh_state_get() {
    dsh_sg_file=$(dsh_state_file)
    [ -r "$dsh_sg_file" ] || return 1
    dsh_sg_value=$(sed -n "s/^$1=//p" "$dsh_sg_file" 2>/dev/null | sed -n '1p')
    [ -n "$dsh_sg_value" ] || return 1
    printf '%s\n' "$dsh_sg_value"
}

# 原子写入一个键：先读旧内容，再整体替换，避免框架读取状态时看到半截内容。
dsh_state_set() {
    dsh_ss_file=$(dsh_state_file)
    mkdir -p "$(dsh_root)" 2>/dev/null || return 1
    dsh_ss_tmp="$dsh_ss_file.tmp.$$"
    if [ -f "$dsh_ss_file" ]; then
        if [ ! -r "$dsh_ss_file" ]; then
            lang_warn "无法读取状态文件：$dsh_ss_file"
            return 1
        fi
        grep -v "^$1=" "$dsh_ss_file" > "$dsh_ss_tmp" 2>/dev/null || : > "$dsh_ss_tmp"
    else
        : > "$dsh_ss_tmp" || return 1
    fi
    printf '%s=%s\n' "$1" "$2" >> "$dsh_ss_tmp" || {
        rm -f "$dsh_ss_tmp" 2>/dev/null || true
        return 1
    }
    chmod 600 "$dsh_ss_tmp" 2>/dev/null || true
    if ! mv "$dsh_ss_tmp" "$dsh_ss_file" 2>/dev/null; then
        rm -f "$dsh_ss_tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}

dsh_cfg_host() {
    dsh_ch_value=$(dsh_state_get host 2>/dev/null || true)
    [ -n "$dsh_ch_value" ] || dsh_ch_value=${LINUXAPP_DSH_HOST:-127.0.0.1}
    printf '%s\n' "$dsh_ch_value"
}

dsh_cfg_port() {
    dsh_cp_value=$(dsh_state_get port 2>/dev/null || true)
    [ -n "$dsh_cp_value" ] || dsh_cp_value=${LINUXAPP_DSH_PORT:-3080}
    printf '%s\n' "$dsh_cp_value"
}

dsh_cfg_trusted() {
    dsh_ct_value=$(dsh_state_get trusted_host 2>/dev/null || true)
    [ -n "$dsh_ct_value" ] || dsh_ct_value=${LINUXAPP_DSH_TRUSTED_HOST:-}
    printf '%s\n' "$dsh_ct_value"
}

dsh_cfg_home() {
    dsh_cd_value=$(dsh_state_get dsh_home 2>/dev/null || true)
    [ -n "$dsh_cd_value" ] || dsh_cd_value=${LINUXAPP_DSH_HOME:-${HOME:-/root}/.dsh}
    printf '%s\n' "$dsh_cd_value"
}

dsh_cfg_workspace() {
    dsh_cw_value=$(dsh_state_get workspace 2>/dev/null || true)
    [ -n "$dsh_cw_value" ] || dsh_cw_value=${LINUXAPP_DSH_WORKSPACE:-${HOME:-/root}}
    printf '%s\n' "$dsh_cw_value"
}

# 单元里使用的 Node.js 目录：安装时记录在状态里，避免之后语言安装根变化导致服务失效。
dsh_cfg_node_bin() {
    dsh_cnbin_value=$(dsh_state_get node_bin 2>/dev/null || true)
    [ -n "$dsh_cnbin_value" ] || dsh_cnbin_value=$(dsh_node_bin)
    printf '%s\n' "$dsh_cnbin_value"
}

dsh_auto_yes() {
    case "${LINUXAPP_DSH_YES:-${LINUXAPP_LANG_YES:-0}}" in
        1) return 0 ;;
    esac
    return 1
}

# 统一的确认入口：支持 LINUXAPP_DSH_YES=1 自动化跳过。
dsh_confirm() {
    if dsh_auto_yes; then
        lang_out "$1（已按 LINUXAPP_DSH_YES=1 自动确认）"
        return 0
    fi
    lang_confirm "$1" "${2:-n}"
}

# ---------------------------------------------------------------- 前置检查

dsh_systemd_available() {
    if [ -z "${LINUXAPP_DSH_SYSTEMCTL:-}" ] && [ ! -d /run/systemd/system ]; then
        return 1
    fi
    command -v "$(dsh_systemctl)" >/dev/null 2>&1 || return 1
    return 0
}

dsh_preflight() {
    if [ "$(id -u 2>/dev/null)" != 0 ]; then
        lang_fail '本模块需要 root 权限（注册 systemd 系统服务并设置开机自启）。请使用 sudo 运行。'
        return 1
    fi
    if ! dsh_systemd_available; then
        lang_fail '当前系统没有可用的 systemd（缺少 /run/systemd/system 或 systemctl），无法注册开机自启服务。'
        return 1
    fi
    return 0
}

# 只探测 Node.js 版本，不输出提示。0 满足要求，2 版本过低，其它为不可用。
dsh_node_probe() {
    dsh_np_node=$(dsh_node_bin)/node
    [ -x "$dsh_np_node" ] || return 1
    dsh_np_raw=$("$dsh_np_node" -v 2>/dev/null | sed -n '1p')
    DSH_NODE_VERSION=$(printf '%s' "$dsh_np_raw" | sed -e 's/^[vV]//')
    dsh_np_major=${DSH_NODE_VERSION%%.*}
    case "$dsh_np_major" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "$dsh_np_major" -lt "$APP_MIN_NODE_MAJOR" ]; then
        return 2
    fi
    return 0
}

# 检查 Node.js 运行时并给出中文提示。
dsh_check_node() {
    DSH_NODE_VERSION=''
    dsh_cn_node=$(dsh_node_bin)/node
    if [ ! -x "$dsh_cn_node" ]; then
        lang_fail "找不到 Node.js：$dsh_cn_node"
        lang_out "请先在「应用管理 → 语言模块 → Node.js 运行时」中安装 Node.js（本应用需要 Node.js $APP_MIN_NODE_MAJOR 或更高版本）。"
        return 1
    fi
    dsh_node_probe
    dsh_cn_code=$?
    case "$dsh_cn_code" in
        0) return 0 ;;
        2)
            lang_fail "Node.js 版本过低：当前 $DSH_NODE_VERSION，本应用需要 $APP_MIN_NODE_MAJOR 或更高版本。"
            lang_out '请在「应用管理 → 语言模块 → Node.js 运行时」中执行「更新」后重试。'
            return 1
            ;;
        *)
            lang_fail "无法识别 Node.js 版本（$dsh_cn_node -v 输出异常）。"
            return 1
            ;;
    esac
}

# 语言依赖联动：先让框架库确保依赖语言模块已安装，再校验 Node.js 版本。
dsh_ensure_language_deps() {
    if [ "$dsh_dep_loaded" -eq 1 ]; then
        if ! dependency_ensure "$APP_TITLE" "$APP_MODULE_PATH"; then
            return 1
        fi
    fi
    dsh_check_node
}

# 安全删除：只删除绝对路径，并拒绝明显危险的目标。
dsh_safe_rm_rf() {
    dsh_sr_target=$1
    case "$dsh_sr_target" in
        ''|/|/root|/home|/usr|/etc|/var|/opt)
            lang_warn "出于安全考虑，已跳过删除：${dsh_sr_target:-<空路径>}"
            return 1
            ;;
    esac
    case "$dsh_sr_target" in
        /*) ;;
        *)
            lang_warn "拒绝删除非绝对路径：$dsh_sr_target"
            return 1
            ;;
    esac
    if ! rm -rf "$dsh_sr_target" 2>/dev/null; then
        lang_warn "删除失败（请检查权限）：$dsh_sr_target"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- 端口与监听

dsh_port_in_use() {
    dsh_piu_port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":$dsh_piu_port" '$4 ~ (p "$") { found = 1 } END { exit(found ? 0 : 1) }'
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk -v p=":$dsh_piu_port" '$4 ~ (p "$") { found = 1 } END { exit(found ? 0 : 1) }'
        return $?
    fi
    return 1
}

# 选择监听地址与端口。结果写入 DSH_LISTEN_HOST / DSH_LISTEN_PORT / DSH_TRUSTED_HOST。
dsh_choose_listen() {
    dsh_cl_host=${LINUXAPP_DSH_HOST:-}
    dsh_cl_port=${LINUXAPP_DSH_PORT:-}
    if [ -z "$dsh_cl_host" ]; then
        dsh_cl_host=127.0.0.1
        dsh_cl_lan=0
        if dsh_auto_yes; then
            # 自动确认不等于同意暴露服务：内网访问必须由用户显式开启。
            lang_out '已按自动确认模式使用默认监听地址 127.0.0.1（自动确认不会开启内网访问）。'
        elif lang_has_tty; then
            lang_out '默认只允许本机访问（127.0.0.1）。'
            if lang_confirm '是否允许内网访问？（会绑定内网地址，内网设备可直接访问该界面并执行代码，请确认风险）' n; then
                dsh_cl_lan=1
            fi
        fi
        if [ "$dsh_cl_lan" -eq 1 ]; then
            dsh_cl_ips=$(ip -4 addr show 2>/dev/null | sed -n 's/.*inet \([0-9][0-9.]*\)\/.*/\1/p' | grep -v '^127\.' | sort -u)
            dsh_cl_count=$(printf '%s\n' "$dsh_cl_ips" | grep -c .)
            if [ "$dsh_cl_count" -eq 0 ]; then
                lang_warn '未检测到内网 IPv4 地址，继续使用 127.0.0.1。'
            elif [ "$dsh_cl_count" -eq 1 ]; then
                dsh_cl_host=$dsh_cl_ips
                lang_out "已选择内网地址：$dsh_cl_host"
            else
                lang_out '可绑定的内网地址：'
                dsh_cl_index=0
                for dsh_cl_ip in $dsh_cl_ips; do
                    dsh_cl_index=$((dsh_cl_index + 1))
                    lang_out "  $dsh_cl_index. $dsh_cl_ip"
                done
                if ! lang_choose_number '请输入编号' "$dsh_cl_index"; then
                    lang_warn '未选择内网地址，继续使用 127.0.0.1。'
                    dsh_cl_host=127.0.0.1
                else
                    dsh_cl_host=$(printf '%s\n' "$dsh_cl_ips" | sed -n "${LANG_CHOICE}p")
                fi
            fi
        fi
    fi

    if [ -z "$dsh_cl_port" ]; then
        dsh_cl_port=3080
        if lang_has_tty && ! dsh_auto_yes; then
            lang_read_value "请输入监听端口（直接回车使用 $dsh_cl_port）：" || return 1
            dsh_cl_reply=$(printf '%s' "$LANG_REPLY" | tr -d ' \t')
            [ -n "$dsh_cl_reply" ] && dsh_cl_port=$dsh_cl_reply
        fi
    fi
    case "$dsh_cl_port" in
        ''|*[!0-9]*)
            lang_fail "监听端口必须是数字：$dsh_cl_port"
            return 1
            ;;
    esac

    dsh_cl_try=0
    while dsh_port_in_use "$dsh_cl_port"; do
        lang_warn "端口 $dsh_cl_port 已被占用。"
        dsh_cl_try=$((dsh_cl_try + 1))
        if [ "$dsh_cl_try" -ge 5 ] || ! lang_has_tty || dsh_auto_yes; then
            lang_fail "请释放端口 $dsh_cl_port，或通过 LINUXAPP_DSH_PORT 指定其它端口后重试。"
            return 1
        fi
        lang_read_value '请输入其它端口：' || return 1
        dsh_cl_reply=$(printf '%s' "$LANG_REPLY" | tr -d ' \t')
        case "$dsh_cl_reply" in
            ''|*[!0-9]*)
                lang_warn '端口必须是数字。'
                continue
                ;;
        esac
        dsh_cl_port=$dsh_cl_reply
    done

    DSH_LISTEN_HOST=$dsh_cl_host
    DSH_LISTEN_PORT=$dsh_cl_port
    if [ -n "${LINUXAPP_DSH_TRUSTED_HOST:-}" ]; then
        DSH_TRUSTED_HOST=$LINUXAPP_DSH_TRUSTED_HOST
    else
        case "$dsh_cl_host" in
            127.0.0.1|localhost|::1) DSH_TRUSTED_HOST='' ;;
            *) DSH_TRUSTED_HOST="$dsh_cl_host:$dsh_cl_port" ;;
        esac
    fi
    return 0
}

# ---------------------------------------------------------------- 服务文件

dsh_write_unit() {
    dsh_wu_version=$1
    dsh_wu_binjs=$(dsh_bin_js "$dsh_wu_version")
    if [ ! -f "$dsh_wu_binjs" ]; then
        lang_fail "版本目录不完整，缺少入口文件：$dsh_wu_binjs"
        return 1
    fi
    dsh_wu_node=$(dsh_cfg_node_bin)/node
    if [ ! -x "$dsh_wu_node" ]; then
        lang_fail "找不到 Node.js 可执行文件：$dsh_wu_node（请先在语言模块中安装 Node.js）。"
        return 1
    fi
    dsh_wu_unit=$(dsh_unit_path)
    dsh_wu_home=$(dsh_cfg_home)
    dsh_wu_workspace=$(dsh_cfg_workspace)
    dsh_wu_node_bin=$(dsh_cfg_node_bin)
    dsh_wu_host=$(dsh_cfg_host)
    dsh_wu_port=$(dsh_cfg_port)
    dsh_wu_trusted=$(dsh_cfg_trusted)

    dsh_wu_exec="\"$dsh_wu_node\" \"$dsh_wu_binjs\" web --host \"$dsh_wu_host\" --port \"$dsh_wu_port\" --no-open"
    if [ -n "$dsh_wu_trusted" ]; then
        dsh_wu_exec="$dsh_wu_exec --trusted-host \"$dsh_wu_trusted\""
    fi

    mkdir -p "$(dsh_unit_dir)" 2>/dev/null || {
        lang_fail "无法创建服务目录：$(dsh_unit_dir)"
        return 1
    }
    dsh_wu_tmp="$dsh_wu_unit.tmp.$$"
    {
        printf '%s\n' '[Unit]'
        printf 'Description=%s Web GUI (linuxapp managed)\n' "$APP_TITLE"
        printf '%s\n' 'After=network-online.target'
        printf '%s\n' 'Wants=network-online.target'
        printf '%s\n' 'StartLimitIntervalSec=60'
        printf '%s\n' 'StartLimitBurst=3'
        printf '\n'
        printf '%s\n' '[Service]'
        printf '%s\n' 'Type=simple'
        printf '%s\n' 'User=root'
        printf 'WorkingDirectory=%s\n' "$dsh_wu_workspace"
        printf 'Environment=HOME=%s\n' "${HOME:-/root}"
        printf 'Environment=DSH_HOME=%s\n' "$dsh_wu_home"
        printf 'Environment=PATH=%s:%s/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' \
            "$dsh_wu_node_bin" "$dsh_wu_home"
        printf 'ExecStart=%s\n' "$dsh_wu_exec"
        printf '%s\n' 'Restart=on-failure'
        printf '%s\n' 'RestartSec=5'
        printf '%s\n' 'TimeoutStopSec=30'
        printf '%s\n' 'KillSignal=SIGTERM'
        printf '%s\n' 'StandardOutput=journal'
        printf '%s\n' 'StandardError=journal'
        printf '%s\n' 'SyslogIdentifier=linuxapp-dsh'
        printf '\n'
        printf '%s\n' '[Install]'
        printf '%s\n' 'WantedBy=multi-user.target'
    } > "$dsh_wu_tmp" 2>/dev/null || {
        rm -f "$dsh_wu_tmp" 2>/dev/null || true
        lang_fail "无法写入服务文件：$dsh_wu_unit"
        return 1
    }
    chmod 644 "$dsh_wu_tmp" 2>/dev/null || true
    if ! mv "$dsh_wu_tmp" "$dsh_wu_unit" 2>/dev/null; then
        rm -f "$dsh_wu_tmp" 2>/dev/null || true
        lang_fail "无法写入服务文件：$dsh_wu_unit"
        return 1
    fi
    if ! "$(dsh_systemctl)" daemon-reload; then
        lang_fail 'systemctl daemon-reload 失败，服务文件可能未生效。'
        return 1
    fi
    lang_ok "服务文件已更新：$dsh_wu_unit（启动版本：$dsh_wu_version）"
    return 0
}

# 写入命令包装脚本，便于在未加载环境变量的 shell 中管理插件（dsh plugin）。
dsh_write_wrapper() {
    dsh_ww_version=$1
    dsh_ww_path=$(dsh_wrapper_path)
    dsh_ww_dir=${dsh_ww_path%/*}
    dsh_ww_binjs=$(dsh_bin_js "$dsh_ww_version")
    [ -f "$dsh_ww_binjs" ] || return 0
    mkdir -p "$dsh_ww_dir" 2>/dev/null || return 0
    dsh_ww_tmp="$dsh_ww_path.tmp.$$"
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' "# $APP_WRAPPER_MARK：由 LinuxApp 的 DeepSeek Harness 软件模块生成，卸载时自动删除。"
        printf '%s\n' '# 作用：在未加载任何环境变量的 shell 中按精确版本调用 dsh（例如管理插件）。'
        printf 'DSH_HOME=%s\nexport DSH_HOME\n' "$(dsh_cfg_home)"
        printf 'PATH="%s:%s/bin:$PATH"\nexport PATH\n' "$(dsh_cfg_node_bin)" "$(dsh_cfg_home)"
        printf 'exec "%s" "%s" "$@"\n' "$(dsh_cfg_node_bin)/node" "$dsh_ww_binjs"
    } > "$dsh_ww_tmp" 2>/dev/null || {
        rm -f "$dsh_ww_tmp" 2>/dev/null || true
        return 0
    }
    chmod 755 "$dsh_ww_tmp" 2>/dev/null || true
    if mv "$dsh_ww_tmp" "$dsh_ww_path" 2>/dev/null; then
        lang_out "命令入口：$dsh_ww_path（例如：$dsh_ww_path plugin --profile web list）"
    else
        rm -f "$dsh_ww_tmp" 2>/dev/null || true
    fi
    return 0
}

# ---------------------------------------------------------------- 启动与就绪

# 查询服务的自动重启次数（systemd 不支持或取不到时返回空）。
dsh_service_restarts() {
    dsh_sr_value=$("$(dsh_systemctl)" show -p NRestarts --value "$APP_UNIT" 2>/dev/null | tr -d ' \t' | sed -n '1p')
    case "$dsh_sr_value" in
        ''|*[!0-9]*) printf '%s\n' '' ;;
        *) printf '%s\n' "$dsh_sr_value" ;;
    esac
}

dsh_start_service() {
    dsh_st_systemctl=$(dsh_systemctl)
    # 记录启动时刻，供随后从日志里只取本次启动打印的访问地址（token 每次启动都会变化）。
    DSH_START_EPOCH=$(date +%s 2>/dev/null || printf '')
    case "$DSH_START_EPOCH" in
        ''|*[!0-9]*) DSH_START_EPOCH='' ;;
    esac
    if ! "$dsh_st_systemctl" start "$APP_UNIT"; then
        lang_fail "systemctl start $APP_UNIT 执行失败。"
        DSH_START_EPOCH=''
        return 1
    fi
    dsh_st_wait=${LINUXAPP_DSH_WAIT:-30}
    case "$dsh_st_wait" in
        ''|*[!0-9]*) dsh_st_wait=30 ;;
    esac
    # 进程刚起来就崩溃时，systemctl is-active 会短暂返回 active。必须等一小段时间，
    # 确认服务仍在运行、且没有发生自动重启，才能算启动成功。
    dsh_st_settle=${LINUXAPP_DSH_SETTLE:-3}
    case "$dsh_st_settle" in
        ''|*[!0-9]*) dsh_st_settle=3 ;;
    esac
    dsh_st_elapsed=0
    dsh_st_state=''
    while [ "$dsh_st_elapsed" -lt "$dsh_st_wait" ]; do
        dsh_st_state=$("$dsh_st_systemctl" is-active "$APP_UNIT" 2>/dev/null || true)
        case "$dsh_st_state" in
            active)
                sleep "$dsh_st_settle"
                dsh_st_state=$("$dsh_st_systemctl" is-active "$APP_UNIT" 2>/dev/null || true)
                if [ "$dsh_st_state" = active ]; then
                    dsh_st_restarts=$(dsh_service_restarts)
                    if [ -z "$dsh_st_restarts" ] || [ "$dsh_st_restarts" = 0 ]; then
                        return 0
                    fi
                    lang_warn "服务启动后已自动重启 $dsh_st_restarts 次，继续观察是否稳定..."
                fi
                ;;
            failed) break ;;
        esac
        sleep 2
        dsh_st_elapsed=$((dsh_st_elapsed + 2))
    done
    dsh_st_state=$("$dsh_st_systemctl" is-active "$APP_UNIT" 2>/dev/null || true)
    if [ "$dsh_st_state" = active ]; then
        return 0
    fi
    lang_fail "服务未能在 ${dsh_st_wait} 秒内稳定运行（当前状态：${dsh_st_state:-未知}）。"
    case "$dsh_st_state" in
        activating|deactivating|reloading|unknown|'')
            # 结束自动重启循环，让服务停在一个可以人工处理的状态，而不是无限重启。
            "$dsh_st_systemctl" stop "$APP_UNIT" >/dev/null 2>&1 || true
            lang_warn '已停止自动重启循环，服务处于异常状态，等待你处理后再重新启动。'
            ;;
    esac
    return 1
}

# 失败诊断：保存并展示 systemctl status 与 journalctl 的最近内容。
dsh_failure_report() {
    dsh_fr_action=$1
    dsh_fr_dir=$(dsh_log_dir)
    mkdir -p "$dsh_fr_dir" 2>/dev/null || true
    dsh_fr_stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || printf 'unknown')
    dsh_fr_file="$dsh_fr_dir/${dsh_fr_action}-${dsh_fr_stamp}.log"
    {
        printf '%s\n' "== systemctl status $APP_UNIT =="
        "$(dsh_systemctl)" status "$APP_UNIT" --no-pager -l 2>&1 | sed -n '1,20p'
        printf '\n%s\n' "== journalctl -u $APP_UNIT =="
        "$(dsh_journalctl)" -u "$APP_UNIT" -n 40 --no-pager 2>&1
    } > "$dsh_fr_file" 2>/dev/null || true
    lang_warn "最近的服务日志（完整内容已保存到 $dsh_fr_file）："
    if [ -s "$dsh_fr_file" ]; then
        sed -n '1,25p' "$dsh_fr_file" | while IFS= read -r dsh_fr_line; do
            lang_out "  $dsh_fr_line"
        done
    else
        lang_out "  （没有取到日志，可手工执行：systemctl status $APP_UNIT）"
    fi
    return 0
}

# 访问地址里的 token 默认显示：被遮住用户就没法直接打开界面。
# 框架用 --hide-secrets 运行时 LINUXAPP_SHOW_SECRETS=0，或直接设置 LINUXAPP_DSH_HIDE_TOKEN=1，都会隐藏它。
dsh_token_visible() {
    case "${LINUXAPP_DSH_HIDE_TOKEN:-0}" in
        1|yes|true|on) return 1 ;;
    esac
    case "${LINUXAPP_SHOW_SECRETS:-1}" in
        0|no|false|off) return 1 ;;
    esac
    return 0
}

# 去掉访问地址里的 token 参数，得到可以安全展示的基准地址。
dsh_url_without_token() {
    printf '%s\n' "$1" | sed 's/[?&]token=[^&]*//; s/[?&]$//'
}

# 从服务日志里取出带 token 的访问地址，写入状态供展示。
# 地址行是应用完成配置树结算后才打印的，通常比 systemd 的 active 稍晚，因此这里做几次短重试；
# 取不到也不影响启动判定（启动判定只看 systemd 状态）。
dsh_capture_url() {
    dsh_cu_tries=${LINUXAPP_DSH_URL_TRIES:-6}
    case "$dsh_cu_tries" in
        ''|*[!0-9]*) dsh_cu_tries=6 ;;
    esac
    dsh_cu_try=0
    dsh_cu_url=''
    # 有本次启动时刻时只取该时刻之后的日志，避免读到上一次进程的旧 token；
    # 没有（例如事后手动查看）时放宽到最近一天，依旧只取日志里最新的一条地址。
    if [ -n "${DSH_START_EPOCH:-}" ]; then
        dsh_cu_since="@$DSH_START_EPOCH"
    else
        dsh_cu_since='-1d'
    fi
    while [ "$dsh_cu_try" -lt "$dsh_cu_tries" ]; do
        dsh_cu_try=$((dsh_cu_try + 1))
        dsh_cu_url=$("$(dsh_journalctl)" -u "$APP_UNIT" --since "$dsh_cu_since" -n 200 --no-pager 2>/dev/null \
            | sed -n 's/.*dsh web: \(http[^ ]*\).*/\1/p' | tail -n 1)
        [ -n "$dsh_cu_url" ] && break
        sleep 2
    done
    if [ -n "$dsh_cu_url" ]; then
        dsh_state_set web_url "$dsh_cu_url" || true
        lang_out "访问地址：$dsh_cu_url"
    else
        lang_info "暂未从日志读到访问地址，可执行「查看最近日志」查看：journalctl -u $APP_UNIT -n 20"
    fi
    return 0
}

# 显式查看访问地址：token 每次启动都会变化，这里重新读一次日志并刷新状态。
# 由用户主动触发，因此即使配置了隐藏 token 也完整显示，方便直接复制到浏览器。
dsh_show_url() {
    if [ ! -f "$(dsh_unit_path)" ]; then
        lang_fail '服务文件不存在，请先安装。'
        return 1
    fi
    dsh_su_active=$("$(dsh_systemctl)" is-active "$APP_UNIT" 2>/dev/null || true)
    if [ "$dsh_su_active" != active ]; then
        lang_warn "服务当前状态为 ${dsh_su_active:-未知}，下面显示的是日志里最近一次的访问地址。"
    fi
    dsh_capture_url
    return 0
}

# 应用启动成功后的清理：删除历史版本、清空回滚点与失败标记。
# LINUXAPP_DSH_KEEP_HISTORY=1 时只清理失败标记，保留历史版本。
dsh_cleanup_history() {
    dsh_ch_current=$(dsh_state_get installed_version 2>/dev/null || true)
    if [ -z "$dsh_ch_current" ]; then
        return 0
    fi
    if [ "${LINUXAPP_DSH_KEEP_HISTORY:-0}" = 1 ]; then
        dsh_state_set rollback_version '' || true
        dsh_state_set failed_version '' || true
        dsh_state_set last_error '' || true
        dsh_state_set last_result ok || true
        lang_info 'LINUXAPP_DSH_KEEP_HISTORY=1：已保留历史版本，仅清理失败标记与回滚点。'
        return 0
    fi
    dsh_ch_dir=$(dsh_versions_dir)
    if [ -d "$dsh_ch_dir" ]; then
        for dsh_ch_item in "$dsh_ch_dir"/*; do
            [ -d "$dsh_ch_item" ] || continue
            dsh_ch_name=${dsh_ch_item##*/}
            case "$dsh_ch_name" in
                .*) continue ;;
            esac
            [ "$dsh_ch_name" = "$dsh_ch_current" ] && continue
            if dsh_safe_rm_rf "$dsh_ch_item"; then
                lang_out "已删除历史版本：$dsh_ch_name"
            fi
        done
    fi
    dsh_state_set rollback_version '' || true
    dsh_state_set failed_version '' || true
    dsh_state_set last_error '' || true
    dsh_state_set last_result ok || true
    return 0
}

# ---------------------------------------------------------------- 版本与安装

dsh_fetch_metadata() {
    dsh_fm_dir=$(dsh_cache_dir)
    dsh_fm_file=$dsh_fm_dir/dsh-registry.json
    mkdir -p "$dsh_fm_dir" 2>/dev/null || return 1
    dsh_fm_url=$(dsh_registry)/$DSH_PACKAGE
    dsh_fm_tmp="$dsh_fm_file.part.$$"
    rm -f "$dsh_fm_tmp" 2>/dev/null || true
    dsh_fm_ok=1
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "${LINUXAPP_LANG_CONNECT_TIMEOUT:-15}" -o "$dsh_fm_tmp" "$dsh_fm_url" 2>/dev/null || dsh_fm_ok=0
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dsh_fm_tmp" "$dsh_fm_url" 2>/dev/null || dsh_fm_ok=0
    else
        dsh_fm_ok=0
    fi
    if [ "$dsh_fm_ok" -eq 1 ] && [ -s "$dsh_fm_tmp" ]; then
        if mv "$dsh_fm_tmp" "$dsh_fm_file" 2>/dev/null; then
            printf '%s\n' "$dsh_fm_file"
            return 0
        fi
    fi
    rm -f "$dsh_fm_tmp" 2>/dev/null || true
    if [ -s "$dsh_fm_file" ]; then
        lang_warn '无法连接 npm 仓库，已改用本地缓存的版本信息（可能不是最新）。'
        printf '%s\n' "$dsh_fm_file"
        return 0
    fi
    return 1
}

# 取 dist-tags 中的某个标签对应的版本。$1 元数据文件，$2 标签名。
dsh_dist_tag_version() {
    tr -d '\n' < "$1" 2>/dev/null \
        | sed -n 's/.*"dist-tags"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' \
        | tr ',' '\n' \
        | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | sed -n '1p'
}

# 判断元数据中是否存在指定版本。$1 元数据文件，$2 版本号。
dsh_has_version() {
    tr -d '\n' < "$1" 2>/dev/null | grep -q "\"$2\":{" 2>/dev/null
}

# 选择要安装的版本，结果写入 DSH_TARGET_VERSION。$1 元数据文件。
dsh_choose_version() {
    dsh_cv_meta=$1
    dsh_cv_wanted=${LINUXAPP_DSH_VERSION:-}
    if [ -n "$dsh_cv_wanted" ]; then
        case "$dsh_cv_wanted" in
            latest|next|alpha|beta|rc)
                dsh_cv_pick=$(dsh_dist_tag_version "$dsh_cv_meta" "$dsh_cv_wanted")
                if [ -z "$dsh_cv_pick" ]; then
                    lang_fail "npm 仓库中没有标签 $dsh_cv_wanted。"
                    return 1
                fi
                DSH_TARGET_VERSION=$dsh_cv_pick
                return 0
                ;;
        esac
        dsh_cv_wanted=$(printf '%s' "$dsh_cv_wanted" | sed -e 's/^[vV]//')
        if ! dsh_has_version "$dsh_cv_meta" "$dsh_cv_wanted"; then
            lang_fail "npm 仓库中找不到 $DSH_PACKAGE 版本 $dsh_cv_wanted。"
            return 1
        fi
        DSH_TARGET_VERSION=$dsh_cv_wanted
        return 0
    fi

    dsh_cv_latest=$(dsh_dist_tag_version "$dsh_cv_meta" latest)
    if [ -z "$dsh_cv_latest" ]; then
        lang_fail '无法从 npm 仓库元数据中解析最新版本号。'
        return 1
    fi
    if ! lang_has_tty; then
        DSH_TARGET_VERSION=$dsh_cv_latest
        lang_info "未指定版本，已选择最新版本：$dsh_cv_latest"
        return 0
    fi
    lang_out "可安装的版本："
    lang_out "  1. 最新版本 $dsh_cv_latest（npm 标签 latest）"
    lang_out "  2. 手动输入版本号或标签（例如 0.1.5-rc.1、next）"
    lang_choose_number '请输入编号' 2 || return 1
    if [ "$LANG_CHOICE" -eq 1 ]; then
        DSH_TARGET_VERSION=$dsh_cv_latest
        return 0
    fi
    lang_read_value '请输入版本号或标签：' || return 1
    dsh_cv_input=$(printf '%s' "$LANG_REPLY" | tr -d ' \t')
    [ -n "$dsh_cv_input" ] || {
        lang_fail '版本号不能为空。'
        return 1
    }
    case "$dsh_cv_input" in
        latest|next|alpha|beta|rc)
            dsh_cv_pick=$(dsh_dist_tag_version "$dsh_cv_meta" "$dsh_cv_input")
            if [ -z "$dsh_cv_pick" ]; then
                lang_fail "npm 仓库中没有标签 $dsh_cv_input。"
                return 1
            fi
            DSH_TARGET_VERSION=$dsh_cv_pick
            return 0
            ;;
    esac
    dsh_cv_input=$(printf '%s' "$dsh_cv_input" | sed -e 's/^[vV]//')
    if ! dsh_has_version "$dsh_cv_meta" "$dsh_cv_input"; then
        lang_fail "npm 仓库中找不到 $DSH_PACKAGE 版本 $dsh_cv_input。"
        return 1
    fi
    DSH_TARGET_VERSION=$dsh_cv_input
    return 0
}

# 把指定版本安装到 versions/<版本>。$1 版本号。
dsh_install_version() {
    dsh_iv_version=$1
    dsh_iv_dir=$(dsh_version_dir "$dsh_iv_version")
    dsh_iv_binjs=$(dsh_bin_js "$dsh_iv_version")
    if [ -f "$dsh_iv_binjs" ]; then
        lang_info "$DSH_PACKAGE $dsh_iv_version 已经安装，跳过下载。"
        return 0
    fi
    dsh_iv_npm=$(dsh_npm_bin)
    if [ ! -x "$dsh_iv_npm" ]; then
        lang_fail "找不到 npm：$dsh_iv_npm（请先在语言模块中安装 Node.js）。"
        return 1
    fi
    mkdir -p "$(dsh_versions_dir)" 2>/dev/null || {
        lang_fail "无法创建版本目录：$(dsh_versions_dir)"
        return 1
    }
    # 上一次安装中断可能留下不完整的目录，先清理再安装。
    if [ -d "$dsh_iv_dir" ]; then
        lang_warn "已存在不完整的版本目录，先删除：$dsh_iv_dir"
        dsh_safe_rm_rf "$dsh_iv_dir" || return 1
    fi
    DSH_STAGING=$(dsh_versions_dir)/.staging.$$
    rm -rf "$DSH_STAGING" 2>/dev/null || true
    mkdir -p "$DSH_STAGING" 2>/dev/null || {
        lang_fail "无法创建临时目录：$DSH_STAGING"
        return 1
    }
    lang_info "正在下载 $DSH_PACKAGE@$dsh_iv_version（registry：$(dsh_registry)）..."
    dsh_iv_status=0
    if lang_has_tty; then
        PATH="$(dsh_node_bin):$PATH" "$dsh_iv_npm" install \
            --prefix "$DSH_STAGING" \
            --registry "$(dsh_registry)" \
            --no-save --no-audit --no-fund --loglevel=error \
            "$DSH_PACKAGE@$dsh_iv_version" > /dev/tty 2>&1 || dsh_iv_status=$?
    else
        PATH="$(dsh_node_bin):$PATH" "$dsh_iv_npm" install \
            --prefix "$DSH_STAGING" \
            --registry "$(dsh_registry)" \
            --no-save --no-audit --no-fund --loglevel=error \
            "$DSH_PACKAGE@$dsh_iv_version" || dsh_iv_status=$?
    fi
    if [ "$dsh_iv_status" -ne 0 ] || [ ! -f "$DSH_STAGING/node_modules/$DSH_PACKAGE/lib/bin.js" ]; then
        dsh_safe_rm_rf "$DSH_STAGING" || true
        DSH_STAGING=''
        lang_fail "下载或安装 $DSH_PACKAGE@$dsh_iv_version 失败（退出码 $dsh_iv_status）。请检查网络与 npm 源后重试。"
        return 1
    fi
    # 校验实际安装到的精确版本，避免镜像内容与请求版本不一致。
    dsh_iv_actual=$(PATH="$(dsh_node_bin):$PATH" "$(dsh_node_bin)/node" \
        "$DSH_STAGING/node_modules/$DSH_PACKAGE/lib/bin.js" --version 2>/dev/null | sed -n '1p')
    dsh_iv_actual=$(printf '%s' "$dsh_iv_actual" | sed -e 's/^[vV]//')
    if [ "$dsh_iv_actual" != "$dsh_iv_version" ]; then
        dsh_safe_rm_rf "$DSH_STAGING" || true
        DSH_STAGING=''
        lang_fail "版本校验失败：期望 $dsh_iv_version，实际 ${dsh_iv_actual:-未知}。已删除本次下载内容。"
        return 1
    fi
    if ! mv "$DSH_STAGING" "$dsh_iv_dir" 2>/dev/null; then
        dsh_safe_rm_rf "$DSH_STAGING" || true
        DSH_STAGING=''
        lang_fail "无法写入版本目录：$dsh_iv_dir"
        return 1
    fi
    DSH_STAGING=''
    lang_ok "$DSH_PACKAGE $dsh_iv_version 已安装到 $dsh_iv_dir"
    return 0
}

# ---------------------------------------------------------------- 动作实现

# 记录一次失败：状态标记为异常，并保留回滚点，等待用户处理或回滚。
dsh_mark_failed() {
    dsh_mf_reason=$1
    dsh_mf_failed=${2:-}
    dsh_state_set last_result failed || true
    dsh_state_set last_error "$dsh_mf_reason" || true
    if [ -n "$dsh_mf_failed" ]; then
        dsh_state_set failed_version "$dsh_mf_failed" || true
    fi
    return 0
}

dsh_install() {
    dsh_in_arg=${1:-}
    dsh_preflight || return 1
    if [ -f "$(dsh_state_file)" ] && [ -f "$(dsh_unit_path)" ]; then
        dsh_in_current=$(dsh_state_get installed_version 2>/dev/null || true)
        lang_out "$APP_TITLE 已经安装（当前版本：${dsh_in_current:-未知}）。"
        lang_out '如需升级版本请选择「更新」；如需重建服务文件请选择「修复服务文件」。'
        return 0
    fi
    dsh_ensure_language_deps || return 1
    if [ -n "$dsh_in_arg" ]; then
        LINUXAPP_DSH_VERSION=$dsh_in_arg
    fi
    dsh_source_choose || return 1
    lang_info "使用 npm 源：$(dsh_registry)"
    dsh_in_meta=$(dsh_fetch_metadata) || {
        lang_fail "无法获取 $DSH_PACKAGE 的版本信息，请检查网络与 npm 源后重试。"
        return 1
    }
    dsh_choose_version "$dsh_in_meta" || return 1
    dsh_choose_listen || return 1

    lang_out "准备安装：$DSH_PACKAGE $DSH_TARGET_VERSION"
    lang_out "监听地址：$DSH_LISTEN_HOST:$DSH_LISTEN_PORT"
    lang_out "服务文件：$(dsh_unit_path)"
    lang_out "数据目录（DSH_HOME）：$(dsh_cfg_home)"
    lang_out "工作目录：$(dsh_cfg_workspace)"
    dsh_confirm '确认开始安装吗？' y || {
        lang_info '已取消安装。'
        return 0
    }

    dsh_install_version "$DSH_TARGET_VERSION" || return 1
    dsh_state_set host "$DSH_LISTEN_HOST" || return 1
    dsh_state_set port "$DSH_LISTEN_PORT" || return 1
    dsh_state_set trusted_host "${DSH_TRUSTED_HOST:-}" || true
    dsh_state_set dsh_home "$(dsh_cfg_home)" || true
    dsh_state_set workspace "$(dsh_cfg_workspace)" || true
    dsh_state_set node_bin "$(dsh_node_bin)" || true
    dsh_state_set unit_path "$(dsh_unit_path)" || true
    dsh_state_set installed_version "$DSH_TARGET_VERSION" || return 1
    dsh_state_set last_action install || true
    dsh_write_unit "$DSH_TARGET_VERSION" || return 1
    if "$(dsh_systemctl)" enable "$APP_UNIT" >/dev/null 2>&1; then
        lang_ok '已设置开机自启（systemctl enable）。'
    else
        lang_warn 'systemctl enable 执行失败，开机自启可能未启用，可稍后执行「修复服务文件」。'
    fi
    dsh_write_wrapper "$DSH_TARGET_VERSION"

    if dsh_start_service; then
        lang_ok "$APP_TITLE $DSH_TARGET_VERSION 安装完成并已启动。"
        dsh_state_set last_result ok || true
        dsh_state_set last_error '' || true
        dsh_capture_url
        dsh_cleanup_history
        return 0
    fi

    dsh_failure_report install
    dsh_mark_failed '首次安装后启动失败'
    lang_warn '服务状态已标记为「异常」，本次未做自动回滚（首次安装没有历史版本可回滚）。'
    lang_out '可尝试：排查原因后选择「启动」；或选择「修复服务文件」；或「查看最近日志」。'
    return 1
}

dsh_start() {
    dsh_preflight || return 1
    dsh_sv_version=$(dsh_state_get installed_version 2>/dev/null || true)
    if [ -z "$dsh_sv_version" ]; then
        lang_fail "$APP_TITLE 尚未安装，请先选择「安装」。"
        return 1
    fi
    dsh_ensure_language_deps || return 1
    dsh_sv_active=$("$(dsh_systemctl)" is-active "$APP_UNIT" 2>/dev/null || true)
    if [ "$dsh_sv_active" = active ]; then
        lang_ok '服务已经在运行中。'
        dsh_state_set last_result ok || true
        dsh_state_set last_error '' || true
        dsh_capture_url
        dsh_cleanup_history
        return 0
    fi
    if dsh_start_service; then
        lang_ok "$APP_TITLE $dsh_sv_version 已启动。"
        dsh_state_set last_result ok || true
        dsh_state_set last_error '' || true
        dsh_capture_url
        dsh_cleanup_history
        return 0
    fi

    dsh_failure_report start
    dsh_sv_rollback=$(dsh_state_get rollback_version 2>/dev/null || true)
    if [ -n "$dsh_sv_rollback" ]; then
        dsh_mark_failed '启动失败' "$dsh_sv_version"
    else
        dsh_mark_failed '启动失败'
    fi
    lang_warn '服务状态已标记为「异常」，没有自动回滚。'
    if [ -n "$dsh_sv_rollback" ]; then
        lang_out "修复问题后可再次选择「启动」，或选择「回滚到上一版本」（$dsh_sv_rollback）。"
    else
        lang_out '修复问题后可再次选择「启动」，或选择「修复服务文件」/「查看最近日志」。'
    fi
    return 1
}

dsh_stop() {
    dsh_preflight || return 1
    if ! "$(dsh_systemctl)" stop "$APP_UNIT"; then
        lang_fail "systemctl stop $APP_UNIT 执行失败，请检查服务状态。"
        return 1
    fi
    lang_ok '服务已停止（开机自启设置保持不变）。'
    dsh_sp_last=$(dsh_state_get last_result 2>/dev/null || true)
    if [ "$dsh_sp_last" = failed ]; then
        lang_warn '检测到上一次操作处于失败状态，已保留失败标记与回滚点，便于你继续处理或回滚。'
    else
        dsh_state_set last_result stopped || true
    fi
    return 0
}

dsh_update() {
    dsh_up_arg=${1:-}
    dsh_preflight || return 1
    dsh_up_current=$(dsh_state_get installed_version 2>/dev/null || true)
    if [ -z "$dsh_up_current" ] || [ ! -f "$(dsh_unit_path)" ]; then
        lang_fail "$APP_TITLE 尚未安装，请先选择「安装」。"
        return 1
    fi

    # 更新前的插件风险提示：无论是否自动确认都要打印。
    lang_warn '更新前请注意：如果你为 DeepSeek Harness 安装过插件（dsh plugin --profile web ...），'
    lang_warn '新版本可能与插件不兼容，更新后服务可能启动失败。'
    lang_warn '本模块在失败时不会自动回滚，服务会停在「异常」状态；'
    lang_warn '你可以在菜单选择「回滚到上一版本」，或先移除不兼容插件后选择「启动」。'
    dsh_confirm '确认继续更新吗？' n || {
        lang_info '已取消更新。'
        return 0
    }

    dsh_ensure_language_deps || return 1
    if [ -n "$dsh_up_arg" ]; then
        LINUXAPP_DSH_VERSION=$dsh_up_arg
    fi
    dsh_source_choose || return 1
    dsh_up_meta=$(dsh_fetch_metadata) || {
        lang_fail "无法获取 $DSH_PACKAGE 的版本信息，请检查网络与 npm 源后重试。"
        return 1
    }
    dsh_choose_version "$dsh_up_meta" || return 1
    if [ "$DSH_TARGET_VERSION" = "$dsh_up_current" ]; then
        lang_ok "当前已是最新版本（$dsh_up_current），无需更新。"
        return 0
    fi
    lang_out "检测到新版本：$DSH_TARGET_VERSION（当前 $dsh_up_current）"
    dsh_confirm "是否更新到 $APP_TITLE $DSH_TARGET_VERSION？" y || {
        lang_info '已取消更新。'
        return 0
    }

    # 先把新版本完整下载到本地，再停服务，避免停服后下载失败导致长时间不可用。
    dsh_install_version "$DSH_TARGET_VERSION" || return 1
    dsh_state_set rollback_version "$dsh_up_current" || return 1
    dsh_state_set last_action update || true
    dsh_state_set last_result pending || true

    lang_info '正在停止服务...'
    if ! "$(dsh_systemctl)" stop "$APP_UNIT"; then
        lang_warn "systemctl stop $APP_UNIT 返回失败，请确认服务状态。"
    fi
    dsh_up_elapsed=0
    dsh_up_state=''
    while [ "$dsh_up_elapsed" -lt 15 ]; do
        dsh_up_state=$("$(dsh_systemctl)" is-active "$APP_UNIT" 2>/dev/null || true)
        case "$dsh_up_state" in
            active|activating|deactivating|reloading)
                sleep 1
                dsh_up_elapsed=$((dsh_up_elapsed + 1))
                ;;
            *) break ;;
        esac
    done
    if [ "$dsh_up_state" = active ]; then
        lang_fail '服务未能在预期时间内停止，已中止更新（未改写服务文件，当前版本保持不变）。'
        dsh_state_set last_result ok || true
        dsh_state_set rollback_version '' || true
        return 1
    fi

    dsh_state_set installed_version "$DSH_TARGET_VERSION" || return 1
    dsh_write_unit "$DSH_TARGET_VERSION" || return 1
    dsh_write_wrapper "$DSH_TARGET_VERSION"

    if dsh_start_service; then
        lang_ok "更新完成：$dsh_up_current -> $DSH_TARGET_VERSION"
        dsh_state_set last_result ok || true
        dsh_state_set last_error '' || true
        dsh_capture_url
        dsh_cleanup_history
        return 0
    fi

    dsh_failure_report update
    dsh_mark_failed '更新后启动失败' "$DSH_TARGET_VERSION"
    lang_warn '更新失败，服务状态已标记为「异常」，本次没有自动回滚。'
    lang_out "可选处理：1) 修复问题后选择「启动」（例如移除不兼容插件：$(dsh_wrapper_path) plugin --profile web remove <插件名>）；"
    lang_out "          2) 选择「回滚到上一版本」（$dsh_up_current）。"
    return 1
}

dsh_rollback() {
    dsh_preflight || return 1
    dsh_rb_current=$(dsh_state_get installed_version 2>/dev/null || true)
    dsh_rb_target=$(dsh_state_get rollback_version 2>/dev/null || true)
    if [ -z "$dsh_rb_target" ]; then
        lang_fail '当前没有可回滚的历史版本。'
        return 1
    fi
    if [ ! -f "$(dsh_bin_js "$dsh_rb_target")" ]; then
        lang_fail "回滚目标版本目录不完整：$(dsh_version_dir "$dsh_rb_target")"
        return 1
    fi
    dsh_ensure_language_deps || return 1
    lang_out "即将回滚：${dsh_rb_current:-未知} -> $dsh_rb_target"
    dsh_confirm '确认回滚到上一版本吗？' y || {
        lang_info '已取消回滚。'
        return 0
    }

    if ! "$(dsh_systemctl)" stop "$APP_UNIT"; then
        lang_warn "systemctl stop $APP_UNIT 返回失败，请确认服务状态。"
    fi
    dsh_state_set installed_version "$dsh_rb_target" || return 1
    dsh_write_unit "$dsh_rb_target" || return 1
    dsh_write_wrapper "$dsh_rb_target"

    if dsh_start_service; then
        dsh_state_set last_result ok || true
        dsh_state_set last_error '' || true
        if [ -n "$dsh_rb_current" ] && [ "$dsh_rb_current" != "$dsh_rb_target" ]; then
            dsh_state_set failed_version "$dsh_rb_current" || true
        fi
        lang_ok "已回滚到 $APP_TITLE $dsh_rb_target 并恢复运行。"
        dsh_capture_url
        dsh_cleanup_history
        return 0
    fi

    dsh_failure_report rollback
    dsh_mark_failed '回滚后启动失败'
    lang_warn "回滚后服务仍未启动，状态保持「异常」；失败版本与回滚点都保留，可继续排查或再次回滚。"
    return 1
}

dsh_repair() {
    dsh_preflight || return 1
    dsh_rp_version=$(dsh_state_get installed_version 2>/dev/null || true)
    if [ -z "$dsh_rp_version" ]; then
        lang_fail "$APP_TITLE 尚未安装，无法修复服务文件。"
        return 1
    fi
    if [ ! -f "$(dsh_bin_js "$dsh_rp_version")" ]; then
        lang_fail "版本目录不完整：$(dsh_version_dir "$dsh_rp_version")，请重新安装或更新。"
        return 1
    fi
    dsh_ensure_language_deps || return 1
    dsh_write_unit "$dsh_rp_version" || return 1
    if "$(dsh_systemctl)" enable "$APP_UNIT" >/dev/null 2>&1; then
        lang_ok '已重新设置开机自启（systemctl enable）。'
    else
        lang_warn 'systemctl enable 执行失败，开机自启可能未启用。'
    fi
    dsh_write_wrapper "$dsh_rp_version"
    lang_ok "服务文件已按当前版本 $dsh_rp_version 重建（未联网、未改动版本）。"
    return 0
}

dsh_log() {
    dsh_lg_unit=$(dsh_unit_path)
    if [ ! -f "$dsh_lg_unit" ]; then
        lang_fail '服务文件不存在，暂无日志可查。'
        return 1
    fi
    if ! command -v "$(dsh_journalctl)" >/dev/null 2>&1; then
        lang_fail '找不到 journalctl，无法查看服务日志。'
        return 1
    fi
    lang_out "最近 60 行服务日志（$APP_UNIT）："
    "$(dsh_journalctl)" -u "$APP_UNIT" -n 60 --no-pager 2>&1 | while IFS= read -r dsh_lg_line; do
        lang_out "$dsh_lg_line"
    done
    return 0
}

dsh_uninstall() {
    dsh_preflight || return 1
    dsh_un_root=$(dsh_root)
    dsh_un_versions=$(dsh_versions_dir)
    dsh_un_home=$(dsh_cfg_home)
    dsh_un_unit=$(dsh_unit_path)
    dsh_un_version=$(dsh_state_get installed_version 2>/dev/null || true)
    dsh_un_wrapper=$(dsh_wrapper_path)
    dsh_un_has_state=0
    [ -f "$(dsh_state_file)" ] && dsh_un_has_state=1
    dsh_un_has_unit=0
    [ -f "$dsh_un_unit" ] && dsh_un_has_unit=1
    dsh_un_has_versions=0
    [ -d "$dsh_un_versions" ] && dsh_un_has_versions=1
    if [ "$dsh_un_has_state" -eq 0 ] && [ "$dsh_un_has_unit" -eq 0 ] && [ "$dsh_un_has_versions" -eq 0 ]; then
        lang_info "$APP_TITLE 尚未安装，无需卸载。"
        return 0
    fi

    lang_out "将停止并禁用服务：$APP_UNIT"
    lang_out "将删除服务文件：$dsh_un_unit"
    if [ -n "$dsh_un_version" ]; then
        lang_out "当前版本：$dsh_un_version"
    fi
    lang_warn "DSH 数据目录默认保留：$dsh_un_home（会话、凭证与插件都在这里）"
    dsh_confirm "确认卸载 $APP_TITLE 吗？" n || {
        lang_info '已取消卸载。'
        return 0
    }

    dsh_un_purge=${LINUXAPP_DSH_PURGE:-0}
    dsh_un_del_versions=1
    dsh_un_del_home=0
    if [ "$dsh_un_purge" = 1 ]; then
        dsh_un_del_versions=1
        dsh_un_del_home=1
        lang_info '已按 LINUXAPP_DSH_PURGE=1 选择同时删除版本目录与 DSH 数据目录。'
    else
        dsh_confirm "是否删除已安装的版本目录？($dsh_un_versions)" y || dsh_un_del_versions=0
        dsh_confirm "是否一并删除 DSH 数据目录？($dsh_un_home：包含会话、凭证与插件)" n || dsh_un_del_home=0
    fi

    "$(dsh_systemctl)" disable --now "$APP_UNIT" >/dev/null 2>&1 || true
    rm -f "$dsh_un_unit" 2>/dev/null || true
    "$(dsh_systemctl)" daemon-reload >/dev/null 2>&1 || true
    rm -f "$(dsh_state_file)" 2>/dev/null || true

    if [ -f "$dsh_un_wrapper" ] && grep -qF "$APP_WRAPPER_MARK" "$dsh_un_wrapper" 2>/dev/null; then
        rm -f "$dsh_un_wrapper" 2>/dev/null || true
        lang_out "已删除命令入口：$dsh_un_wrapper"
    fi

    if [ "$dsh_un_purge" = 1 ]; then
        dsh_safe_rm_rf "$dsh_un_root" || true
        lang_ok "已删除应用目录：$dsh_un_root"
    elif [ "$dsh_un_del_versions" = 1 ]; then
        dsh_safe_rm_rf "$dsh_un_versions" || true
        lang_ok "已删除版本目录：$dsh_un_versions"
    else
        lang_out "版本目录已保留：$dsh_un_versions（如需彻底清理可手工删除）"
    fi

    if [ "$dsh_un_del_home" = 1 ]; then
        dsh_safe_rm_rf "$dsh_un_home" || true
        lang_ok "已删除 DSH 数据目录：$dsh_un_home"
    else
        lang_out "DSH 数据目录已保留：$dsh_un_home"
    fi

    lang_ok "$APP_TITLE 已卸载。"
    return 0
}

dsh_status() {
    dsh_status_unit=$(dsh_unit_path)
    dsh_status_version=$(dsh_state_get installed_version 2>/dev/null || true)
    dsh_status_last=$(dsh_state_get last_result 2>/dev/null || true)
    dsh_status_rollback=$(dsh_state_get rollback_version 2>/dev/null || true)
    dsh_status_failed=$(dsh_state_get failed_version 2>/dev/null || true)
    dsh_status_url=$(dsh_state_get web_url 2>/dev/null || true)

    dsh_status_unit_exists=0
    [ -f "$dsh_status_unit" ] && dsh_status_unit_exists=1
    dsh_status_has_versions=0
    if [ -d "$(dsh_versions_dir)" ]; then
        for dsh_status_item in "$(dsh_versions_dir)"/*; do
            [ -d "$dsh_status_item" ] || continue
            case "${dsh_status_item##*/}" in
                .*) continue ;;
            esac
            dsh_status_has_versions=1
            break
        done
    fi

    if [ "$dsh_status_unit_exists" -eq 0 ] && [ "$dsh_status_has_versions" -eq 0 ]; then
        printf '未安装|-|尚未安装 %s；可选择「安装」，默认安装最新版本\n' "$APP_TITLE"
        return 0
    fi

    dsh_status_node_hint=''
    dsh_node_probe
    case "$?" in
        0) ;;
        2) dsh_status_node_hint="；但 Node.js $DSH_NODE_VERSION 低于要求的 $APP_MIN_NODE_MAJOR" ;;
        *) dsh_status_node_hint='；但当前找不到可用的 Node.js 运行时' ;;
    esac

    if [ "$dsh_status_unit_exists" -eq 0 ]; then
        printf '异常|%s|服务文件缺失（%s），请执行「修复服务文件」%s\n' \
            "${dsh_status_version:--}" "$dsh_status_unit" "$dsh_status_node_hint"
        return 0
    fi

    dsh_status_active=$("$(dsh_systemctl)" is-active "$APP_UNIT" 2>/dev/null || true)
    dsh_status_enabled=$("$(dsh_systemctl)" is-enabled "$APP_UNIT" 2>/dev/null || true)
    case "$dsh_status_enabled" in
        enabled) dsh_status_boot='开机自启已启用' ;;
        '') dsh_status_boot='开机自启状态未知' ;;
        *) dsh_status_boot="开机自启：$dsh_status_enabled" ;;
    esac
    dsh_status_rollback_hint=''
    if [ -n "$dsh_status_rollback" ]; then
        dsh_status_rollback_hint="，或选择「回滚到上一版本」（$dsh_status_rollback）"
    fi

    # 访问地址（含 token）默认直接显示在说明列，方便复制到浏览器打开；
    # 隐藏时只显示基准地址，并提示可以用「查看访问地址」显式查看。
    dsh_status_addr=''
    if [ -n "$dsh_status_url" ]; then
        if dsh_token_visible; then
            dsh_status_addr="；访问地址：$dsh_status_url"
        else
            dsh_status_addr="；访问地址：$(dsh_url_without_token "$dsh_status_url")（token 已隐藏，可用「查看访问地址」查看）"
        fi
    fi

    case "$dsh_status_active" in
        active)
            dsh_status_note=''
            if [ -n "$dsh_status_rollback" ] || [ -n "$dsh_status_failed" ] || [ "$dsh_status_last" = failed ]; then
                dsh_status_note='；存在历史版本或失败标记，选择「启动」即可清理'
            fi
            printf '运行中|%s|服务 %s 运行中（%s:%s，%s）%s%s%s\n' \
                "${dsh_status_version:-未知}" "$APP_UNIT" "$(dsh_cfg_host)" "$(dsh_cfg_port)" \
                "$dsh_status_boot" "$dsh_status_node_hint" "$dsh_status_note" "$dsh_status_addr"
            ;;
        inactive)
            if [ "$dsh_status_last" = failed ]; then
                printf '异常|%s|上次操作失败，服务当前未运行；可修复后选择「启动」%s%s\n' \
                    "${dsh_status_version:-未知}" "$dsh_status_rollback_hint" "$dsh_status_node_hint"
            else
                printf '已停止|%s|服务已安装但未运行（%s）；可选择「启动」%s\n' \
                    "${dsh_status_version:-未知}" "$dsh_status_boot" "$dsh_status_node_hint"
            fi
            ;;
        *)
            printf '异常|%s|服务状态：%s；启动失败，可查看「最近日志」%s%s\n' \
                "${dsh_status_version:-未知}" "${dsh_status_active:-未知}" \
                "$dsh_status_rollback_hint" "$dsh_status_node_hint"
            ;;
    esac
    return 0
}

# 按当前状态把附加动作报给框架：失败且存在回滚点时才出现「回滚到上一版本」。
dsh_extras() {
    dsh_ex_state_file=$(dsh_state_file)
    dsh_ex_unit=$(dsh_unit_path)
    if [ ! -f "$dsh_ex_state_file" ] && [ ! -f "$dsh_ex_unit" ]; then
        return 0
    fi
    dsh_ex_last=$(dsh_state_get last_result 2>/dev/null || true)
    dsh_ex_rollback=$(dsh_state_get rollback_version 2>/dev/null || true)
    if [ "$dsh_ex_last" = failed ] && [ -n "$dsh_ex_rollback" ]; then
        dsh_ex_active=$("$(dsh_systemctl)" is-active "$APP_UNIT" 2>/dev/null || true)
        if [ "$dsh_ex_active" != active ]; then
            printf 'rollback|回滚到上一版本（%s）\n' "$dsh_ex_rollback"
        fi
    fi
    # 注意：动作名里不能有空格，框架按空白切分动作表（否则会被拆成两个菜单项）。
    printf '%s\n' 'url|查看访问地址（含token）'
    printf '%s\n' 'repair|修复服务文件'
    printf '%s\n' 'log|查看最近日志'
    return 0
}

# 声明依赖的语言环境：框架在安装、更新、启动前会先确保该语言模块已安装。
dsh_requires() {
    printf '%s\n' 'nodejs'
    return 0
}

# ---------------------------------------------------------------- 动作分发

dsh_main() {
    dsh_action=${1:-status}
    case "$dsh_action" in
        requires)
            dsh_requires
            ;;
        extras)
            dsh_extras
            ;;
        status)
            dsh_status
            ;;
        install)
            dsh_arg=''
            if [ "$#" -gt 1 ]; then
                shift
                dsh_arg=$1
            fi
            dsh_install "$dsh_arg"
            ;;
        update)
            dsh_arg=''
            if [ "$#" -gt 1 ]; then
                shift
                dsh_arg=$1
            fi
            dsh_update "$dsh_arg"
            ;;
        start)
            dsh_start
            ;;
        stop)
            dsh_stop
            ;;
        rollback)
            dsh_rollback
            ;;
        url)
            dsh_show_url
            ;;
        repair)
            dsh_repair
            ;;
        log)
            dsh_log
            ;;
        uninstall)
            dsh_uninstall
            ;;
        *)
            lang_fail "未知的软件动作：$dsh_action"
            return 2
            ;;
    esac
}

trap 'dsh_cleanup; lang_out ""; lang_warn "DeepSeek Harness 操作已被 Ctrl+C 中断，临时文件已清理。"; exit 130' INT
trap 'dsh_cleanup' TERM HUP

dsh_main "$@"
dsh_exit_code=$?
dsh_cleanup
exit "$dsh_exit_code"

# Last updated: 2026-09-12 07:00
