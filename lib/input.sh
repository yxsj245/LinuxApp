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
    # shellcheck disable=SC2034
    READ_KEY=''
    read_status=0
    while [ -z "$READ_KEY" ]; do
        # 过滤伪终端可能产生的 NUL 填充字节，避免 Bash 命令替换告警。
        READ_KEY=$(dd if="$INPUT_TTY" bs=1 count=1 2>/dev/null | tr -d '\000')
        read_status=$?
        [ "$read_status" -eq 0 ] || break
    done
    input_restore_terminal
    return "$read_status"
}

# Last updated: 2026-09-11 19:00
