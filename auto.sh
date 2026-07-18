#!/bin/bash

# ============================================
# 微信通话自动录音器 v3.3
# 功能：跟随微信启动 + 专用空设备隔离录音
#        通话检测靠 RecordStream（不是靠播放流）
# 改进：
#   - 音频模块只创建一次，复用不再爆音
#   - 响应从 2s→0.5s，关闭同步
#   - inotifywait 监听微信进程退出
#   - 托盘菜单：暂停/继续、停止录音、退出
#   - 实时显示录音时长
# ============================================

# ===== 配置 =====
OUTPUT_DIR="$HOME/Desktop/wechat_viceo/微信录音"
SCRIPT_NAME="微信录音助手"
WECHAT_PID_FILE="/tmp/wechat_main_pid"

# 音频隔离配置
WECHAT_SINK="wechat-capture"
WECHAT_SINK_DESC="微信通话隔离"

# ===== 状态文件 =====
STATUS_FILE="/tmp/wechat_recorder_status"
PID_FILE="/tmp/wechat_recording.pid"
LOCK_FILE="/tmp/wechat_recorder.lock"
YAD_PID_FILE="/tmp/yad_tray.pid"
YAD_HOLDER_PID_FILE="/tmp/yad_holder.pid"
MODULE_FILE="/tmp/wechat_audio_modules"
YAD_PIPE="/tmp/yad_tray_input"
CLICK_SCRIPT="/tmp/wechat_tray_click.sh"

# ===== 运行时状态 =====
RECORDING_PAUSED=false
DURATION_PID=""
REC_START_TIME=0

mkdir -p "$OUTPUT_DIR"

# ===== 通知函数 =====
notify() {
    local title="$1"
    local message="$2"
    local icon="${3:-info}"
    if command -v notify-send &>/dev/null; then
        notify-send -t 3000 -i "$icon" "$title" "$message"
    fi
}

# ===== 获取微信主进程PID =====
get_wechat_pid() {
    pgrep -x "wechat" | head -1
}

# ===== 检查微信是否运行 =====
is_wechat_running() {
    if [ -f "$WECHAT_PID_FILE" ]; then
        local saved_pid=$(cat "$WECHAT_PID_FILE")
        if kill -0 "$saved_pid" 2>/dev/null && ps -p "$saved_pid" -o comm= 2>/dev/null | grep -q "wechat"; then
            return 0
        fi
    fi
    local pid=$(get_wechat_pid)
    if [ -n "$pid" ]; then
        echo "$pid" > "$WECHAT_PID_FILE"
        return 0
    fi
    return 1
}

