#!/bin/sh

# 入口定位与本地同步：本地目录运行时按脚本所在目录解析；一键命令
# （例如 `sh -c "$(curl -fsSL https://.../main.sh)"`）执行时 $0 不是文件路径，
# 解析不到本地目录，此时把全部脚本（框架 + 模块）一次性取回用户目录，再以该目录为根目录重新执行本脚本。
# 运行期只使用本地脚本、不再联网：模块脚本不在菜单中按需下载，全部在同步阶段落地。
# 站点地址与本地副本有效期优先取环境变量：同步阶段还没有 config/source.sh，只能先用下面的内置默认值，
# 进入菜单后由 config/source.sh 接管（两处默认值保持一致，可继续用环境变量覆盖）。
LINUXAPP_BOOTSTRAP_BASE_URL=${LINUXAPP_BASE_URL:-https://linuxapp.xiaozhuhouses.asia/}
LINUXAPP_BOOTSTRAP_CACHE_TTL=${LINUXAPP_CACHE_TTL:-3600}
# 同步标记写在本地副本目录内：既记录本次同步时间（用于有效期判断），也用来区分
# 「一键运行取回的本地副本」与「直接使用的本地目录」——没有标记的目录不会被执行同步。
LINUXAPP_SYNC_STAMP='.linuxapp-sync'
LINUXAPP_ROOT=''

# 一键运行的本地副本目录：LINUXAPP_HOME 优先，其次 XDG_DATA_HOME，最后 ~/.local/share/linuxapp。
linuxapp_home_dir() {
    if [ -n "${LINUXAPP_HOME:-}" ]; then
        printf '%s\n' "$LINUXAPP_HOME"
    elif [ -n "${XDG_DATA_HOME:-}" ]; then
        printf '%s/linuxapp\n' "$XDG_DATA_HOME"
    else
        printf '%s/.local/share/linuxapp\n' "${HOME:-.}"
    fi
}

linuxapp_sync_stamp_path() {
    printf '%s/%s\n' "$1" "$LINUXAPP_SYNC_STAMP"
}

# 本地副本有效期（秒），默认 1 小时，与 config/source.sh 的 LINUXAPP_CACHE_TTL 保持一致。
linuxapp_sync_ttl() {
    lst_ttl=${LINUXAPP_CACHE_TTL:-$LINUXAPP_BOOTSTRAP_CACHE_TTL}
    case "$lst_ttl" in
        ''|*[!0-9]*) lst_ttl=$LINUXAPP_BOOTSTRAP_CACHE_TTL ;;
    esac
    printf '%s\n' "$lst_ttl"
}

# 目录内是否具备最小可运行框架文件。
linuxapp_root_usable() {
    [ -n "$1" ] && [ -f "$1/config/source.sh" ] && [ -f "$1/config/modules.list" ] && [ -f "$1/lib/ui.sh" ]
}

# 本地副本是否仍在有效期内：标记缺失、时间戳异常、系统时间回拨或已经超期都返回 1。
linuxapp_sync_fresh() {
    lsf_stamp=$(linuxapp_sync_stamp_path "$1")
    lsf_saved=$(sed -n '1p' "$lsf_stamp" 2>/dev/null)
    lsf_now=$(date +%s 2>/dev/null) || return 1
    case "$lsf_saved" in
        ''|*[!0-9]*) return 1 ;;
    esac
    case "$lsf_now" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$lsf_saved" -le "$lsf_now" ] || return 1
    [ $((lsf_now - lsf_saved)) -lt "$(linuxapp_sync_ttl)" ] 2>/dev/null
}

