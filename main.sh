#!/bin/sh

# 入口定位：本地仓库运行时按脚本所在目录解析；一键命令
# （例如 `sh -c "$(curl -fsSL https://.../main.sh)"`）执行时 $0 不是文件路径，
# 解析不到仓库，此时把框架文件取回用户目录，再以该目录为根目录重新执行本脚本。
# 站点地址优先取环境变量：自举阶段还没有 config/source.sh，只能先用下面的内置默认值，
# 自举完成后由 config/source.sh 接管（两处默认值保持一致，可继续用 LINUXAPP_BASE_URL 覆盖）。
LINUXAPP_BOOTSTRAP_BASE_URL=${LINUXAPP_BASE_URL:-https://linuxapp.xiaozhuhouses.asia/}
LINUXAPP_ROOT=''

# 目录内是否具备最小可运行框架文件。
linuxapp_root_usable() {
    [ -n "$1" ] && [ -f "$1/config/source.sh" ] && [ -f "$1/config/modules.list" ] && [ -f "$1/lib/ui.sh" ]
}

# 先看脚本自身目录，再看当前工作目录；两者都不成立时返回 1，交给在线自举处理。
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
linuxapp_bootstrap_fetch() {
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
        printf '%s\n' '错误：系统中找不到 curl 或 wget，无法获取 LinuxApp 框架文件。' >&2
        printf '%s\n' '请在 LinuxApp 仓库目录内直接运行 ./main.sh。' >&2
        return 1
    fi
    if [ "$lbf_status" -eq 0 ] && [ -s "$lbf_tmp" ]; then
        mv "$lbf_tmp" "$lbf_target" && return 0
    fi
    rm -f "$lbf_tmp"
    return 1
}

# 在线自举：按 config/bootstrap.list 逐行取回框架文件，随后进入菜单。
# 目录默认放在用户数据目录，可用 LINUXAPP_HOME 覆盖；只有框架文件会落地，
# 模块脚本仍由 lib/loader.sh 在菜单中按需在线加载。
linuxapp_bootstrap() {
    lb_base=${LINUXAPP_BASE_URL:-$LINUXAPP_BOOTSTRAP_BASE_URL}
    lb_base=${lb_base%/}
    if [ -n "${LINUXAPP_HOME:-}" ]; then
        lb_home=$LINUXAPP_HOME
    elif [ -n "${XDG_DATA_HOME:-}" ]; then
        lb_home="$XDG_DATA_HOME/linuxapp"
    else
        lb_home="${HOME:-.}/.local/share/linuxapp"
    fi
    lb_manifest="$lb_home/config/bootstrap.list"

    printf '首次运行：正在从 %s 获取 LinuxApp 文件到 %s\n' "$lb_base" "$lb_home"
    if ! linuxapp_bootstrap_fetch "$lb_base/config/bootstrap.list" "$lb_manifest"; then
        printf '错误：无法下载文件清单 %s/config/bootstrap.list，请检查网络后重试。\n' "$lb_base" >&2
        printf '%s\n' '提示：也可以先下载整个 LinuxApp 仓库，再在仓库目录内运行 ./main.sh。' >&2
        return 1
    fi

    lb_failed=''
    while IFS= read -r lb_rel || [ -n "$lb_rel" ]; do
        case "$lb_rel" in
            ''|'#'*) continue ;;
        esac
        # 清单只允许仓库内的相对路径，防止被篡改的清单写到项目目录之外。
        case "$lb_rel" in
            /*|*..*)
                printf '错误：文件清单中存在非法路径：%s\n' "$lb_rel" >&2
                return 1
                ;;
        esac
        if ! linuxapp_bootstrap_fetch "$lb_base/$lb_rel" "$lb_home/$lb_rel"; then
            lb_failed=$lb_rel
            break
        fi
    done < "$lb_manifest"
    if [ -n "$lb_failed" ]; then
        printf '错误：下载框架文件失败：%s/%s\n' "$lb_base" "$lb_failed" >&2
        printf '%s\n' '请检查网络连通性，或先下载整个 LinuxApp 仓库后在仓库目录内运行 ./main.sh。' >&2
        return 1
    fi
    chmod +x "$lb_home/main.sh" 2>/dev/null || true
    LINUXAPP_ROOT=$lb_home
    # 固定加载源：框架与模块脚本必须来自同一次部署，避免混用不同站点的版本。
    LINUXAPP_BASE_URL=$lb_base
    export LINUXAPP_ROOT LINUXAPP_BASE_URL
    printf '%s\n' '框架文件已就绪，正在进入 LinuxApp 菜单 ...'
    exec sh "$lb_home/main.sh" "$@"
}

if ! linuxapp_locate_root; then
    linuxapp_bootstrap "$@" || exit 1
fi
export LINUXAPP_ROOT

LINUXAPP_OFFLINE=0
# 状态行第四列（凭证等敏感字段）默认显示明文：带 token 的访问地址如果被遮住，用户无法直接打开界面。
# 需要隐藏时用 --hide-secrets；该变量会导出给模块，模块内的同类显示（如 DeepSeek Harness 的访问地址）也遵循它。
LINUXAPP_SHOW_SECRETS=1
LINUXAPP_SPECIAL_ACTION=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -offline) LINUXAPP_OFFLINE=1 ;;
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
            printf '%s\n' '用法：main.sh [-offline] [--show-secrets|--hide-secrets]'
            printf '%s\n' '       main.sh --install-ssh-hook'
            printf '%s\n' '       main.sh --remove-ssh-hook'
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
export LINUXAPP_OFFLINE LINUXAPP_SHOW_SECRETS

. "$LINUXAPP_ROOT/config/source.sh" || exit 1
. "$LINUXAPP_ROOT/lib/ui.sh" || exit 1
. "$LINUXAPP_ROOT/lib/input.sh" || exit 1
. "$LINUXAPP_ROOT/lib/cache.sh" || exit 1
. "$LINUXAPP_ROOT/lib/system.sh" || exit 1
. "$LINUXAPP_ROOT/lib/privilege.sh" || exit 1
. "$LINUXAPP_ROOT/lib/lifecycle.sh" || exit 1
. "$LINUXAPP_ROOT/lib/dependency.sh" || exit 1
. "$LINUXAPP_ROOT/lib/ssh_hook.sh" || exit 1
. "$LINUXAPP_ROOT/lib/loader.sh" || exit 1

LINUXAPP_STATE_DIR=$(cache_root)/state
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

# 把模块脚本路径解析为绝对路径：仓库内相对路径优先，其次使用缓存脚本。
module_resolve_path() {
    mrp_input=$1
    case "$mrp_input" in
        /*)
            printf '%s\n' "$mrp_input"
            return 0
            ;;
    esac
    if [ -f "$LINUXAPP_ROOT/$mrp_input" ]; then
        printf '%s\n' "$LINUXAPP_ROOT/$mrp_input"
        return 0
    fi
    cache_script_path "$mrp_input"
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
if [ "$LINUXAPP_OFFLINE" -eq 1 ]; then
    loader_validate_offline || exit 1
fi
if ! input_is_interactive; then
    ui_error 'main.sh 菜单必须在交互式终端中运行。需要自动化调用时请使用模块脚本接口。'
    exit 1
fi

main_loop
main_status=$?
main_cleanup
exit "$main_status"

# Last updated: 2026-09-12 08:53