# ===== 音频隔离设置 =====
setup_audio_isolation() {
    local logfile="/tmp/wechat_recorder_debug.log"
    local needs_setup=false

    if ! pactl list short sinks 2>/dev/null | grep -q "$WECHAT_SINK"; then
        needs_setup=true
    fi

    if [ "$needs_setup" = false ]; then
        echo "[$(date '+%H:%M:%S')] ✅ 音频隔离已就绪（复用已有模块）" >> "$logfile"
        echo "🔇 微信音频隔离已启用" > "$STATUS_FILE"

        local real_sink=$(pactl list short sinks 2>/dev/null | \
            grep "alsa_output" | head -1 | awk '{print $2}')
        if [ -n "$real_sink" ]; then
            local has_loop=$(pactl list short modules 2>/dev/null | \
                grep "module-loopback" | grep "$WECHAT_SINK" | head -1)
            if [ -z "$has_loop" ]; then
                echo "[$(date '+%H:%M:%S')] ⚠️ loopback 丢失，重新创建" >> "$logfile"
                local loop_id=$(pactl load-module module-loopback \
                    source="$WECHAT_SINK.monitor" \
                    sink="$real_sink" \
                    latency_msec=200 2>&1)
                if [ $? -eq 0 ] && [ -n "$loop_id" ]; then
                    loop_id="$(echo "$loop_id" | tail -1)"
                    echo "$loop_id" > "$MODULE_FILE"
                    echo "[$(date '+%H:%M:%S')] ✅ 重建 loopback (模块 $loop_id)" >> "$logfile"
                fi
            else
                local existing_id=$(echo "$has_loop" | awk '{print $1}')
                echo "$existing_id" > "$MODULE_FILE"
            fi
        fi
        route_wechat_to_isolation >> "$logfile" 2>&1
        return 0
    fi

    # 全新创建（首次运行）
    if [ -f "$MODULE_FILE" ]; then
        local old_ids=$(cat "$MODULE_FILE")
        for mid in $old_ids; do
            [ -n "$mid" ] && pactl unload-module "$mid" 2>/dev/null
        done
        rm -f "$MODULE_FILE"
    fi

    local module_ids=""
    local null_id=$(pactl load-module module-null-sink \
        sink_name="$WECHAT_SINK" \
        sink_properties="device.description=$WECHAT_SINK_DESC" 2>&1)
    if [ $? -ne 0 ] || [ -z "$null_id" ]; then
        echo "[$(date '+%H:%M:%S')] ⚠️ 创建空设备失败: $null_id" >> "$logfile"
        if pactl list short sinks 2>/dev/null | grep -q "$WECHAT_SINK"; then
            echo "[$(date '+%H:%M:%S')] ✅ wechat-capture 已存在，复用" >> "$logfile"
        else
            echo "[$(date '+%H:%M:%S')] ❌ 无法创建 wechat-capture" >> "$logfile"
            return 1
        fi
    else
        module_ids="$(echo "$null_id" | tail -1)"
        echo "[$(date '+%H:%M:%S')] ✅ 创建空设备 wechat-capture (模块 $null_id)" >> "$logfile"
    fi

    local real_sink=$(pactl list short sinks 2>/dev/null | \
        grep "alsa_output" | head -1 | awk '{print $2}')
    if [ -z "$real_sink" ]; then
        echo "[$(date '+%H:%M:%S')] ⚠️ 找不到 alsa 音箱输出" >> "$logfile"
        [ -n "$module_ids" ] && echo "$module_ids" > "$MODULE_FILE"
        return 1
    fi

    local loop_id=$(pactl load-module module-loopback \
        source="$WECHAT_SINK.monitor" \
        sink="$real_sink" \
        latency_msec=200 2>&1)
    if [ $? -ne 0 ] || [ -z "$loop_id" ]; then
        echo "[$(date '+%H:%M:%S')] ⚠️ 创建 loopback 失败: $loop_id" >> "$logfile"
    else
        loop_id="$(echo "$loop_id" | tail -1)"
        module_ids="$module_ids $loop_id"
        echo "[$(date '+%H:%M:%S')] ✅ 创建 loopback: wechat-capture → 音箱 (模块 $loop_id)" >> "$logfile"
    fi

    if [ -n "$module_ids" ]; then
        echo "$module_ids" > "$MODULE_FILE"
    fi
    route_wechat_to_isolation >> "$logfile" 2>&1
    echo "🔇 微信音频隔离已启用" > "$STATUS_FILE"
}

# ===== 微信通话检测 =====
is_wechat_in_call() {
    local pid=$(get_wechat_pid)
    [ -z "$pid" ] && return 1
    pactl list source-outputs 2>/dev/null | \
        grep -q "application.process.id = \"$pid\"" && return 0 || return 1
}