# 先看脚本自身目录，再看当前工作目录；两者都不成立时返回 1，交给同步阶段处理。
linuxapp_locate_root() {
    llr_self=$0
    llr_dir=''
    case "$llr_self" in
        */*)
            llr_dir=$(CDPATH=; cd "$(dirname "$llr_self")" 2>/dev/null && pwd) || llr_dir=''
            ;;
    esac
    if linuxapp_root_usable "$llr_dir"; then
        LINUXAPP_ROOT=$llr_dir
        return 0
    fi
    llr_cwd=$(pwd 2>/dev/null) || llr_cwd=''
    if linuxapp_root_usable "$llr_cwd"; then
        LINUXAPP_ROOT=$llr_cwd
        return 0
    fi
    return 1
}

# 下载单个文件：先写临时文件，校验成功后再原子替换目标文件。
linuxapp_sync_fetch() {
    lbf_url=$1
    lbf_target=$2
    lbf_tmp="$lbf_target.tmp.$$"
    mkdir -p "$(dirname "$lbf_target")" 2>/dev/null || {
        printf '错误：无法创建目录：%s\n' "$(dirname "$lbf_target")" >&2
        return 1
    }
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "${LINUXAPP_CONNECT_TIMEOUT:-10}" "$lbf_url" -o "$lbf_tmp" 2>/dev/null
        lbf_status=$?
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout="${LINUXAPP_CONNECT_TIMEOUT:-10}" -O "$lbf_tmp" "$lbf_url" 2>/dev/null
        lbf_status=$?
    else
        printf '%s\n' '错误：系统中找不到 curl 或 wget，无法获取 LinuxApp 脚本。' >&2
        printf '%s\n' '请在 LinuxApp 仓库目录内直接运行 ./main.sh。' >&2
        return 1
    fi
    if [ "$lbf_status" -eq 0 ] && [ -s "$lbf_tmp" ]; then
        mv "$lbf_tmp" "$lbf_target" && return 0
    fi
    rm -f "$lbf_tmp"
    return 1
}

# 校验清单里的路径：只接受同步目录内的相对路径，避免被篡改的清单写到目录之外。
linuxapp_sync_check_relative() {
    lcr_rel=$1
    case "$lcr_rel" in
        /*|*..*)
            printf '错误：脚本清单中存在非法路径：%s\n' "$lcr_rel" >&2
            return 1
            ;;
    esac
    return 0
}

# 按逐行清单同步脚本（框架清单格式）。失败时把首个出错的路径写入全局 LINUXAPP_SYNC_FAILED。
linuxapp_sync_manifest() {
    lsm_home=$1
    lsm_base=$2
    lsm_file=$3
    LINUXAPP_SYNC_FAILED=''
    while IFS= read -r lsm_line || [ -n "$lsm_line" ]; do
        case "$lsm_line" in
            ''|'#'*) continue ;;
        esac
        if ! linuxapp_sync_check_relative "$lsm_line"; then
            LINUXAPP_SYNC_FAILED=$lsm_line
            return 1
        fi
        if ! linuxapp_sync_fetch "$lsm_base/$lsm_line" "$lsm_home/$lsm_line"; then
            LINUXAPP_SYNC_FAILED=$lsm_line
            return 1
        fi
    done < "$lsm_file"
    return 0
}

# 同步 config/modules.list 中登记的全部模块脚本（四列格式：类型|模块 ID|相对脚本路径|显示名称）。
# 模块清单本身由框架清单负责取回，因此这里读到的是本次部署的最新登记结果。
linuxapp_sync_modules() {
    lsmd_home=$1
    lsmd_base=$2
    lsmd_list="$lsmd_home/config/modules.list"
    [ -f "$lsmd_list" ] || return 0
    LINUXAPP_SYNC_FAILED=''
    while IFS='|' read -r lsmd_type lsmd_id lsmd_path lsmd_label || [ -n "$lsmd_path" ]; do
        case "$lsmd_type" in
            ''|'#'*) continue ;;
        esac
        [ -n "$lsmd_path" ] || continue
        if ! linuxapp_sync_check_relative "$lsmd_path"; then
            LINUXAPP_SYNC_FAILED=$lsmd_path
            return 1
        fi
        if ! linuxapp_sync_fetch "$lsmd_base/$lsmd_path" "$lsmd_home/$lsmd_path"; then
            LINUXAPP_SYNC_FAILED=$lsmd_path
            return 1
        fi
    done < "$lsmd_list"
    return 0
}

# 全量同步：先取回框架清单与框架文件，再按取回的模块清单取回全部模块脚本。
linuxapp_sync_pull() {
    lsp_home=$1
    lsp_base=$2
    lsp_manifest="$lsp_home/config/bootstrap.list"

    if ! linuxapp_sync_fetch "$lsp_base/config/bootstrap.list" "$lsp_manifest"; then
        printf '错误：无法下载脚本清单 %s/config/bootstrap.list，请检查网络后重试。\n' "$lsp_base" >&2
        printf '%s\n' '提示：也可以先下载整个 LinuxApp 仓库，再在仓库目录内运行 ./main.sh。' >&2
        return 1
    fi
    if ! linuxapp_sync_manifest "$lsp_home" "$lsp_base" "$lsp_manifest"; then
        printf '错误：下载框架脚本失败：%s/%s\n' "$lsp_base" "$LINUXAPP_SYNC_FAILED" >&2
        printf '%s\n' '请检查网络连通性后重试；也可以先下载整个 LinuxApp 仓库，再在仓库目录内运行 ./main.sh。' >&2
        return 1
    fi
    chmod +x "$lsp_home/main.sh" 2>/dev/null || true
    if ! linuxapp_sync_modules "$lsp_home" "$lsp_base"; then
        printf '错误：下载模块脚本失败：%s/%s\n' "$lsp_base" "$LINUXAPP_SYNC_FAILED" >&2
        printf '%s\n' '请检查网络连通性后重试；也可以先下载整个 LinuxApp 仓库，再在仓库目录内运行 ./main.sh。' >&2
        return 1
    fi
    return 0
}

# 写入同步标记：第一行为同步时间（秒），第二行为本次使用的站点地址，便于排查脚本来源。
linuxapp_sync_write_stamp() {
    lws_stamp=$(linuxapp_sync_stamp_path "$1")
    lws_tmp="$lws_stamp.tmp.$$"
    lws_now=$(date +%s 2>/dev/null) || return 1
    case "$lws_now" in
        ''|*[!0-9]*) return 1 ;;
    esac
    mkdir -p "$(dirname "$lws_stamp")" 2>/dev/null || return 1
    printf '%s\n%s\n' "$lws_now" "$2" > "$lws_tmp" 2>/dev/null || {
        rm -f "$lws_tmp"
        return 1
    }
    mv "$lws_tmp" "$lws_stamp" 2>/dev/null || {
        rm -f "$lws_tmp"
        return 1
    }
    return 0
}

# 清理在线模式遗留的脚本缓存目录：新版本把全部脚本同步到本地副本，该目录已不再使用。
linuxapp_sync_clean_legacy() {
    if [ -n "${XDG_CACHE_HOME:-}" ]; then
        lsl_dir="$XDG_CACHE_HOME/linuxapp/scripts"
    else
        lsl_dir="${HOME:-.}/.cache/linuxapp/scripts"
    fi
    # 只删除绝对路径且以 /linuxapp/scripts 结尾的目录，避免误删其它位置。
    case "$lsl_dir" in
        /*/linuxapp/scripts) rm -rf "$lsl_dir" 2>/dev/null || true ;;
    esac
    return 0
}

