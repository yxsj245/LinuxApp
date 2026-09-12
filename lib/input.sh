#!/bin/sh

INPUT_TTY=/dev/tty
INPUT_STTY_STATE=''
READ_KEY=''
READ_LINE=''

# 普通输入模式需要识别的控制字符：回车（终端通常把 CR 翻译成 LF，这里两种都认）、
# 退格（Backspace 与 Ctrl+H）。命令替换会剥掉末尾换行，因此先在末尾拼接哨兵字符再删除，
# 否则换行写进变量时会被吞成空串。
INPUT_LINE_NEWLINE=$(printf '\n_')
INPUT_LINE_NEWLINE=${INPUT_LINE_NEWLINE%_}
INPUT_LINE_CARRIAGE=$(printf '\r_')
INPUT_LINE_CARRIAGE=${INPUT_LINE_CARRIAGE%_}
INPUT_LINE_ERASE=$(printf '\177_')
INPUT_LINE_ERASE=${INPUT_LINE_ERASE%_}
INPUT_LINE_BACKSPACE=$(printf '\010_')
INPUT_LINE_BACKSPACE=${INPUT_LINE_BACKSPACE%_}

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

# 读取一行输入（普通输入模式）：输入内容后按回车确认，结果写入 READ_LINE。
# 用于编号可能超过一位的菜单（软件模块列表），避免「按下即确认」导致误选。
# 保留返回键的即时性：第一个按键就是 b 时立即结束，不需要再按回车；
# 其余按键按普通输入模式逐字符回显，退格可以删除，回车只表示确认、不再当作刷新。
read_line() {
    if ! input_is_interactive; then
        return 1
    fi

    input_save_terminal
    if ! stty -icanon min 1 time 0 -echo < "$INPUT_TTY" 2>/dev/null; then
        input_restore_terminal
        return 1
    fi

    READ_LINE=''
    READ_LINE_DONE=0
    while [ "$READ_LINE_DONE" -eq 0 ]; do
        # 与 read_key 相同的哨兵写法：命令替换会剥掉末尾换行，直接赋值会把回车吞成空串，
        # 末尾追加哨兵字符 x 再删除，回车、空格等按键才能被原样取到。
        READ_LINE_BYTE=$( { dd if="$INPUT_TTY" bs=1 count=1 2>/dev/null | tr -d '\000'; printf 'x'; } )
        READ_LINE_BYTE=${READ_LINE_BYTE%x}
        case "$READ_LINE_BYTE" in
            '')
                # 读不到数据（EOF 或终端异常）时结束，避免死循环。
                READ_LINE_DONE=1
                ;;
            "$INPUT_LINE_NEWLINE"|"$INPUT_LINE_CARRIAGE")
                READ_LINE_DONE=1
                ;;
            "$INPUT_LINE_ERASE"|"$INPUT_LINE_BACKSPACE")
                if [ -n "$READ_LINE" ]; then
                    READ_LINE=${READ_LINE%?}
                    printf '\b \b' > "$INPUT_TTY"
                fi
                ;;
            b|B)
                # 首个字符就是 b：返回键按下立即生效，不需要回车确认。
                if [ -z "$READ_LINE" ]; then
                    READ_LINE=$READ_LINE_BYTE
                    READ_LINE_DONE=1
                else
                    READ_LINE=$READ_LINE$READ_LINE_BYTE
                fi
                printf '%s' "$READ_LINE_BYTE" > "$INPUT_TTY"
                ;;
            *)
                READ_LINE=$READ_LINE$READ_LINE_BYTE
                printf '%s' "$READ_LINE_BYTE" > "$INPUT_TTY"
                ;;
        esac
    done
    printf '\n' > "$INPUT_TTY"
    input_restore_terminal
    return 0
}

# 判断按键是否为「没有实际选择」的空白键（回车、空格、Tab 等）。
# 菜单中这类按键只当作刷新当前界面，不再提示「无效选择」，避免用户按回车时以为程序卡住。
input_key_is_blank() {
    [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]
}

# Last updated: 2026-09-12 08:49
