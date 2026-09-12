#!/bin/sh
# shellcheck disable=SC2034

# Java 语言模块（Eclipse Temurin JDK）。
# 支持安装、切换版本、更新、修复环境、卸载与状态查询；安装源可选国内镜像或官方源。
# 动作：capabilities、versions、status、install、switch [版本]、update、repair、uninstall
# 卸载支持选择已安装的版本，输入 a 表示卸载全部版本。

LANG_KEY=java
LANG_TITLE='Java'

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

# ---------------------------------------------------------------- 版本元数据

# API 使用的架构目录名：x64 或 aarch64。
java_api_arch() {
    case "$(lang_arch_kind)" in
        x64) printf '%s\n' 'x64' ;;
        arm64) printf '%s\n' 'aarch64' ;;
        *) return 1 ;;
    esac
}

# 按版本号从新到旧排序“版本|文件名|sha256|官方地址”记录。
java_sort_records() {
    awk -F'|' '{
        n = split($1, p, ".");
        value = 0;
        for (i = 1; i <= 4; i++) {
            v = (i <= n) ? p[i] + 0 : 0;
            value = value * 1000 + v;
        }
        printf "%015d\t%s\n", value, $0;
    }' | sort -rn | cut -f2-
}

# 解析 Adoptium feature_releases 响应，输出发布记录。
java_parse_releases() {
    awk '
        /"package"[[:space:]]*:[[:space:]]*\{/ { in_pkg = 1; pkg_name = ""; pkg_sum = ""; pkg_link = ""; next }
        in_pkg && /^[[:space:]]*\}[,]?[[:space:]]*$/ { in_pkg = 0; next }
        in_pkg {
            line = $0
            if (line ~ /"name"[[:space:]]*:/) {
                sub(/.*"name"[[:space:]]*:[[:space:]]*"/, "", line)
                sub(/".*/, "", line)
                pkg_name = line
            } else if (line ~ /"checksum"[[:space:]]*:/) {
                sub(/.*"checksum"[[:space:]]*:[[:space:]]*"/, "", line)
                sub(/".*/, "", line)
                pkg_sum = line
            } else if (line ~ /"link"[[:space:]]*:/) {
                sub(/.*"link"[[:space:]]*:[[:space:]]*"/, "", line)
                sub(/".*/, "", line)
                pkg_link = line
            }
            next
        }
        /"openjdk_version"[[:space:]]*:/ {
            line = $0
            sub(/.*"openjdk_version"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/".*/, "", line)
            ver = line
            sub(/\+.*$/, "", ver)
            if (pkg_name != "" && ver != "") {
                printf "%s|%s|%s|%s\n", ver, pkg_name, pkg_sum, pkg_link
            }
            pkg_name = ""; pkg_sum = ""; pkg_link = ""
        }
    ' "$1" | java_sort_records
}

# 取 LTS 大版本列表，每行一个，写入标准输出。
java_fetch_lts_majors() {
    java_flm_file=$1
    if ! lang_cache_fetch 'adoptium-releases.json' \
        "$LINUXAPP_LANG_ADOPTIUM_API/v3/info/available_releases" > "$java_flm_file"; then
        return 1
    fi
    java_flm_list=$(awk '
        /"available_lts_releases"/ { inside = 1; next }
        inside && /\]/ { exit }
        inside { gsub(/[^0-9]/, ""); if (length($0) > 0) print }
    ' "$java_flm_file" | sort -n)
    if [ -z "$java_flm_list" ]; then
        # 兼容紧凑格式的 JSON 输出。
        java_flm_list=$(tr -d ' \n' < "$java_flm_file" \
            | sed -n 's/.*"available_lts_releases":\[\([^]]*\)\].*/\1/p' \
            | tr ',' '\n' | grep -v '^$' | sort -n)
    fi
    [ -n "$java_flm_list" ] || return 1
    printf '%s\n' "$java_flm_list"
    return 0
}

# 取某个大版本的 GA 发布记录，写入标准输出；元数据缓存到 $2。
java_fetch_releases() {
    java_fr_major=$1
    java_fr_file=$2
    java_fr_arch=$3
    if ! lang_cache_fetch "adoptium-java-${java_fr_major}-${java_fr_arch}.json" \
        "$LINUXAPP_LANG_ADOPTIUM_API/v3/assets/feature_releases/${java_fr_major}/ga?os=linux&architecture=${java_fr_arch}&image_type=jdk&page_size=50" \
        > "$java_fr_file"; then
        return 1
    fi
    java_parse_releases "$java_fr_file"
}

# 从记录列表取指定版本记录，写入标准输出。
java_pick_record() {
    printf '%s\n' "$1" | awk -F'|' -v v="$2" '$1 == v { print; exit }'
}

# 本地缓存中的可升级提示，不联网。
java_upgrade_hint() {
    java_uh_current=$1
    java_uh_major=${java_uh_current%%.*}
    java_uh_target=''
    java_uh_arch=$(java_api_arch 2>/dev/null) || return 0
    java_uh_file=$(lang_default_root)/cache/adoptium-java-${java_uh_major}-${java_uh_arch}.json
    [ -s "$java_uh_file" ] || return 0
    java_uh_target=$(java_parse_releases "$java_uh_file" | sed -n '1p' | cut -d'|' -f1)
    [ -n "$java_uh_target" ] || return 0
    if lang_version_gt "$java_uh_target" "$java_uh_current"; then
        printf '；本地缓存显示可升级到 %s（运行「更新」）' "$java_uh_target"
    fi
    return 0
}

# ---------------------------------------------------------------- 选择与安装

# 选择要安装的大版本，结果写入 LANG_MAJOR；$1 为 LTS 大版本列表。
java_choose_major() {
    java_cm_majors=$1
    if [ -n "${LINUXAPP_LANG_VERSION:-}" ]; then
        LANG_MAJOR=${LINUXAPP_LANG_VERSION%%.*}
        case "$LANG_MAJOR" in
            ''|*[!0-9]*)
                lang_fail "环境变量 LINUXAPP_LANG_VERSION 取值无效：$LINUXAPP_LANG_VERSION"
                return 1
                ;;
        esac
        if ! printf '%s\n' "$java_cm_majors" | grep -qx "$LANG_MAJOR"; then
            lang_fail "大版本 $LANG_MAJOR 不在可用 LTS 列表中：$(printf '%s' "$java_cm_majors" | tr '\n' ' ')"
            return 1
        fi
        return 0
    fi
    if ! lang_has_tty; then
        lang_fail '当前不是交互式终端，请通过 LINUXAPP_LANG_VERSION=<大版本号> 指定要安装的 JDK 版本。'
        return 1
    fi
    java_cm_current=$(lang_current_version java 2>/dev/null || true)
    lang_out '可安装的 JDK LTS 大版本：'
    java_cm_index=0
    for java_cm_major in $(printf '%s\n' "$java_cm_majors" | sort -rn); do
        java_cm_index=$((java_cm_index + 1))
        java_cm_mark=''
        if [ -n "$java_cm_current" ]; then
            case "$java_cm_current" in
                "$java_cm_major".*) java_cm_mark='（当前）' ;;
            esac
        fi
        lang_out "  $java_cm_index. JDK $java_cm_major$java_cm_mark"
    done
    java_cm_index=$((java_cm_index + 1))
    lang_out "  $java_cm_index. 手动输入其它大版本"
    lang_choose_number '请输入编号' "$java_cm_index" || return 1
    if [ "$LANG_CHOICE" -eq "$java_cm_index" ]; then
        lang_read_value '请输入 JDK 大版本号（例如 17）：' || return 1
        case "$LANG_REPLY" in
            ''|*[!0-9]*) lang_fail '大版本号必须是数字。'; return 1 ;;
        esac
        LANG_MAJOR=$LANG_REPLY
        return 0
    fi
    LANG_MAJOR=$(printf '%s\n' "$java_cm_majors" | sort -rn | sed -n "${LANG_CHOICE}p")
    return 0
}

# 选择要安装的具体版本，结果写入 LANG_VERSION_RECORD；$1 为发布记录列表。
java_choose_version() {
    java_cvv_records=$1
    java_cvv_wanted=${LINUXAPP_LANG_VERSION:-}
    case "$java_cvv_wanted" in
        *.*)
            java_cvv_record=$(java_pick_record "$java_cvv_records" "$java_cvv_wanted")
            if [ -z "$java_cvv_record" ]; then
                lang_fail "在 JDK $LANG_MAJOR 中找不到版本 $java_cvv_wanted。"
                lang_out "可选版本：$(printf '%s\n' "$java_cvv_records" | cut -d'|' -f1 | sed -n '1,10p' | tr '\n' ' ')"
                return 1
            fi
            LANG_VERSION_RECORD=$java_cvv_record
            return 0
            ;;
    esac
    if [ -n "$java_cvv_wanted" ]; then
        LANG_VERSION_RECORD=$(printf '%s\n' "$java_cvv_records" | sed -n '1p')
        return 0
    fi
    if ! lang_has_tty; then
        lang_fail '当前不是交互式终端，请通过 LINUXAPP_LANG_VERSION=<版本号> 指定要安装的 JDK 版本。'
        return 1
    fi
    java_cvv_count=$(printf '%s\n' "$java_cvv_records" | grep -c .)
    java_cvv_show=$java_cvv_count
    [ "$java_cvv_show" -gt 5 ] && java_cvv_show=5
    lang_out "JDK $LANG_MAJOR 可安装的补丁版本（从新到旧）："
    java_cvv_index=0
    while [ "$java_cvv_index" -lt "$java_cvv_show" ]; do
        java_cvv_index=$((java_cvv_index + 1))
        java_cvv_line=$(printf '%s\n' "$java_cvv_records" | sed -n "${java_cvv_index}p" | cut -d'|' -f1)
        java_cvv_mark=''
        if lang_version_installed java "$java_cvv_line"; then
            java_cvv_mark='（已安装）'
        fi
        lang_out "  $java_cvv_index. $java_cvv_line$java_cvv_mark"
    done
    if [ "$java_cvv_count" -gt 5 ]; then
        lang_out "  （另有 $((java_cvv_count - 5)) 个较旧版本，可选手动输入）"
    fi
    java_cvv_manual=$((java_cvv_show + 1))
    lang_out "  $java_cvv_manual. 手动输入版本号"
    lang_choose_number '请输入编号' "$java_cvv_manual" || return 1
    if [ "$LANG_CHOICE" -eq "$java_cvv_manual" ]; then
        lang_read_value '请输入完整版本号（例如 17.0.18）：' || return 1
        java_cvv_record=$(java_pick_record "$java_cvv_records" "$LANG_REPLY")
        if [ -z "$java_cvv_record" ]; then
            lang_fail "找不到版本：$LANG_REPLY"
            return 1
        fi
        LANG_VERSION_RECORD=$java_cvv_record
        return 0
    fi
    LANG_VERSION_RECORD=$(printf '%s\n' "$java_cvv_records" | sed -n "${LANG_CHOICE}p")
    return 0
}

# 下载并解包安装指定记录：$1 记录，$2 大版本，$3 源，$4 API 架构。
# 成功后把版本号写入 LANG_INSTALLED_VERSION。
java_install_record() {
    java_ir_version=$(printf '%s' "$1" | cut -d'|' -f1)
    java_ir_name=$(printf '%s' "$1" | cut -d'|' -f2)
    java_ir_sum=$(printf '%s' "$1" | cut -d'|' -f3)
    java_ir_link=$(printf '%s' "$1" | cut -d'|' -f4)
    java_ir_major=$2
    java_ir_arch=$4
    java_ir_mirror="$LINUXAPP_LANG_JAVA_MIRROR/$java_ir_major/jdk/$java_ir_arch/linux/$java_ir_name"
    case "$3" in
        mirror)
            java_ir_primary=$java_ir_mirror
            java_ir_secondary=$java_ir_link
            ;;
        *)
            java_ir_primary=$java_ir_link
            java_ir_secondary=$java_ir_mirror
            ;;
    esac
    java_ir_home=$(lang_home java)
    if [ -d "$java_ir_home/$java_ir_version" ]; then
        lang_info "JDK $java_ir_version 已经安装，跳过下载。"
        LANG_INSTALLED_VERSION=$java_ir_version
        return 0
    fi
    if [ -z "$java_ir_sum" ]; then
        lang_fail '没有取到官方校验值，出于安全考虑已中止安装。'
        return 1
    fi
    mkdir -p "$LINUXAPP_LANG_STAGING" 2>/dev/null || {
        lang_fail "无法创建临时目录：$LINUXAPP_LANG_STAGING"
        return 1
    }
    java_ir_archive=$LINUXAPP_LANG_STAGING/$java_ir_name
    if ! lang_download "$java_ir_primary" "$java_ir_archive"; then
        lang_warn '首选源下载失败，改用备用源重试。'
        if ! lang_download "$java_ir_secondary" "$java_ir_archive"; then
            lang_fail '国内镜像与官方源都无法下载，请检查网络后重试。'
            return 1
        fi
    fi
    if ! lang_verify_sha256 "$java_ir_archive" "$java_ir_sum"; then
        rm -f "$java_ir_archive" 2>/dev/null || true
        return 1
    fi
    if ! lang_check_archive "$java_ir_archive"; then
        rm -f "$java_ir_archive" 2>/dev/null || true
        return 1
    fi
    java_ir_extract=$LINUXAPP_LANG_STAGING/extract
    rm -rf "$java_ir_extract" 2>/dev/null || true
    lang_info "正在解压 JDK $java_ir_version..."
    if ! lang_extract "$java_ir_archive" "$java_ir_extract" 1; then
        lang_fail '解压失败，安装已中止。'
        return 1
    fi
    if [ ! -f "$java_ir_extract/bin/java" ]; then
        lang_fail '解压结果缺少 bin/java，安装已中止。'
        return 1
    fi
    mkdir -p "$java_ir_home" 2>/dev/null || {
        lang_fail "无法创建安装目录：$java_ir_home"
        return 1
    }
    if ! mv "$java_ir_extract" "$java_ir_home/$java_ir_version" 2>/dev/null; then
        lang_fail "无法安装到 $java_ir_home/$java_ir_version"
        return 1
    fi
    rm -f "$java_ir_archive" 2>/dev/null || true
    lang_ok "JDK $java_ir_version 已解压到 $java_ir_home/$java_ir_version"
    LANG_INSTALLED_VERSION=$java_ir_version
    return 0
}

# 激活版本：$1 版本，$2 询问默认值。
java_activate() {
    java_ac_version=$1
    java_ac_default=${2:-y}
    java_ac_current=$(lang_current_version java 2>/dev/null || true)
    if [ "$java_ac_current" = "$java_ac_version" ]; then
        lang_info "当前已经是 JDK $java_ac_version。"
        return 0
    fi
    if [ -n "$java_ac_current" ]; then
        if ! lang_confirm "是否把当前版本从 $java_ac_current 切换为 $java_ac_version？" "$java_ac_default"; then
            lang_info "JDK $java_ac_version 已安装，当前版本仍为 $java_ac_current，稍后可执行「切换版本」。"
            return 0
        fi
    fi
    lang_link_current java "$java_ac_version" || return 1
    lang_ok "当前 Java 版本已设置为 $java_ac_version。"
    return 0
}

# 执行 java -version 验证安装结果。
java_report_version() {
    java_rv_bin=$(lang_home java)/$1/bin/java
    if [ -x "$java_rv_bin" ]; then
        java_rv_output=$("$java_rv_bin" -version 2>&1 | sed -n '1p')
        lang_ok "验证结果：$java_rv_output"
    else
        lang_warn "未找到可执行文件：$java_rv_bin"
    fi
    return 0
}

# ---------------------------------------------------------------- 动作实现

java_install() {
    lang_require_commands tar || return 1
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        lang_fail '系统中找不到 curl 或 wget，无法下载 JDK。请先安装 curl 或 wget。'
        return 1
    fi
    java_in_arch=$(java_api_arch) || {
        lang_fail '当前 CPU 架构不受支持，仅支持 x86_64 与 aarch64。'
        return 1
    }
    java_in_root=$(lang_default_root)
    mkdir -p "$java_in_root/java" 2>/dev/null || {
        lang_fail "无法创建安装目录：$java_in_root/java"
        return 1
    }
    LINUXAPP_LANG_STAGING=$java_in_root/java/.staging.$$
    rm -rf "$LINUXAPP_LANG_STAGING" 2>/dev/null || true
    mkdir -p "$LINUXAPP_LANG_STAGING" 2>/dev/null || {
        lang_fail "无法创建临时目录：$LINUXAPP_LANG_STAGING"
        return 1
    }

    lang_info '正在获取 JDK 版本信息...'
    java_in_majors=$(java_fetch_lts_majors "$LINUXAPP_LANG_STAGING/releases.json") || {
        lang_fail '无法获取 JDK 版本列表，请检查网络连接后重试。'
        return 1
    }
    java_choose_major "$java_in_majors" || return 1
    java_in_records=$(java_fetch_releases "$LANG_MAJOR" \
        "$LINUXAPP_LANG_STAGING/releases-$LANG_MAJOR.json" "$java_in_arch") || {
        lang_fail "无法获取 JDK $LANG_MAJOR 的版本列表，请检查网络连接后重试。"
        return 1
    }
    [ -n "$java_in_records" ] || {
        lang_fail "没有找到 JDK $LANG_MAJOR 的可用发布版本。"
        return 1
    }
    java_choose_version "$java_in_records" || return 1

    java_in_version=$(printf '%s' "$LANG_VERSION_RECORD" | cut -d'|' -f1)
    java_in_name=$(printf '%s' "$LANG_VERSION_RECORD" | cut -d'|' -f2)
    java_in_source=${LINUXAPP_LANG_SOURCE:-}
    if ! lang_version_installed java "$java_in_version"; then
        lang_source_choose || return 1
        java_in_source=$LANG_SOURCE
        lang_out "准备安装：JDK $java_in_version"
        if [ "$java_in_source" = mirror ]; then
            lang_out "安装源：国内镜像（$LINUXAPP_LANG_JAVA_MIRROR）"
        else
            lang_out "安装源：官方源（Adoptium GitHub 发布页）"
        fi
        lang_out "文件：$java_in_name"
        lang_confirm '确认开始安装吗？' y || {
            lang_info '已取消安装。'
            return 0
        }
    else
        lang_info "JDK $java_in_version 已经安装。"
    fi

    java_install_record "$LANG_VERSION_RECORD" "$LANG_MAJOR" "$java_in_source" "$java_in_arch" || return 1
    java_activate "$LANG_INSTALLED_VERSION" y || return 1
    if ! lang_env_sync; then
        lang_fail '环境变量注入失败。'
        return 1
    fi
    lang_env_hint
    java_report_version "$LANG_INSTALLED_VERSION"
    return 0
}

java_switch() {
    java_sw_wanted=${1:-${LINUXAPP_LANG_VERSION:-}}
    java_sw_versions=$(lang_list_versions java)
    if [ -z "$java_sw_versions" ]; then
        lang_warn '尚未安装任何 JDK 版本，请先执行「安装」。'
        return 1
    fi
    java_sw_current=$(lang_current_version java 2>/dev/null || true)
    if [ -n "$java_sw_wanted" ]; then
        if ! printf '%s\n' "$java_sw_versions" | grep -qx "$java_sw_wanted"; then
            lang_fail "版本 $java_sw_wanted 尚未安装。已安装：$(printf '%s' "$java_sw_versions" | tr '\n' ' ')"
            return 1
        fi
        java_sw_target=$java_sw_wanted
    else
        if ! lang_has_tty; then
            lang_fail '当前不是交互式终端，请使用：module.sh switch <版本>'
            return 1
        fi
        lang_out '已安装的 JDK 版本：'
        java_sw_index=0
        for java_sw_version in $java_sw_versions; do
            java_sw_index=$((java_sw_index + 1))
            java_sw_mark=''
            if [ "$java_sw_version" = "$java_sw_current" ]; then
                java_sw_mark='（当前）'
            fi
            lang_out "  $java_sw_index. $java_sw_version$java_sw_mark"
        done
        java_sw_more=$((java_sw_index + 1))
        lang_out "  $java_sw_more. 安装或升级到其它版本（等同于「更新」）"
        lang_choose_number '请输入编号' "$java_sw_more" || return 1
        if [ "$LANG_CHOICE" -eq "$java_sw_more" ]; then
            java_update
            return $?
        fi
        java_sw_target=$(printf '%s\n' "$java_sw_versions" | sed -n "${LANG_CHOICE}p")
    fi
    if [ "$java_sw_target" = "$java_sw_current" ]; then
        lang_info "当前已经是 JDK $java_sw_target，无需切换。"
        return 0
    fi
    lang_link_current java "$java_sw_target" || return 1
    lang_env_sync >/dev/null 2>&1 || true
    lang_ok "已切换：JDK $java_sw_current -> $java_sw_target"
    lang_env_hint
    java_report_version "$java_sw_target"
    return 0
}

java_update() {
    lang_require_commands tar || return 1
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        lang_fail '系统中找不到 curl 或 wget，无法下载 JDK。请先安装 curl 或 wget。'
        return 1
    fi
    java_up_current=$(lang_current_version java 2>/dev/null || true)
    if [ -z "$java_up_current" ]; then
        lang_warn '当前没有激活的 JDK 版本，请先执行「安装」。'
        return 1
    fi
    java_up_arch=$(java_api_arch) || {
        lang_fail '当前 CPU 架构不受支持，仅支持 x86_64 与 aarch64。'
        return 1
    }
    java_up_major=${java_up_current%%.*}
    java_up_mode=${LINUXAPP_LANG_UPDATE:-patch}
    case "$java_up_mode" in
        patch|major|latest) ;;
        *)
            lang_fail "环境变量 LINUXAPP_LANG_UPDATE 取值无效：$java_up_mode（应为 patch、major 或 latest）。"
            return 1
            ;;
    esac
    java_up_root=$(lang_default_root)
    mkdir -p "$java_up_root/java" 2>/dev/null || return 1
    LINUXAPP_LANG_STAGING=$java_up_root/java/.staging.$$
    rm -rf "$LINUXAPP_LANG_STAGING" 2>/dev/null || true
    mkdir -p "$LINUXAPP_LANG_STAGING" 2>/dev/null || {
        lang_fail "无法创建临时目录：$LINUXAPP_LANG_STAGING"
        return 1
    }

    lang_info "正在检查 JDK $java_up_major 的最新补丁版本（当前 $java_up_current）..."
    java_up_records=$(java_fetch_releases "$java_up_major" \
        "$LINUXAPP_LANG_STAGING/releases-$java_up_major.json" "$java_up_arch") || {
        lang_fail '无法获取版本信息，请检查网络连接后重试。'
        return 1
    }
    java_up_record=$(printf '%s\n' "$java_up_records" | sed -n '1p')
    java_up_latest=$(printf '%s' "$java_up_record" | cut -d'|' -f1)
    java_up_record_major=$java_up_major

    # major 模式明确要求跨大版本，忽略当前大版本的补丁更新。
    if [ "$java_up_mode" = major ]; then
        java_up_record=''
    fi
    if [ -n "$java_up_record" ] && ! lang_version_gt "$java_up_latest" "$java_up_current"; then
        lang_info "JDK $java_up_major 的补丁版本已是最新（$java_up_current）。"
        java_up_record=''
    fi

    if [ -z "$java_up_record" ]; then
        # 需要跨大版本：major 模式取比当前更新的最近 LTS，latest 模式取最新 LTS。
        java_up_majors=$(java_fetch_lts_majors "$LINUXAPP_LANG_STAGING/releases.json") || java_up_majors=''
        if [ -z "$java_up_majors" ]; then
            lang_warn '无法获取 LTS 大版本列表，未做更新。'
            return 1
        fi
        case "$java_up_mode" in
            latest)
                java_up_target_major=$(printf '%s\n' "$java_up_majors" | sort -rn | sed -n '1p')
                ;;
            *)
                java_up_target_major=$(printf '%s\n' "$java_up_majors" | lang_next_major "$java_up_major")
                ;;
        esac
        if [ -z "$java_up_target_major" ] || [ "$java_up_target_major" = "$java_up_major" ]; then
            lang_ok '当前已是最新版本，无需更新。'
            return 0
        fi
        if [ "$java_up_mode" = patch ]; then
            if [ "${LINUXAPP_LANG_YES:-0}" = 1 ]; then
                lang_info '非交互模式默认不做大版本升级；如需升级请设置 LINUXAPP_LANG_UPDATE=major 或 latest。'
                return 0
            fi
            if ! lang_confirm "补丁已是最新；是否升级到更新的 LTS 大版本 JDK $java_up_target_major？" n; then
                lang_ok '当前补丁已是最新，未做大版本升级。'
                return 0
            fi
        fi
        lang_info "正在获取 JDK $java_up_target_major 的版本信息..."
        java_up_records=$(java_fetch_releases "$java_up_target_major" \
            "$LINUXAPP_LANG_STAGING/releases-$java_up_target_major.json" "$java_up_arch") || {
            lang_fail "无法获取 JDK $java_up_target_major 的版本列表。"
            return 1
        }
        java_up_record=$(printf '%s\n' "$java_up_records" | sed -n '1p')
        java_up_latest=$(printf '%s' "$java_up_record" | cut -d'|' -f1)
        java_up_record_major=$java_up_target_major
        if [ -z "$java_up_latest" ]; then
            lang_fail "没有找到 JDK $java_up_target_major 的可用发布版本。"
            return 1
        fi
    fi

    lang_out "检测到新版本：JDK $java_up_latest（当前 $java_up_current）"
    lang_source_choose || return 1
    java_up_source=$LANG_SOURCE
    lang_confirm "是否升级到 JDK $java_up_latest？" y || {
        lang_info '已取消更新。'
        return 0
    }
    java_install_record "$java_up_record" "$java_up_record_major" "$java_up_source" "$java_up_arch" || return 1
    java_activate "$LANG_INSTALLED_VERSION" y || return 1
    if ! lang_env_sync; then
        lang_fail '环境变量注入失败。'
        return 1
    fi
    lang_ok "升级完成：JDK $java_up_current -> $LANG_INSTALLED_VERSION"
    lang_out "旧版本 $java_up_current 仍然保留，可用「切换版本」随时回退。"
    lang_env_hint
    java_report_version "$LANG_INSTALLED_VERSION"
    return 0
}