# 执行同步并按需重新执行本脚本。$1 同步目录，$2 同步原因，$3.. 原始参数。
# 成功时一定以本地脚本重新执行（exec），不会返回；只有拿不到可用脚本时才返回 1。
linuxapp_sync_run() {
    lsr_home=$1
    lsr_reason=$2
    shift 2
    lsr_base=${LINUXAPP_BASE_URL:-$LINUXAPP_BOOTSTRAP_BASE_URL}
    lsr_base=${lsr_base%/}

    case "$lsr_reason" in
        force) printf '正在按 --update 重新拉取 LinuxApp 脚本：%s\n' "$lsr_base" ;;
        stale) printf '本地脚本副本已超过 %s 秒有效期，正在从 %s 更新到 %s\n' "$(linuxapp_sync_ttl)" "$lsr_base" "$lsr_home" ;;
        *) printf '正在从 %s 获取 LinuxApp 脚本到 %s\n' "$lsr_base" "$lsr_home" ;;
    esac

    if linuxapp_sync_pull "$lsr_home" "$lsr_base"; then
        linuxapp_sync_write_stamp "$lsr_home" "$lsr_base" || \
            printf '%s\n' '警告：无法写入同步标记，本次同步时间未能记录。' >&2
        linuxapp_sync_clean_legacy
    else
        # 已经有一份可用副本时降级为继续使用本地副本，避免断网的机器无法进入菜单。
        if ! linuxapp_root_usable "$lsr_home" || [ ! -f "$(linuxapp_sync_stamp_path "$lsr_home")" ]; then
            return 1
        fi
        printf '%s\n' '警告：同步失败，继续使用本地已有的脚本副本（可能不是最新）。' >&2
        # 交给本地副本继续运行时禁止它再次联网，避免同步失败时反复重试。
        LINUXAPP_SYNC_SKIP=1
        export LINUXAPP_SYNC_SKIP
    fi

    printf '%s\n' '脚本已就绪，正在进入 LinuxApp 菜单 ...'
    # 用本地脚本重新执行：既让刚取回的代码生效，也统一去掉只作用于同步阶段的 --update。
    lsr_count=$#
    lsr_index=0
    while [ "$lsr_index" -lt "$lsr_count" ]; do
        lsr_arg=$1
        shift
        case "$lsr_arg" in
            -update|--update) : ;;
            *) set -- "$@" "$lsr_arg" ;;
        esac
        lsr_index=$((lsr_index + 1))
    done
    exec sh "$lsr_home/main.sh" "$@"
}

