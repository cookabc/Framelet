#!/usr/bin/env bash
# 从 unified log 采集 Framelet 的响应指标，与测试自身的计数互为独立校验。
#
# 打点在 Sources/Framelet/Recording/PerfSignposts.swift（仅 DEBUG）：
#   live_write  field=elapsed|exportProgress published=0|1
#   warm_repaint clips layout_us paint_us
# 同一处还发 os_signpost 事件（live-write 区间、warm-repaint 点），Instruments 里看时间轴用它们；
# `log show` 不返回 signpost，所以脚本口径走日志行。
#
# 用法: scripts/measure-signpost.sh [测试过滤器=ResponsivenessBaselineTests]
set -euo pipefail

FILTER="${1:-ResponsivenessBaselineTests}"
SUBSYSTEM="studio.framelet.mac"

swift test --filter "$FILTER" >/tmp/framelet-signpost-test.log 2>&1 &
TEST_PID=$!

PID=""
while kill -0 "$TEST_PID" 2>/dev/null; do
    PID="$(pgrep -x xctest || true)"
    [[ -n "$PID" ]] && break
    sleep 0.2
done
wait "$TEST_PID" || { echo "测试未通过，见 /tmp/framelet-signpost-test.log"; exit 1; }
[[ -z "$PID" ]] && { echo "没抓到 xctest PID（测试太快或宿主进程名不同）。"; exit 1; }

sleep 1
LINES="$(/usr/bin/log show --last 60s \
    --predicate "subsystem == \"$SUBSYSTEM\" AND processID == $PID" \
    --info --debug --style compact 2>/dev/null | grep -E 'live_write|warm_repaint' || true)"
[[ -z "$LINES" ]] && { echo "未取到 $SUBSYSTEM 日志行。确认是 Debug 构建（打点在 #if DEBUG 内）。"; exit 1; }

echo "=== 写入门控（pid=$PID）==="
for field in elapsed exportProgress; do
    total="$(printf '%s\n' "$LINES" | grep -c "field=$field " || true)"
    published="$(printf '%s\n' "$LINES" | grep -c "field=$field published=true" || true)"
    [[ "$total" -eq 0 ]] && { printf '%-16s 无样本\n' "$field"; continue; }
    printf '%-16s 写入 %s 次 / 触发重绘 %s 次（%d%%）\n' "$field" "$total" "$published" \
        "$((published * 100 / total))"
done

echo
echo "=== 强制整窗重绘耗时 ==="
for key in layout_us paint_us; do
    printf '%s\n' "$LINES" | sed -n "s/.*${key}=\([0-9]*\).*/\1/p" | sort -n | awk -v l="$key" '
        { a[NR] = $1 }
        END {
            if (NR == 0) { printf "%-10s n=0\n", l; exit }
            i50 = int(0.5 * NR + 0.5); if (i50 < 1) i50 = 1
            i95 = int(0.95 * NR + 0.5); if (i95 > NR) i95 = NR
            printf "%-10s n=%-4d p50=%-8d p95=%-8d max=%d  (us)\n", l, NR, a[i50], a[i95], a[NR]
        }'
done
echo
echo "elapsed 的触发比例约 1/5 即门禁生效：计时器 5 Hz，读数只显示整秒。"
