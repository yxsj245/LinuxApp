#!/bin/sh

# LinuxApp 框架级语言依赖联动库。
#
# 软件模块通过可选动作 requires 声明自己依赖的语言环境（例如 nodejs），框架在安装、更新、
# 启动软件之前调用本库，确认对应语言模块的状态；缺少时直接调用该语言模块的 install 动作，
# 让「装软件」这一步顺手把运行环境准备好。
#
# 约定：
# 1. 只使用 POSIX sh 语法，不依赖 Bash 专有特性。
# 2. 本库自包含：不依赖 lib/ui.sh，也不依赖 lib/lang.sh，因此框架菜单与模块脚本都能直接调用。
# 3. 面向用户的提示优先写 /dev/tty：框架通过命令替换捕获动作输出，若提示写标准输出，
#    用户会在操作结束后才看到内容，交互过程会像卡住一样没有任何反馈。
# 4. 所有决策都可以用环境变量给出，便于非交互场景自动化：LINUXAPP_APP_AUTO_DEPS=1 自动安装、
#    0 只提示不安装；未设置且没有终端时一律按「不满足」处理，绝不猜测。

# ---------------------------------------------------------------- 终端输出

dep_has_tty() {
    # /dev/tty 的权限位始终可读可写，但进程没有控制终端时打开会失败，必须真实尝试打开。
    if (exec 9> /dev/tty) 2>/dev/null; then
        exec 9>&-
        return 0
    fi
    return 1
}

dep_out() {
    if dep_has_tty && printf '%s\n' "$1" > /dev/tty 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$1"
}

dep_info() {
    dep_out "[信息] $1"
}

dep_warn() {
    dep_out "[警告] $1"
}

dep_fail() {
    dep_out "[错误] $1"
}

# 确认提示：$1 提示语，$2 默认值（y 或 n）。返回 0 表示确认。
dep_confirm() {
    dep_cf_prompt=$1
    dep_cf_default=${2:-n}
    case "$dep_cf_default" in
        y|Y) dep_cf_hint='[Y/n]' ;;
        *) dep_cf_hint='[y/N]' ;;
    esac
    if ! dep_has_tty; then
        dep_warn '当前不是交互式终端，无法确认依赖安装；请设置 LINUXAPP_APP_AUTO_DEPS=1 自动安装，或先手工安装依赖语言。'
        return 1
    fi
    while :; do
        if ! printf '%s' "$dep_cf_prompt $dep_cf_hint " > /dev/tty 2>/dev/null; then
            printf '%s' "$dep_cf_prompt $dep_cf_hint "
        fi
        if ! IFS= read -r dep_cf_reply < /dev/tty; then
            dep_warn '无法读取输入，已取消依赖安装。'
            return 1
        fi
        case "$dep_cf_reply" in
            '')
                case "$dep_cf_default" in
                    y|Y) return 0 ;;
                    *) return 1 ;;
                esac
                ;;
            y|Y|yes|YES|是) return 0 ;;
            n|N|no|NO|否) return 1 ;;
            *) dep_warn '请输入 y 或 n。' ;;
        esac
    done
}

# ---------------------------------------------------------------- 依赖解析

# 读取软件模块声明的依赖语言键（模块可选动作 requires，输出空格分隔的语言键）。
dependency_languages() {
    dep_lg_path=$1
    [ -f "$dep_lg_path" ] || return 1
    dep_lg_list=$(sh "$dep_lg_path" requires 2>/dev/null || true)
    [ -n "$dep_lg_list" ] || return 1
    printf '%s\n' "$dep_lg_list"
}