# 入口准备：定位本地目录；本地副本超过有效期或收到 --update 时重新同步全部脚本。
# 返回 0 表示当前进程可以直接使用 LINUXAPP_ROOT 继续运行。
linuxapp_entry() {
    le_force=0
    for le_arg in "$@"; do
        case "$le_arg" in
            -update|--update) le_force=1 ;;
        esac
    done

    # 上一次同步失败后已经降级使用本地副本，本次不再重复联网。
    if [ "${LINUXAPP_SYNC_SKIP:-0}" = 1 ]; then
        linuxapp_locate_root || return 1
        return 0
    fi

    if linuxapp_locate_root; then
        # 没有同步标记的目录是仓库目录或用户自备的本地目录：脚本直接来自该目录，不做同步。
        if [ ! -f "$(linuxapp_sync_stamp_path "$LINUXAPP_ROOT")" ]; then
            return 0
        fi
        # 带标记的目录是一键运行取回的本地副本：有效期内直接用，过期或 --update 时重新同步。
        if [ "$le_force" -eq 0 ] && linuxapp_sync_fresh "$LINUXAPP_ROOT"; then
            return 0
        fi
        le_home=$LINUXAPP_ROOT
    else
        le_home=$(linuxapp_home_dir)
        # 本地副本仍然有效时直接用本地副本重新执行，不联网。
        if [ "$le_force" -eq 0 ] && linuxapp_root_usable "$le_home" && linuxapp_sync_fresh "$le_home"; then
            exec sh "$le_home/main.sh" "$@"
        fi
    fi

    # 同步原因只用于给出准确的中文提示：--update 强制更新、已有副本超期、首次获取。
    if [ "$le_force" -eq 1 ]; then
        le_reason=force
    elif [ -f "$(linuxapp_sync_stamp_path "$le_home")" ]; then
        le_reason=stale
    else
        le_reason=first
    fi

    linuxapp_sync_run "$le_home" "$le_reason" "$@"
    # linuxapp_sync_run 成功时必然 exec，走到这里说明同步失败且没有可用副本。
    return 1
}

linuxapp_entry "$@" || exit 1
export LINUXAPP_ROOT

# 状态行第四列（凭证等敏感字段）默认显示明文：带 token 的访问地址如果被遮住，用户无法直接打开界面。
# 需要隐藏时用 --hide-secrets；该变量会导出给模块，模块内的同类显示（如 DeepSeek Harness 的访问地址）也遵循它。
LINUXAPP_SHOW_SECRETS=1
# --update 只作用于同步阶段。走到参数解析说明当前脚本直接来自本地目录，入口没有执行同步，
# 此时记录标记，等界面初始化后再提示用户。
LINUXAPP_UPDATE_NOTICE=0
LINUXAPP_SPECIAL_ACTION=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -update|--update) LINUXAPP_UPDATE_NOTICE=1 ;;
        --show-secrets) LINUXAPP_SHOW_SECRETS=1 ;;
        --hide-secrets) LINUXAPP_SHOW_SECRETS=0 ;;
        --install-ssh-hook|--remove-ssh-hook)
            if [ -n "$LINUXAPP_SPECIAL_ACTION" ]; then
                printf '%s\n' '错误：不能同时指定多个特殊动作。' >&2
                exit 2
            fi
            LINUXAPP_SPECIAL_ACTION=$1
            ;;
        --help|-h)
            printf '%s\n' '用法：main.sh [--update] [--show-secrets|--hide-secrets]'
            printf '%s\n' '       main.sh --install-ssh-hook'
            printf '%s\n' '       main.sh --remove-ssh-hook'
            printf '%s\n' ''
            printf '%s\n' '--update   忽略本地副本有效期，重新拉取全部脚本后再进入菜单'
            exit 0
            ;;
        *)
            printf '错误：未知参数：%s\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

case "$LINUXAPP_SPECIAL_ACTION" in
    --install-ssh-hook)
        . "$LINUXAPP_ROOT/config/source.sh"
        . "$LINUXAPP_ROOT/lib/ui.sh"
        . "$LINUXAPP_ROOT/lib/ssh_hook.sh"
        ui_init
        ssh_hook_install
        exit $?
        ;;
    --remove-ssh-hook)
        . "$LINUXAPP_ROOT/config/source.sh"
        . "$LINUXAPP_ROOT/lib/ui.sh"
        . "$LINUXAPP_ROOT/lib/ssh_hook.sh"
        ui_init
        ssh_hook_remove
        exit $?
        ;;
esac
export LINUXAPP_SHOW_SECRETS

. "$LINUXAPP_ROOT/config/source.sh" || exit 1
. "$LINUXAPP_ROOT/lib/ui.sh" || exit 1
. "$LINUXAPP_ROOT/lib/input.sh" || exit 1
. "$LINUXAPP_ROOT/lib/state.sh" || exit 1
. "$LINUXAPP_ROOT/lib/system.sh" || exit 1
. "$LINUXAPP_ROOT/lib/privilege.sh" || exit 1
. "$LINUXAPP_ROOT/lib/lifecycle.sh" || exit 1
. "$LINUXAPP_ROOT/lib/dependency.sh" || exit 1
. "$LINUXAPP_ROOT/lib/ssh_hook.sh" || exit 1
. "$LINUXAPP_ROOT/lib/loader.sh" || exit 1

LINUXAPP_STATE_DIR=$(state_dir)
export LINUXAPP_STATE_DIR

CHILD_RUNNING=0
CHILD_INTERRUPTED=0

main_cleanup() {
    input_restore_terminal
}