# 卸载：可选择卸载某个已安装版本，输入 a 表示卸载全部版本。
java_uninstall() {
    java_un_home=$(lang_home java)
    java_un_versions=$(lang_list_versions java)
    java_un_current=$(lang_current_version java 2>/dev/null || true)
    if [ -z "$java_un_versions" ] && [ ! -d "$java_un_home" ]; then
        lang_info 'Java 环境尚未安装，无需卸载。'
        return 0
    fi

    java_un_scope=all
    java_un_target=''
    if [ -n "$java_un_versions" ]; then
        lang_uninstall_choose 'JDK 版本' "$java_un_versions" "$java_un_current" || {
            lang_info '已取消卸载。'
            return 0
        }
        java_un_scope=$LANG_UNINSTALL_SCOPE
        java_un_target=$LANG_UNINSTALL_VERSION
    fi

    if [ "$java_un_scope" = one ]; then
        java_un_rest=$(printf '%s\n' "$java_un_versions" | grep -vxF "$java_un_target")
        lang_out "将删除版本目录：$java_un_home/$java_un_target"
        if [ "$java_un_target" = "$java_un_current" ]; then
            lang_warn '该版本当前正在使用。'
        fi
        if [ -z "$java_un_rest" ]; then
            lang_out "这是最后一个 JDK 版本，卸载后将一并清理安装目录：$java_un_home"
        fi
        lang_confirm "确认卸载 JDK $java_un_target 吗？" n || {
            lang_info '已取消卸载。'
            return 0
        }
        lang_remove_versions java "$java_un_target" || {
            lang_fail "删除失败：$java_un_home/$java_un_target（请检查权限）"
            return 1
        }
        if [ -n "$java_un_rest" ]; then
            lang_ok "JDK $java_un_target 已卸载。"
            if ! lang_reactivate_latest java; then
                lang_warn '剩余版本重新激活失败，请执行「切换版本」手工选择。'
                lang_env_sync >/dev/null 2>&1 || true
                return 1
            fi
            if [ "$java_un_target" = "$java_un_current" ]; then
                lang_out "当前 Java 版本已切换为 $LANG_ACTIVATED_VERSION。"
            fi
            lang_env_sync >/dev/null 2>&1 || true
            lang_env_hint
            return 0
        fi
        if ! rm -rf "$java_un_home" 2>/dev/null; then
            lang_fail "删除失败：$java_un_home（请检查权限）"
            return 1
        fi
        lang_env_sync >/dev/null 2>&1 || true
        lang_ok 'JDK 已全部卸载，安装目录已清理。'
        lang_env_hint
        return 0
    fi

    lang_out "将删除 Java 安装目录：$java_un_home"
    if [ -n "$java_un_versions" ]; then
        lang_out "包含版本：$(printf '%s' "$java_un_versions" | tr '\n' ',' | sed -e 's/,$//' -e 's/,/、/g')"
    fi
    lang_confirm '确认卸载 Java 环境吗？' n || {
        lang_info '已取消卸载。'
        return 0
    }
    if ! rm -rf "$java_un_home" 2>/dev/null; then
        lang_fail "删除失败：$java_un_home（请检查权限）"
        return 1
    fi
    lang_env_sync >/dev/null 2>&1 || true
    lang_ok 'Java 环境已卸载。'
    lang_env_hint
    return 0
}