# ===== 将微信音频流路由到隔离空设备 =====
route_wechat_to_isolation() {
    local pid=$(get_wechat_pid)
    [ -z "$pid" ] && return

    local current_id="" current_sink="" is_wechat=false moved=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^Sink[[:space:]]Input[[:space:]]#([0-9]+) ]]; then
            if [ "$is_wechat" = true ] && [ -n "$current_id" ]; then
                local sink_name=$(pactl list short sinks 2>/dev/null | \
                    awk -v sid="$current_sink" '$1==sid{print $2; exit}')
                if [ -n "$sink_name" ] && [ "$sink_name" != "$WECHAT_SINK" ]; then
                    pactl move-sink-input "$current_id" "$WECHAT_SINK" 2>/dev/null && ((moved++))
                fi
            fi
            current_id="${BASH_REMATCH[1]}"
            current_sink=""
            is_wechat=false
        elif [[ "$line" =~ ^[[:space:]]*Sink:[[:space:]]([0-9]+) ]]; then
            current_sink="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ application.process.id[[:space:]]*=[[:space:]]*\"$pid\" ]]; then
            is_wechat=true
        fi
    done < <(pactl list sink-inputs 2>/dev/null)

    if [ "$is_wechat" = true ] && [ -n "$current_id" ]; then
        local sink_name=$(pactl list short sinks 2>/dev/null | \
            awk -v sid="$current_sink" '$1==sid{print $2; exit}')
        if [ -n "$sink_name" ] && [ "$sink_name" != "$WECHAT_SINK" ]; then
            pactl move-sink-input "$current_id" "$WECHAT_SINK" 2>/dev/null && ((moved++))
        fi
    fi
    [ "$moved" -gt 0 ] && echo "🔄 已路由 $moved 个微信音频流到隔离设备"
}

# ===== 录音时长显示（通过 FIFO 更新 yad tooltip） =====
update_yad_tooltip() {
    local text="$1"
    echo "tooltip:$text" > "$YAD_PIPE" 2>/dev/null
}

start_duration_counter() {
    stop_duration_counter
    REC_START_TIME=$SECONDS
    (
        while true; do
            if [ ! -f "$PID_FILE" ]; then break; fi
            local pid=$(cat "$PID_FILE" 2>/dev/null)
            if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then break; fi
            local elapsed=$((SECONDS - REC_START_TIME))
            printf -v time_str "%02d:%02d" $((elapsed/60)) $((elapsed%60))
            if [ "$RECORDING_PAUSED" = true ]; then
                echo "tooltip:⏸️ 录音暂停 $time_str" > "$YAD_PIPE" 2>/dev/null
            else
                echo "tooltip:🎙️ 录音中 $time_str" > "$YAD_PIPE" 2>/dev/null
            fi
            sleep 1
        done
    ) &
    DURATION_PID=$!
}

stop_duration_counter() {
    if [ -n "$DURATION_PID" ]; then
        kill "$DURATION_PID" 2>/dev/null
        DURATION_PID=""
    fi
}

# ===== 录音功能 =====
get_filename() {
    echo "$OUTPUT_DIR/微信录音_$(date '+%Y%m%d_%H%M%S').wav"
}

start_recording() {
    local filename=$(get_filename)
    local logfile="/tmp/wechat_recorder_debug.log"

    echo "[$(date '+%H:%M:%S')] 🎙️ 录音中: $filename" > "$STATUS_FILE"
    notify "🎙️ 微信录音中" "正在录制通话" "mic"

    route_wechat_to_isolation >> "$logfile" 2>&1

    if command -v pw-record &>/dev/null; then
        pw-record --target="$WECHAT_SINK" "$filename" >> "$logfile" 2>&1 &
    else
        parec --device="$WECHAT_SINK.monitor" \
              --format=s16le --rate=48000 --channels=2 >> "$logfile" 2>&1 |
            sox -t raw -r 48000 -e signed -b 16 -c 2 - "$filename" >> "$logfile" 2>&1 &
    fi

    RECORDING_PID=$!
    echo $RECORDING_PID > "$PID_FILE"
    RECORDING_PAUSED=false

    start_duration_counter
}

stop_recording() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 $pid 2>/dev/null; then
            kill $pid 2>/dev/null
            sleep 0.3
            kill -9 $pid 2>/dev/null
        fi
        rm -f "$PID_FILE"
    fi
    RECORDING_PAUSED=false
    stop_duration_counter
    echo "⏸️ 等待通话..." > "$STATUS_FILE"
    update_yad_tooltip "⏸️ 等待通话"
}