# shellcheck disable=SC2329
main_interrupt() {
    if [ "$CHILD_RUNNING" -eq 1 ]; then
        CHILD_INTERRUPTED=1
        return 0
    fi
    main_cleanup
    printf '\n%s\n' '已收到 Ctrl+C，LinuxApp 菜单已退出，当前 SSH 终端仍可继续使用。'
    exit 130
}

# shellcheck disable=SC2329
main_terminate() {
    main_cleanup
    printf '\n%s\n' 'LinuxApp 已终止。'
    exit 143
}

trap 'main_interrupt' INT
trap 'main_terminate' TERM HUP

MODULE_FOUND=0
MODULE_TYPE=''
MODULE_PATH=''
MODULE_LABEL=''

find_module_by_index() {
    wanted_type=$1
    wanted_index=$2
    MODULE_FOUND=0
    module_index=0
    while IFS='|' read -r module_type _ module_path module_label; do
        case "$module_type" in
            ''|'#'*) continue ;;
        esac
        if [ "$module_type" = "$wanted_type" ]; then
            module_index=$((module_index + 1))
        fi
        if [ "$module_type" = "$wanted_type" ] && [ "$module_index" = "$wanted_index" ]; then
            MODULE_FOUND=1
            MODULE_TYPE=$module_type
            MODULE_PATH=$module_path
            MODULE_LABEL=$module_label
            return 0
        fi
    done < "$LINUXAPP_ROOT/config/modules.list"
    return 1
}

# 变量统一使用 msv_ 前缀：POSIX sh 没有局部变量，函数内赋值会覆盖同名全局变量。
module_status_values() {
    msv_path=$2
    MODULE_STATE='异常'
    MODULE_VERSION='未知'
    MODULE_INFO='脚本不可用'
    MODULE_SECRET=''
    if ! loader_ensure_script "$msv_path"; then
        return 1
    fi
    msv_raw=$(lifecycle_status "$LOADED_MODULE_PATH" 2>&1)
    msv_code=$?
    if [ "$msv_code" -ne 0 ] && [ -z "$msv_raw" ]; then
        return "$msv_code"
    fi
    MODULE_STATE=$(printf '%s\n' "$msv_raw" | awk -F '|' 'NR == 1 { print $1 }')
    MODULE_VERSION=$(printf '%s\n' "$msv_raw" | awk -F '|' 'NR == 1 { print $2 }')
    MODULE_INFO=$(printf '%s\n' "$msv_raw" | awk -F '|' 'NR == 1 { print $3 }')
    MODULE_SECRET=$(printf '%s\n' "$msv_raw" | awk -F '|' 'NR == 1 { print $4 }')
    [ -n "$MODULE_STATE" ] || MODULE_STATE='异常'
    [ -n "$MODULE_VERSION" ] || MODULE_VERSION='未知'
    [ -n "$MODULE_INFO" ] || MODULE_INFO='无状态信息'
    if [ -n "$MODULE_SECRET" ]; then
        if [ "$LINUXAPP_SHOW_SECRETS" -eq 1 ]; then
            MODULE_INFO="$MODULE_INFO；凭证：$MODULE_SECRET"
        else
            MODULE_INFO="$MODULE_INFO；凭证：******"
        fi
    fi
    return 0
}

print_module_row() {
    row_type=$1
    row_label=$2
    row_path=$3
    module_status_values "$row_type" "$row_path" || true
    row_status_color=$(ui_status_color "$MODULE_STATE")
    printf '%s%s%s | %s%s%s | %s%s%s | %s%s%s\n' \
        "$UI_BOLD" "$row_label" "$UI_RESET" \
        "$UI_SECONDARY" "$MODULE_VERSION" "$UI_RESET" \
        "$row_status_color" "$MODULE_STATE" "$UI_RESET" \
        "$UI_SECONDARY" "$MODULE_INFO" "$UI_RESET"
}

print_module_group() {
    group_type=$1
    group_title=$2
    printf '%s[%s]%s\n' "$UI_BOLD" "$group_title" "$UI_RESET"
    group_found=0
    while IFS='|' read -r module_type _ module_path module_label; do
        case "$module_type" in
            ''|'#'*) continue ;;
        esac
        if [ "$module_type" = "$group_type" ]; then
            group_found=1
            print_module_row "$module_type" "$module_label" "$module_path"
        fi
    done < "$LINUXAPP_ROOT/config/modules.list"
    [ "$group_found" -eq 1 ] || ui_text '（暂无模块）'
}

