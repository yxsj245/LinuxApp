#!/bin/sh

INPUT_TTY=/dev/tty
INPUT_STTY_STATE=''
READ_KEY=''

input_is_interactive() {
    [ -r "$INPUT_TTY" ] && [ -w "$INPUT_TTY" ] && [ -t 1 ]
}

input_save_terminal() {
    if [ -z "$INPUT_STTY_STATE" ] && input_is_interactive; then
        INPUT_STTY_STATE=$(stty -g < "$INPUT_TTY" 2>/dev/null) || INPUT_STTY_STATE=''
    fi
}

input_restore_terminal() {
    if [ -n "$INPUT_STTY_STATE" ] && input_is_interactive; then
        stty "$INPUT_STTY_STATE" < "$INPUT_TTY" 2>/dev/null || true
        INPUT_STTY_STATE=''
    fi
}

read_key() {
    if ! input_is_interactive; then
        return 1
    fi

    input_save_terminal
    if ! stty -icanon min 1 time 0 -echo < "$INPUT_TTY" 2>/dev/null; then
        input_restore_terminal
        return 1
    fi

    # POSIX sh 的 read 在部分实现中仍会等待换行，因此使用 dd 精确读取一个字节。
    # 注意：命令替换会剥离结果末尾的换行，若直接赋值，用户按下的回车会被吞成空串，
    # 表现为停在「按任意键继续」上按回车毫无反应；因此在末尾追加哨兵字符 x，
    # 赋值后再用 ${var%x} 去掉，保证回车、空格等任意按键都能被识别。
    READ_KEY=''
    READ_GUARD=0
    while [ -z "$READ_KEY" ] && [ "$READ_GUARD" -lt 16 ]; do
        READ_GUARD=$((READ_GUARD + 1))
        # 过滤伪终端可能产生的 NUL 填充字节，避免 Bash 命令替换告警。
        READ_KEY=$( { dd if="$INPUT_TTY" bs=1 count=1 2>/dev/null | tr -d '\000'; printf 'x'; } )
        READ_KEY=${READ_KEY%x}
    done
    input_restore_terminal
    [ -n "$READ_KEY" ]
}

# 判断按键是否为「没有实际选择」的空白键（回车、空格、Tab 等）。
# 菜单中这类按键只当作刷新当前界面，不再提示「无效选择」，避免用户按回车时以为程序卡住。
input_key_is_blank() {
    [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]
}

# Last updated: 2026-09-12 04:47