# 定位 LinuxApp 仓库根目录：优先 LINUXAPP_ROOT，其次按模块脚本路径推断。
# $1 模块脚本路径（可空）。成功时输出仓库根目录。
dependency_repo_root() {
    if [ -n "${LINUXAPP_ROOT:-}" ] && [ -f "$LINUXAPP_ROOT/config/modules.list" ]; then
        printf '%s\n' "$LINUXAPP_ROOT"
        return 0
    fi
    dep_rr_path=${1:-}
    case "$dep_rr_path" in
        */modules/*)
            dep_rr_root=${dep_rr_path%%/modules/*}
            if [ -n "$dep_rr_root" ] && [ -f "$dep_rr_root/config/modules.list" ]; then
                printf '%s\n' "$dep_rr_root"
                return 0
            fi
            ;;
    esac
    return 1
}

# 语言键 → 语言模块脚本相对路径。$1 语言键，$2 仓库根目录（可空）。
# 成功时把相对路径写入 DEP_MODULE_PATH、显示名写入 DEP_LABEL，返回 0。
dependency_language_module() {
    dep_lm_key=$1
    dep_lm_root=${2:-}
    [ -n "$dep_lm_root" ] || dep_lm_root=$(dependency_repo_root "") || return 1
    DEP_MODULE_PATH=''
    DEP_LABEL=''
    dep_lm_found=1
    while IFS='|' read -r dep_lm_type dep_lm_id dep_lm_path dep_lm_label; do
        case "$dep_lm_type" in
            ''|'#'*) continue ;;
        esac
        if [ "$dep_lm_type" = language ] && [ "$dep_lm_id" = "$dep_lm_key" ]; then
            DEP_MODULE_PATH=$dep_lm_path
            DEP_LABEL=$dep_lm_label
            dep_lm_found=0
            break
        fi
    done < "$dep_lm_root/config/modules.list"
    [ "$dep_lm_found" -eq 0 ] || return 1
    [ -n "$DEP_MODULE_PATH" ] || return 1
    return 0
}

# 定位语言模块脚本：$1 本地目录，$2 模块相对路径。成功时把实际路径写入 DEP_SCRIPT_PATH。
# 全部脚本在入口同步阶段就取回本地，这里只做本地查找，运行期不联网。
dependency_language_script() {
    dep_dls_root=$1
    dep_dls_rel=$2
    DEP_SCRIPT_PATH="$dep_dls_root/$dep_dls_rel"
    [ -f "$DEP_SCRIPT_PATH" ]
}

# 查询语言模块状态：$1 语言模块脚本路径。状态写入 DEP_STATE，版本写入 DEP_VERSION。
dependency_language_state() {
    dep_ls_path=$1
    DEP_STATE='异常'
    DEP_VERSION='未知'
    [ -f "$dep_ls_path" ] || return 1
    dep_ls_raw=$(sh "$dep_ls_path" status 2>/dev/null || true)
    DEP_STATE=$(printf '%s\n' "$dep_ls_raw" | awk -F '|' 'NR == 1 { print $1 }')
    DEP_VERSION=$(printf '%s\n' "$dep_ls_raw" | awk -F '|' 'NR == 1 { print $2 }')
    [ -n "$DEP_STATE" ] || DEP_STATE='异常'
    [ -n "$DEP_VERSION" ] || DEP_VERSION='未知'
    return 0
}

# ---------------------------------------------------------------- 对外接口

# 依赖状态报告（只读，供菜单显示）。$1 软件模块脚本路径。
# 每行输出「语言显示名：状态（版本）」，没有依赖或无法解析时输出为空。
# 语言模块脚本随入口同步落地本地，因此这里直接读取真实状态，不做任何联网动作。
dependency_report() {
    dep_rp_path=$1
    dep_rp_root=$(dependency_repo_root "$dep_rp_path" 2>/dev/null || true)
    [ -n "$dep_rp_root" ] || return 0
    dep_rp_langs=$(dependency_languages "$dep_rp_path" 2>/dev/null || true)
    [ -n "$dep_rp_langs" ] || return 0
    for dep_rp_key in $dep_rp_langs; do
        if dependency_language_module "$dep_rp_key" "$dep_rp_root"; then
            dep_rp_rel=$DEP_MODULE_PATH
            dep_rp_script=''
            if dependency_language_script "$dep_rp_root" "$dep_rp_rel"; then
                dep_rp_script=$DEP_SCRIPT_PATH
            fi
            if [ -f "$dep_rp_script" ]; then
                dependency_language_state "$dep_rp_script"
            else
                # 本地没有该脚本时无法判断状态，按“未安装”提示，用户可重新执行 --update 拉取脚本。
                DEP_STATE='未安装'
                DEP_VERSION='-'
            fi
            printf '%s：%s（%s）\n' "$DEP_LABEL" "$DEP_STATE" "$DEP_VERSION"
        else
            printf '%s：清单中未登记该语言模块\n' "$dep_rp_key"
        fi
    done
    return 0
}

# 确保依赖语言已安装。$1 应用显示名，$2 软件模块脚本路径。
# 返回 0 表示依赖已满足（或该模块没有声明依赖），返回 1 表示未满足，调用方必须中止当前操作。
dependency_ensure() {
    dep_en_app=$1
    dep_en_path=$2
    dep_en_root=$(dependency_repo_root "$dep_en_path" 2>/dev/null || true)
    if [ -z "$dep_en_root" ]; then
        dep_warn '无法定位 LinuxApp 仓库目录（缺少 config/modules.list），已跳过语言依赖检查。'
        return 0
    fi
    dep_en_langs=$(dependency_languages "$dep_en_path" 2>/dev/null || true)
    if [ -z "$dep_en_langs" ]; then
        return 0
    fi

    for dep_en_key in $dep_en_langs; do
        if ! dependency_language_module "$dep_en_key" "$dep_en_root"; then
            dep_fail "应用「$dep_en_app」依赖语言模块 $dep_en_key，但 config/modules.list 中没有登记该语言模块。"
            return 1
        fi
        dep_en_rel=$DEP_MODULE_PATH
        dep_en_label=$DEP_LABEL
        # 语言模块脚本随入口同步落地本地；这里只做本地查找，找不到就明确报错而不是误判为已满足。
        dep_en_script=''
        if dependency_language_script "$dep_en_root" "$dep_en_rel"; then
            dep_en_script=$DEP_SCRIPT_PATH
        fi
        if [ -z "$dep_en_script" ] || [ ! -f "$dep_en_script" ]; then
            dep_fail "语言模块脚本不存在：$dep_en_root/$dep_en_rel；请重新执行 ./main.sh --update 拉取全部脚本。"
            return 1
        fi
        dependency_language_state "$dep_en_script"
        if [ "$DEP_STATE" = '已安装' ]; then
            dep_info "依赖语言环境已满足：$dep_en_label（$DEP_VERSION）"
            continue
        fi

        dep_warn "应用「$dep_en_app」需要 $dep_en_label，当前状态：$DEP_STATE。"
        case "${LINUXAPP_APP_AUTO_DEPS:-}" in
            1)
                dep_info "已按 LINUXAPP_APP_AUTO_DEPS=1 自动安装依赖语言：$dep_en_label"
                ;;
            0)
                dep_fail "已按 LINUXAPP_APP_AUTO_DEPS=0 跳过依赖安装。请先在「应用管理 → 语言模块」中安装 $dep_en_label 后重试。"
                return 1
                ;;
            *)
                if ! dep_confirm "是否现在安装 $dep_en_label？" y; then
                    dep_fail "缺少依赖语言 $dep_en_label，已中止本次操作。可在「应用管理 → 语言模块」中安装后重试。"
                    return 1
                fi
                ;;
        esac

        # 语言模块自己负责源选择、版本选择与交互提示，这里只负责调用与结果校验。
        if ! sh "$dep_en_script" install; then
            dep_fail "$dep_en_label 安装失败，已中止本次操作。"
            return 1
        fi
        dependency_language_state "$dep_en_script"
        if [ "$DEP_STATE" != '已安装' ]; then
            dep_fail "$dep_en_label 安装后状态仍为「$DEP_STATE」，已中止本次操作。"
            return 1
        fi
        dep_out "[完成] 依赖语言环境已就绪：$dep_en_label（$DEP_VERSION）"
    done
    return 0
}

# Last updated: 2026-09-12 09:34