show_dashboard() {
    ui_clear
    ui_header
    ui_section '系统基础信息'
    printf '%s主机%s | %s%s%s\n' "$UI_PRIMARY" "$UI_RESET" "$UI_SECONDARY" "$(system_hostname)" "$UI_RESET"
    printf '%s系统%s | %s%s%s\n' "$UI_PRIMARY" "$UI_RESET" "$UI_SECONDARY" "$(system_distribution)" "$UI_RESET"
    printf '%s内核%s | %s%s%s\n' "$UI_PRIMARY" "$UI_RESET" "$UI_SECONDARY" "$(system_kernel)" "$UI_RESET"
    printf '%s架构%s | %s%s%s\n' "$UI_PRIMARY" "$UI_RESET" "$UI_SECONDARY" "$(system_architecture)" "$UI_RESET"
    printf '%s用户%s | %s%s%s\n' "$UI_PRIMARY" "$UI_RESET" "$UI_SECONDARY" "$(system_user)" "$UI_RESET"
    ui_section '已安装列表'
    print_module_group software '软件类'
    print_module_group language '语言类'
    ui_section '功能区'
    ui_menu_item '1.' '应用管理'
    ui_menu_item '2.' 'SSH 登录钩子管理'
    ui_menu_item 'R.' '刷新状态'
    ui_menu_item '0.' '退出'
    printf '\n'
}

# 执行模块动作。参数使用 rma_ 前缀：POSIX sh 没有局部变量，若沿用调用方的
# 变量名（如 action_path），会把 module_actions_menu 的脚本路径覆盖成缓存脚本
# 的绝对路径，导致动作结束后刷新界面时按相对路径找不到模块脚本。
run_module_action() {
    rma_type=$1
    rma_path=$2
    rma_name=$3
    CHILD_RUNNING=1
    CHILD_INTERRUPTED=0
    action_output=$(lifecycle_action "$rma_path" "$rma_type" "$rma_name" 2>&1)
    rma_status=$?
    CHILD_RUNNING=0
    if [ -n "$action_output" ]; then
        ui_text_block <<EOF
$action_output
EOF
    fi
    if [ "$CHILD_INTERRUPTED" -eq 1 ] || [ "$rma_status" -eq 130 ]; then
        ui_warn '子任务已中断，返回当前模块的上一级菜单。'
        return 130
    fi
    return "$rma_status"
}

