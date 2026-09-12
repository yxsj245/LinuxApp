#!/bin/sh

LOADED_MODULE_PATH=''

# 解析模块脚本路径。全部脚本在入口同步阶段就已落地本地副本，运行期只读本地文件、不再联网，
# 因此这里只做路径解析与存在性检查。
# $1 相对 config/modules.list 的脚本路径，或脚本绝对路径。成功时把实际路径写入 LOADED_MODULE_PATH。
loader_ensure_script() {
    loader_relative=$1
    LOADED_MODULE_PATH=''

    # 已经是绝对路径（例如调用方传入的本地脚本）时直接使用，不能再与本地目录拼接，
    # 否则会得到一个必然不存在的路径。
    case "$loader_relative" in
        /*)
            if [ -f "$loader_relative" ]; then
                # shellcheck disable=SC2034
                LOADED_MODULE_PATH=$loader_relative
                return 0
            fi
            ui_error "模块脚本不存在：$loader_relative"
            ui_warn '请重新执行 ./main.sh --update 拉取全部脚本。'
            return 1
            ;;
    esac

    loader_local="$LINUXAPP_ROOT/$loader_relative"
    if [ -f "$loader_local" ]; then
        # shellcheck disable=SC2034
        LOADED_MODULE_PATH=$loader_local
        return 0
    fi
    ui_error "模块脚本不存在：$loader_relative（实际检查路径：$loader_local）"
    ui_warn '请重新执行 ./main.sh --update 拉取全部脚本。'
    return 1
}

# 进入菜单前校验本地脚本完整性：框架清单与模块清单里登记的脚本都必须已经在本地。
# 任一脚本缺失时返回非 0，由入口中止启动，避免进入菜单后才出现「脚本不可用」。
loader_validate_local() {
    lvl_missing=0
    lvl_manifest="$LINUXAPP_ROOT/config/bootstrap.list"
    if [ -f "$lvl_manifest" ]; then
        while IFS= read -r lvl_rel || [ -n "$lvl_rel" ]; do
            case "$lvl_rel" in
                ''|'#'*) continue ;;
            esac
            if [ ! -f "$LINUXAPP_ROOT/$lvl_rel" ]; then
                ui_error "缺少框架脚本：$lvl_rel"
                lvl_missing=1
            fi
        done < "$lvl_manifest"
    else
        ui_error '缺少框架清单：config/bootstrap.list'
        lvl_missing=1
    fi

    if [ -f "$LINUXAPP_ROOT/config/modules.list" ]; then
        while IFS='|' read -r lvl_type _ lvl_path _ || [ -n "$lvl_path" ]; do
            case "$lvl_type" in
                ''|'#'*) continue ;;
            esac
            [ -n "$lvl_path" ] || continue
            if [ ! -f "$LINUXAPP_ROOT/$lvl_path" ]; then
                ui_error "缺少模块脚本：$lvl_path"
                lvl_missing=1
            fi
        done < "$LINUXAPP_ROOT/config/modules.list"
    else
        ui_error '缺少模块清单：config/modules.list'
        lvl_missing=1
    fi

    if [ "$lvl_missing" -eq 1 ]; then
        ui_warn '本地脚本不完整，请重新执行 ./main.sh --update 拉取全部脚本。'
    fi
    return "$lvl_missing"
}

# Last updated: 2026-09-12 09:34