# ===== 用户操作处理（通过信号触发） =====
handle_stop_recording() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        kill $pid 2>/dev/null
        sleep 0.3
        kill -9 $pid 2>/dev/null
        rm -f "$PID_FILE"
    fi
    was_recording=false
    RECORDING_PAUSED=false
    stop_duration_counter
    echo "⏹️ 录音已手动停止" > "$STATUS_FILE"
    update_yad_tooltip "⏹️ 录音已手动停止"
    notify "⏹️ 录音已停止" "通话录音已手动停止"
}

handle_pause_toggle() {
    if [ ! -f "$PID_FILE" ]; then
        return
    fi
    local pid=$(cat "$PID_FILE")
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$PID_FILE"
        was_recording=false
        RECORDING_PAUSED=false
        return
    fi

    if [ "$RECORDING_PAUSED" = false ]; then
        kill -STOP "$pid" 2>/dev/null
        RECORDING_PAUSED=true
        echo "⏸️ 录音暂停" > "$STATUS_FILE"
        update_yad_tooltip "⏸️ 录音暂停"
        notify "⏸️ 录音已暂停" "通话录音已暂停"
    else
        kill -CONT "$pid" 2>/dev/null
        RECORDING_PAUSED=false
        echo "🎙️ 录音继续" > "$STATUS_FILE"
        notify "🎙️ 录音继续" "通话录音已继续"
        start_duration_counter
    fi
}

# ===== 检查录音进程 =====
is_recording_alive() {
    if [ ! -f "$PID_FILE" ]; then return 1; fi
    local pid=$(cat "$PID_FILE")
    [ -z "$pid" ] && return 1
    kill -0 "$pid" 2>/dev/null || return 1
    ps -p "$pid" -o comm= 2>/dev/null | grep -qE "pw-record|parec|sox" || return 1
    if [ "$RECORDING_PAUSED" = true ]; then
        ps -p "$pid" -o stat= 2>/dev/null | grep -q "T" && return 0
        RECORDING_PAUSED=false
    fi
    return 0
}

# ===== 主循环 =====
run_monitor() {
    local was_recording=false
    local wechat_was_running=false
    local route_counter=0

    # 设置信号处理
    trap 'handle_stop_recording' USR1
    trap 'handle_pause_toggle'   USR2

    if is_wechat_running; then
        wechat_was_running=true
        echo "✅ 微信已运行，开始监控" > "$STATUS_FILE"
        update_yad_tooltip "✅ 微信已运行，等待通话"
        setup_audio_isolation
    else
        echo "⏳ 等待微信启动..." > "$STATUS_FILE"
        update_yad_tooltip "⏳ 等待微信启动..."
    fi

    while true; do
        if ! is_wechat_running; then
            if [ "$wechat_was_running" = true ]; then
                echo "🛑 微信已退出，录音助手即将关闭" > "$STATUS_FILE"
                if [ "$was_recording" = true ]; then
                    stop_recording
                    was_recording=false
                fi
                echo "🛑 录音助手随微信退出" > "$STATUS_FILE"
                cleanup
                exit 0
            fi
            wechat_was_running=false
            sleep 0.5
            continue
        fi

        if [ "$wechat_was_running" = false ]; then
            setup_audio_isolation
            update_yad_tooltip "✅ 微信已启动，等待通话"
        fi
        wechat_was_running=true

        ((route_counter++))
        if [ "$route_counter" -ge 10 ]; then
            route_wechat_to_isolation
            route_counter=0
        fi

        if [ "$was_recording" = true ] && ! is_recording_alive; then
            echo "[$(date '+%H:%M:%S')] ⚠️ 录音进程已意外退出，重置" > "$STATUS_FILE"
            rm -f "$PID_FILE"
            was_recording=false
            RECORDING_PAUSED=false
            stop_duration_counter
            update_yad_tooltip "⏸️ 等待通话"
        fi

        if is_wechat_in_call; then
            if [ "$was_recording" = false ]; then
                start_recording
                was_recording=true
            fi
        else
            if [ "$was_recording" = true ]; then
                stop_recording
                was_recording=false
                update_yad_tooltip "⏸️ 等待通话"
            fi
        fi
        sleep 0.5
    done
}