# 把模块脚本路径解析为绝对路径：绝对路径原样返回，相对路径拼到本地目录。
module_resolve_path() {
    mrp_input=$1
    case "$mrp_input" in
        /*)
            printf '%s\n' "$mrp_input"
            return 0
            ;;
    esac
    printf '%s\n' "$LINUXAPP_ROOT/$mrp_input"
}

# 语言模块的动作列表：基础动作加上模块自报的可选能力（切换版本、更新）。
module_language_actions() {
    module_cap_path=$(module_resolve_path "$1")
    MODULE_CAPABILITIES=$(lifecycle_capabilities "$module_cap_path" 2>/dev/null || true)
    MODULE_ACTION_MAP='install:安装'
    case " $MODULE_CAPABILITIES " in
        *' switch '*) MODULE_ACTION_MAP="$MODULE_ACTION_MAP switch:切换版本" ;;
    esac
    case " $MODULE_CAPABILITIES " in
        *' update '*) MODULE_ACTION_MAP="$MODULE_ACTION_MAP update:更新" ;;
    esac
    case " $MODULE_CAPABILITIES " in
        *' repair '*) MODULE_ACTION_MAP="$MODULE_ACTION_MAP repair:修复环境" ;;
    esac
    MODULE_ACTION_MAP="$MODULE_ACTION_MAP uninstall:卸载 status:查看状态"
    return 0
}

# 软件模块的动作列表：六个基础动作加上模块按当前状态自报的附加动作（可选动作 extras）。
# extras 每行输出「动作键|中文名」，动作键会原样传给模块脚本；与基础动作同名的条目会被忽略，
# 避免模块自报的动作覆盖框架约定的生命周期动作。
module_software_actions() {
    module_sa_path=$(module_resolve_path "$1")
    MODULE_ACTION_MAP='install:安装 start:启动 stop:停止 update:更新 uninstall:卸载 status:查看状态'
    module_sa_extras=$(lifecycle_extras "$module_sa_path" 2>/dev/null || true)
    if [ -n "$module_sa_extras" ]; then
        module_sa_map=$MODULE_ACTION_MAP
        while IFS= read -r module_sa_line; do
            case "$module_sa_line" in
                ''|'#'*) continue ;;
            esac
            module_sa_key=${module_sa_line%%|*}
            module_sa_label=${module_sa_line#*|}
            # 没有分隔符或动作键为空的行不是合法声明，直接跳过。
            [ -n "$module_sa_key" ] || continue
            [ "$module_sa_label" != "$module_sa_line" ] || continue
            module_sa_dup=0
            for module_sa_pair in $module_sa_map; do
                if [ "${module_sa_pair%%:*}" = "$module_sa_key" ]; then
                    module_sa_dup=1
                    break
                fi
            done
            [ "$module_sa_dup" -eq 0 ] || continue
            module_sa_map="$module_sa_map $module_sa_key:$module_sa_label"
        done <<EOF
$module_sa_extras
EOF
        MODULE_ACTION_MAP=$module_sa_map
    fi
    return 0
}

# 软件模块的依赖语言状态（只读，供菜单显示）。没有声明依赖时不输出任何内容。
module_dependency_report() {
    module_dp_path=$(module_resolve_path "$1")
    module_dp_lines=$(dependency_report "$module_dp_path" 2>/dev/null || true)
    [ -n "$module_dp_lines" ] || return 0
    while IFS= read -r module_dp_line; do
        [ -n "$module_dp_line" ] || continue
        printf '%s依赖语言%s | %s%s%s\n' \
            "$UI_PRIMARY" "$UI_RESET" "$UI_SECONDARY" "$module_dp_line" "$UI_RESET"
    done <<EOF
$module_dp_lines
EOF
    return 0
}

# 软件模块动作执行前的语言依赖确保：缺少依赖语言时先调用语言模块安装。
# 返回 1 时调用方必须中止当前动作（此时尚未产生任何副作用）。
module_ensure_dependencies() {
    module_ed_type=$1
    module_ed_label=$2
    module_ed_script=$3
    module_ed_action=$4
    [ "$module_ed_type" = software ] || return 0
    case "$module_ed_action" in
        install|update|start) ;;
        *) return 0 ;;
    esac
    dependency_ensure "$module_ed_label" "$module_ed_script"
}

module_actions_menu() {
    action_type=$1
    action_label=$2
    action_path=$3
    while :; do
        ui_clear
        ui_header
        ui_section "$action_label"
        module_status_values "$action_type" "$action_path" || true
        action_status_color=$(ui_status_color "$MODULE_STATE")
        printf '%s当前状态%s | %s%s%s | %s%s%s\n' \
            "$UI_PRIMARY" "$UI_RESET" "$action_status_color" "$MODULE_STATE" "$UI_RESET" "$UI_SECONDARY" "$MODULE_INFO" "$UI_RESET"
        if [ "$action_type" = software ]; then
            module_dependency_report "$action_path"
        fi
        printf '\n'
        if [ "$action_type" = software ]; then
            module_software_actions "$action_path"
        else
            module_language_actions "$action_path"
        fi
        module_action_index=0
        for module_action_pair in $MODULE_ACTION_MAP; do
            module_action_index=$((module_action_index + 1))
            ui_menu_item "$module_action_index." "${module_action_pair#*:}"
        done
        ui_menu_item 'b.' '返回'
        read_key || return 1
        action_name=''
        case "$READ_KEY" in
            b|B) return 0 ;;
            0)
                ui_warn '返回请按 b。'
                continue
                ;;
            *[!0-9]*)
                if input_key_is_blank "$READ_KEY"; then
                    continue
                fi
                ui_warn '无效选择。'
                continue
                ;;
        esac
        module_action_index=0
        for module_action_pair in $MODULE_ACTION_MAP; do
            module_action_index=$((module_action_index + 1))
            if [ "$module_action_index" = "$READ_KEY" ]; then
                action_name=${module_action_pair%%:*}
                break
            fi
        done
        if [ -z "$action_name" ]; then
            ui_warn '无效选择。'
            continue
        fi
        if [ "$action_name" = status ]; then
            module_status_values "$action_type" "$action_path" || true
            status_color=$(ui_status_color "$MODULE_STATE")
            printf '%s状态%s | %s%s%s | %s%s%s\n' "$UI_PRIMARY" "$UI_RESET" "$status_color" "$MODULE_STATE" "$UI_RESET" "$UI_SECONDARY" "$MODULE_INFO" "$UI_RESET"
            ui_wait_key || return 1
            continue
        fi
        if ! loader_ensure_script "$action_path"; then
            ui_wait_key || return 1
            continue
        fi
        if ! module_ensure_dependencies "$action_type" "$action_label" "$LOADED_MODULE_PATH" "$action_name"; then
            ui_warn '依赖语言环境未满足，本次操作已中止。'
            ui_wait_key || return 1
            continue
        fi
        run_module_action "$action_type" "$LOADED_MODULE_PATH" "$action_name"
        action_status=$?
        [ "$action_status" -eq 130 ] && return 0
        if [ "$action_status" -eq 0 ]; then
            ui_ok '操作已完成。'
        else
            ui_error "操作失败，返回码：$action_status"
        fi
        ui_wait_key || return 1
    done
}

module_list_menu() {
    list_type=$1
    list_title=$2
    while :; do
        ui_clear
        ui_header
        ui_section "$list_title"
        list_found=0
        list_index=0
        while IFS='|' read -r module_type _ module_path module_label; do
            case "$module_type" in
                ''|'#'*) continue ;;
            esac
            if [ "$module_type" = "$list_type" ]; then
                list_found=1
                list_index=$((list_index + 1))
                module_status_values "$module_type" "$module_path" || true
                list_status_color=$(ui_status_color "$MODULE_STATE")
                printf '%s%s%s | %s%s%s | %s%s%s\n' \
                    "$UI_PRIMARY" "$list_index" "$UI_RESET" \
                    "$UI_BOLD" "$module_label" "$UI_RESET" \
                    "$list_status_color" "$MODULE_STATE" "$UI_RESET"
            fi
        done < "$LINUXAPP_ROOT/config/modules.list"
        [ "$list_found" -eq 1 ] || ui_text '暂无可用模块。'
        printf '\n'
        ui_menu_item 'b.' '返回'
        if [ "$list_type" = software ]; then
            # 软件模块后续会继续增加，编号可能超过一位，因此使用普通输入模式：
            # 输入编号后按回车确认；按 b 仍然立即返回，不需要回车。
            printf '%s输入编号后按回车确认：%s' "$UI_SECONDARY" "$UI_RESET"
            read_line || return 1
            list_reply=$READ_LINE
        else
            read_key || return 1
            list_reply=$READ_KEY
        fi
        case "$list_reply" in
            b|B) return 0 ;;
        esac
        if input_key_is_blank "$list_reply"; then
            continue
        fi
        if [ "$list_reply" = 0 ]; then
            ui_warn '返回请按 b。'
            continue
        fi
        if [ "$list_type" = software ]; then
            case "$list_reply" in
                *[!0-9]*)
                    ui_warn '无效选择，请输入列表中的数字编号。'
                    continue
                    ;;
            esac
            # 去掉编号的前导 0，输入 01、007 也能匹配到对应序号。
            while :; do
                case "$list_reply" in
                    0[0-9]*) list_reply=${list_reply#0} ;;
                    *) break ;;
                esac
            done
        fi
        find_module_by_index "$list_type" "$list_reply"
        if [ "$MODULE_FOUND" -eq 1 ]; then
            module_actions_menu "$MODULE_TYPE" "$MODULE_LABEL" "$MODULE_PATH"
        else
            ui_warn '没有找到对应模块。'
        fi
    done
}

application_menu() {
    while :; do
        ui_clear
        ui_header
        ui_section '应用管理'
        ui_menu_item '1.' '软件模块'
        ui_menu_item '2.' '语言模块'
        ui_menu_item 'b.' '返回'
        read_key || return 1
        case "$READ_KEY" in
            1) module_list_menu software '软件模块' ;;
            2) module_list_menu language '语言模块' ;;
            b|B) return 0 ;;
            0)
                ui_warn '返回请按 b。'
                ;;
            *)
                if ! input_key_is_blank "$READ_KEY"; then
                    ui_warn '无效选择。'
                fi
                ;;
        esac
    done
}

ssh_menu() {
    while :; do
        ui_clear
        ui_header
        ui_section 'SSH 登录钩子管理'
        ui_menu_item '1.' '安装当前用户登录钩子'
        ui_menu_item '2.' '移除当前用户登录钩子'
        ui_menu_item 'b.' '返回'
        read_key || return 1
        case "$READ_KEY" in
            1) ssh_hook_install; ui_wait_key || return 1 ;;
            2) ssh_hook_remove; ui_wait_key || return 1 ;;
            b|B) return 0 ;;
            0)
                ui_warn '返回请按 b。'
                ;;
            *)
                if ! input_key_is_blank "$READ_KEY"; then
                    ui_warn '无效选择。'
                fi
                ;;
        esac
    done
}

main_loop() {
    while :; do
        show_dashboard
        read_key || {
            ui_error '无法读取键盘输入，必须在交互式终端运行。'
            return 1
        }
        case "$READ_KEY" in
            1) application_menu ;;
            2) ssh_menu ;;
            r|R) : ;;
            3)
                ui_warn '刷新状态请按 R。'
                ;;
            0) return 0 ;;
            *)
                if ! input_key_is_blank "$READ_KEY"; then
                    ui_warn '无效选择。'
                fi
                ;;
        esac
    done
}

ui_init
if [ "$LINUXAPP_UPDATE_NOTICE" -eq 1 ]; then
    ui_warn "--update 只对一键运行取回的本地副本生效；当前脚本直接来自 $LINUXAPP_ROOT，未执行同步。"
    ui_text '本地仓库内的更新请执行 git pull 后重新运行。'
fi
# 全部脚本都在同步阶段落地本机，运行期不再联网，因此这里按清单检查一遍再进入菜单。
loader_validate_local || exit 1
if ! input_is_interactive; then
    ui_error 'main.sh 菜单必须在交互式终端中运行。需要自动化调用时请使用模块脚本接口。'
    exit 1
fi

main_loop
main_status=$?
main_cleanup
exit "$main_status"

# Last updated: 2026-09-12 09:34