java_status() {
    java_st_root=$(lang_default_root)
    java_st_current=$(lang_current_version java 2>/dev/null || true)
    java_st_versions=$(lang_list_versions java)
    if [ -z "$java_st_current" ]; then
        if [ -z "$java_st_versions" ]; then
            printf '未安装|-|尚未安装 Java 环境，安装时可选择国内镜像或官方源\n'
            return 0
        fi
        printf '未安装|-|安装根 %s 已有解包目录但未激活，请执行「切换版本」\n' "$java_st_root"
        return 0
    fi
    java_st_count=$(printf '%s\n' "$java_st_versions" | grep -c .)
    java_st_list=$(printf '%s' "$java_st_versions" | tr '\n' ',' | sed -e 's/,$//' -e 's/,/、/g')
    java_st_hint=$(java_upgrade_hint "$java_st_current")
    printf '已安装|%s|安装根 %s，共 %s 个版本：%s%s\n' \
        "$java_st_current" "$java_st_root" "$java_st_count" "$java_st_list" "$java_st_hint"
    return 0
}

java_versions() {
    java_vs_current=$(lang_current_version java 2>/dev/null || true)
    lang_list_versions java | while IFS= read -r java_vs_version; do
        [ -n "$java_vs_version" ] || continue
        if [ "$java_vs_version" = "$java_vs_current" ]; then
            printf '%s|current\n' "$java_vs_version"
        else
            printf '%s|installed\n' "$java_vs_version"
        fi
    done
    return 0
}

# ---------------------------------------------------------------- 动作分发

java_main() {
    java_action=${1:-status}
    case "$java_action" in
        capabilities) printf '%s\n' 'versions switch update repair' ;;
        versions) java_versions ;;
        status) java_status ;;
        install) java_install ;;
        switch)
            java_dispatch_arg=''
            if [ "$#" -gt 1 ]; then
                shift
                java_dispatch_arg=$1
            fi
            java_switch "$java_dispatch_arg"
            ;;
        update) java_update ;;
        repair) lang_env_repair ;;
        uninstall) java_uninstall ;;
        start|stop)
            lang_fail '语言模块不支持启动和停止。'
            return 2
            ;;
        *)
            lang_fail "未知的语言动作：$java_action"
            return 2
            ;;
    esac
}

trap 'lang_cleanup; lang_out ""; lang_warn "Java 操作已被 Ctrl+C 中断，临时文件已清理。"; exit 130' INT
trap 'lang_cleanup' TERM HUP

java_main "$@"
java_exit_code=$?
lang_cleanup
exit "$java_exit_code"

# Last updated: 2026-09-12 05:19