# ===== YAD 托盘图标 =====
run_tray() {
    if ! command -v yad &>/dev/null; then
        echo "⚠️ YAD 未安装，使用纯通知模式"
        run_monitor
        return
    fi

    local my_pid=$$

    # 点击托盘图标时执行的脚本（用独立脚本避免引号嵌套问题）
    cat > "$CLICK_SCRIPT" << EOSCRIPT
#!/bin/bash
STATUS=\$(cat $STATUS_FILE 2>/dev/null || echo "等待通话…")
yad --info --title="微信录音助手" --text="\$STATUS\n---\n录音目录: $OUTPUT_DIR" --width=380 --height=150
EOSCRIPT
    chmod +x "$CLICK_SCRIPT"

    # 创建 FIFO 用于 yad --listen 命令通道
    rm -f "$YAD_PIPE"
    mkfifo "$YAD_PIPE"

    # 后台进程保持 FIFO 写入端打开，确保 yad 不会读到 EOF 退出
    ( while true; do sleep 999; done ) > "$YAD_PIPE" &
    echo $! > "$YAD_HOLDER_PID_FILE"

    # 启动 yad 通知图标，从 FIFO 读取 tooltip 更新命令
    yad --notification \
        --image="mic" \
        --text="微信录音助手" \
        --command="$CLICK_SCRIPT" \
        --menu="⏹ 停止录音!kill -USR1 $my_pid|⏸ 暂停/继续!kill -USR2 $my_pid|🚪 退出!gtk-quit" \
        --no-middle \
        --listen < "$YAD_PIPE" &

    YAD_PID=$!
    echo "$YAD_PID" > "$YAD_PID_FILE"

    # 发送初始 tooltip
    echo "tooltip:⏳ 启动中..." > "$YAD_PIPE"

    run_monitor
}

# ===== 清理函数 =====
cleanup() {
    echo "🛑 正在退出..."

    stop_duration_counter

    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        kill $pid 2>/dev/null
        rm -f "$PID_FILE"
    fi
    rm -f "$MODULE_FILE"

    if [ -f "$YAD_PID_FILE" ]; then
        kill $(cat "$YAD_PID_FILE") 2>/dev/null
        rm -f "$YAD_PID_FILE"
    fi
    if [ -f "$YAD_HOLDER_PID_FILE" ]; then
        kill $(cat "$YAD_HOLDER_PID_FILE") 2>/dev/null
        rm -f "$YAD_HOLDER_PID_FILE"
    fi

    rm -f "$YAD_PIPE" "$CLICK_SCRIPT"
    rm -f "$LOCK_FILE" "$WECHAT_PID_FILE"

    echo "⏹️ 录音助手已退出" > "$STATUS_FILE"
    exit 0
}

# ===== 主程序 =====
main() {
    if [ -f "$LOCK_FILE" ]; then
        local old_pid=$(cat "$LOCK_FILE")
        if kill -0 $old_pid 2>/dev/null; then
            echo "⚠️ 录音助手已在运行 (PID: $old_pid)"
            notify "⚠️ 已在运行" "微信录音助手已在后台运行" "error"
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"

    rm -f "$PID_FILE" "$WECHAT_PID_FILE"
    echo "🚀 微信录音助手 v3.3" > "$STATUS_FILE"

    # 清理我自己的 loopback 残留
    if [ -f "$MODULE_FILE" ]; then
        local old_ids=$(cat "$MODULE_FILE")
        for mid in $old_ids; do
            [ -n "$mid" ] && pactl unload-module "$mid" 2>/dev/null
        done
        rm -f "$MODULE_FILE"
    fi

    trap cleanup INT TERM

    run_tray
}

main
