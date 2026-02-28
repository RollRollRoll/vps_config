#!/usr/bin/env bash
set -euo pipefail

BASE="https://speed.cloudflare.com"
MEAS_ID="$(date +%s%N)"

# -----------------------
# 你的下载基准参数（你已验证 99,000,000 OK；>=100,000,000 会 403）
# -----------------------
DL_BYTES=99000000
DL_N=8

# -----------------------
# 延迟探针参数
#   - SAMPLES：采样点数
#   - INTERVAL：采样间隔（秒，小数可用）
# -----------------------
LAT_SAMPLES=30
LAT_INTERVAL=0.2

# -----------------------
# 上传参数
#   - UP_N：上传次数（同样走“总字节/总耗时”的平均值）
#   - UP_CANDIDATES：如果大包被拒绝/失败，自动降级到更小的包
# -----------------------
UP_N=6
UP_CANDIDATES=(50000000 25000000 10000000 1000000)

# -----------------------
# 是否测 Loaded latency（下载/上传进行时的延迟）
#   1 = 开启；0 = 关闭
# -----------------------
MEASURE_LOADED_LATENCY=1

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

RESULTS_FILE="${tmpdir}/results.dat"

# 写入结果键值对到 results.dat
write_result() {
  echo "$1=$2" >> "$RESULTS_FILE"
}

# ---- 颜色设置（自动检测 TTY）----
if [[ -t 1 ]]; then
  C_RESET='\033[0m'
  C_CYAN='\033[36m'
  C_BOLD_WHITE='\033[1;37m'
  C_GRAY='\033[90m'
else
  C_RESET='' C_CYAN='' C_BOLD_WHITE='' C_GRAY=''
fi

# ---- 终端格式化输出 ----
render_terminal() {
  source "$RESULTS_FILE"

  local dl_total_mb up_total_mb
  dl_total_mb="$(awk -v b="$DL_TOTAL_BYTES" 'BEGIN{printf "%.1f", b/1000000}')"
  up_total_mb="$(awk -v b="$UP_TOTAL_BYTES" 'BEGIN{printf "%.1f", b/1000000}')"

  echo ""
  printf "   ${C_CYAN}Cloudflare Speed Test Results${C_RESET}\n"
  printf "   Server: speed.cloudflare.com ${C_GRAY}(IPv4)${C_RESET}\n"
  printf "   Timestamp: %s\n" "$TIMESTAMP"
  echo ""
  printf "   ${C_CYAN}━━━ Latency ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
  printf "   Idle:        ${C_BOLD_WHITE}%7s ms${C_RESET}  ${C_GRAY}(jitter: %s ms)${C_RESET}\n" "$IDLE_LAT_AVG" "$IDLE_LAT_JITTER"

  if [[ -n "${DL_LAT_AVG:-}" ]]; then
    printf "   Download:   ${C_BOLD_WHITE}%7s ms${C_RESET}  ${C_GRAY}(jitter: %s ms)${C_RESET}\n" "$DL_LAT_AVG" "$DL_LAT_JITTER"
  fi
  if [[ -n "${UP_LAT_AVG:-}" ]]; then
    printf "   Upload:     ${C_BOLD_WHITE}%7s ms${C_RESET}  ${C_GRAY}(jitter: %s ms)${C_RESET}\n" "$UP_LAT_AVG" "$UP_LAT_JITTER"
  fi

  echo ""
  printf "   ${C_CYAN}━━━ Speed ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
  printf "   Download:   ${C_BOLD_WHITE}%8s Mbps${C_RESET}  ${C_GRAY}(%s MB in %ss)${C_RESET}\n" "$DL_MBPS" "$dl_total_mb" "$DL_TIME_SEC"
  printf "   Upload:     ${C_BOLD_WHITE}%8s Mbps${C_RESET}  ${C_GRAY}(%s MB in %ss)${C_RESET}\n" "$UP_MBPS" "$up_total_mb" "$UP_TIME_SEC"
  echo ""
}

# ---- SVG 散点图生成 ----
# 参数: $1=采样文件路径 $2=颜色(hex) $3=标题
svg_scatter() {
  local datafile="$1"
  local color="$2"
  local title="$3"

  if [[ ! -s "$datafile" ]]; then
    echo "<p style=\"color:#888\">No data for ${title}</p>"
    return
  fi

  awk -v color="$color" -v title="$title" '
  BEGIN {
    n=0; max_y=0
  }
  {
    n++
    y[n] = $1
    if ($1 > max_y) max_y = $1
  }
  END {
    if (n == 0) { print "<p style=\"color:#888\">No data for " title "</p>"; exit }

    w = 600; h = 150
    pad_l = 50; pad_r = 10; pad_t = 25; pad_b = 25
    plot_w = w - pad_l - pad_r
    plot_h = h - pad_t - pad_b

    # 给 y 轴留 10% 余量
    if (max_y < 1) max_y = 1
    y_ceil = max_y * 1.1

    printf "<svg width=\"100%%\" viewBox=\"0 0 %d %d\" xmlns=\"http://www.w3.org/2000/svg\" style=\"max-width:%dpx\">\n", w, h, w

    # 标题
    printf "<text x=\"%d\" y=\"15\" fill=\"#ccc\" font-size=\"12\" font-family=\"monospace\">%s</text>\n", pad_l, title

    # Y 轴标签（0 和 max）
    printf "<text x=\"%d\" y=\"%d\" fill=\"#666\" font-size=\"10\" font-family=\"monospace\" text-anchor=\"end\">%.1f</text>\n", pad_l-5, pad_t+4, y_ceil
    printf "<text x=\"%d\" y=\"%d\" fill=\"#666\" font-size=\"10\" font-family=\"monospace\" text-anchor=\"end\">0</text>\n", pad_l-5, pad_t+plot_h+4

    # 网格线
    printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"#333\" stroke-width=\"0.5\"/>\n", pad_l, pad_t, pad_l+plot_w, pad_t
    printf "<line x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"#333\" stroke-width=\"0.5\"/>\n", pad_l, pad_t+plot_h, pad_l+plot_w, pad_t+plot_h

    # 散点
    for (i=1; i<=n; i++) {
      cx = pad_l + (i-1) * plot_w / (n > 1 ? n-1 : 1)
      cy = pad_t + plot_h - (y[i] / y_ceil) * plot_h
      printf "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3\" fill=\"%s\" opacity=\"0.7\"/>\n", cx, cy, color
    }

    printf "</svg>\n"
  }
  ' "$datafile"
}

# ---- HTML 报告生成 ----
render_html() {
  source "$RESULTS_FILE"

  local report_file="cf_speed_$(date '+%Y%m%d_%H%M%S').html"

  local dl_total_mb up_total_mb
  dl_total_mb="$(awk -v b="$DL_TOTAL_BYTES" 'BEGIN{printf "%.1f", b/1000000}')"
  up_total_mb="$(awk -v b="$UP_TOTAL_BYTES" 'BEGIN{printf "%.1f", b/1000000}')"

  # 生成 SVG 图表
  local svg_idle svg_dl svg_ul
  svg_idle="$(svg_scatter "$lat_idle" "#4fc3f7" "Idle Latency")"
  svg_dl=""
  svg_ul=""
  if [[ -n "${DL_LAT_N:-}" ]]; then
    svg_dl="$(svg_scatter "${tmpdir}/lat_dload.txt" "#66bb6a" "Download Latency")"
  fi
  if [[ -n "${UP_LAT_N:-}" ]]; then
    svg_ul="$(svg_scatter "${tmpdir}/lat_uload.txt" "#ffa726" "Upload Latency")"
  fi

  cat > "$report_file" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Cloudflare Speed Test Report</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    background: #1a1a2e;
    color: #e0e0e0;
    font-family: 'SF Mono', 'Fira Code', 'Cascadia Code', monospace;
    padding: 30px;
    max-width: 800px;
    margin: 0 auto;
  }
  h1 { color: #4fc3f7; font-size: 1.4em; margin-bottom: 4px; }
  .meta { color: #888; font-size: 0.85em; margin-bottom: 24px; }
  .cards { display: flex; gap: 16px; margin-bottom: 24px; }
  .card {
    flex: 1;
    background: #16213e;
    border-radius: 10px;
    padding: 20px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.3);
    text-align: center;
  }
  .card .label { color: #888; font-size: 0.8em; text-transform: uppercase; margin-bottom: 8px; }
  .card .value { font-size: 2em; font-weight: bold; }
  .card .unit { font-size: 0.5em; color: #888; }
  .card .detail { color: #666; font-size: 0.75em; margin-top: 6px; }
  .card.dl .value { color: #66bb6a; }
  .card.ul .value { color: #ffa726; }
  h2 { color: #4fc3f7; font-size: 1.1em; margin: 20px 0 10px; }
  table {
    width: 100%;
    border-collapse: collapse;
    background: #16213e;
    border-radius: 8px;
    overflow: hidden;
    margin-bottom: 24px;
  }
  th { background: #0f3460; color: #4fc3f7; text-align: left; padding: 8px 12px; font-size: 0.8em; }
  td { padding: 8px 12px; border-top: 1px solid #1a1a2e; font-size: 0.85em; }
  tr:hover { background: #1a2744; }
  .chart-section { background: #16213e; border-radius: 8px; padding: 16px; margin-bottom: 16px; }
  .footer { color: #555; font-size: 0.75em; margin-top: 30px; text-align: center; }
</style>
</head>
<body>
<h1>Cloudflare Speed Test Report</h1>
<div class="meta">
  Server: speed.cloudflare.com (IPv4) &middot; ${TIMESTAMP} &middot; ID: ${MEAS_ID}
</div>

<div class="cards">
  <div class="card dl">
    <div class="label">Download</div>
    <div class="value">${DL_MBPS}<span class="unit"> Mbps</span></div>
    <div class="detail">${dl_total_mb} MB in ${DL_TIME_SEC}s</div>
  </div>
  <div class="card ul">
    <div class="label">Upload</div>
    <div class="value">${UP_MBPS}<span class="unit"> Mbps</span></div>
    <div class="detail">${up_total_mb} MB in ${UP_TIME_SEC}s</div>
  </div>
</div>

<h2>Latency Statistics</h2>
<table>
  <thead>
    <tr><th>Type</th><th>n</th><th>Min</th><th>Avg</th><th>P50</th><th>P90</th><th>Max</th><th>Jitter</th></tr>
  </thead>
  <tbody>
    <tr>
      <td>Idle</td>
      <td>${IDLE_LAT_N}</td>
      <td>${IDLE_LAT_MIN} ms</td>
      <td>${IDLE_LAT_AVG} ms</td>
      <td>${IDLE_LAT_P50} ms</td>
      <td>${IDLE_LAT_P90} ms</td>
      <td>${IDLE_LAT_MAX} ms</td>
      <td>${IDLE_LAT_JITTER} ms</td>
    </tr>
HTMLEOF

  # 条件追加下载/上传延迟行
  if [[ -n "${DL_LAT_N:-}" ]]; then
    cat >> "$report_file" <<DLROW
    <tr>
      <td>Download</td>
      <td>${DL_LAT_N}</td>
      <td>${DL_LAT_MIN} ms</td>
      <td>${DL_LAT_AVG} ms</td>
      <td>${DL_LAT_P50} ms</td>
      <td>${DL_LAT_P90} ms</td>
      <td>${DL_LAT_MAX} ms</td>
      <td>${DL_LAT_JITTER} ms</td>
    </tr>
DLROW
  fi

  if [[ -n "${UP_LAT_N:-}" ]]; then
    cat >> "$report_file" <<ULROW
    <tr>
      <td>Upload</td>
      <td>${UP_LAT_N}</td>
      <td>${UP_LAT_MIN} ms</td>
      <td>${UP_LAT_AVG} ms</td>
      <td>${UP_LAT_P50} ms</td>
      <td>${UP_LAT_P90} ms</td>
      <td>${UP_LAT_MAX} ms</td>
      <td>${UP_LAT_JITTER} ms</td>
    </tr>
ULROW
  fi

  cat >> "$report_file" <<HTMLEOF2
  </tbody>
</table>

<h2>Latency Distribution</h2>
<div class="chart-section">
${svg_idle}
</div>
HTMLEOF2

  if [[ -n "$svg_dl" ]]; then
    cat >> "$report_file" <<SVGDL
<div class="chart-section">
${svg_dl}
</div>
SVGDL
  fi

  if [[ -n "$svg_ul" ]]; then
    cat >> "$report_file" <<SVGUL
<div class="chart-section">
${svg_ul}
</div>
SVGUL
  fi

  cat >> "$report_file" <<HTMLFOOTER
<div class="footer">Generated by cf_test.sh &middot; ${TIMESTAMP}</div>
</body>
</html>
HTMLFOOTER

  printf "   Report saved: ${C_BOLD_WHITE}%s${C_RESET}\n" "$report_file"
}

# ---- 采集 latency：输出每个采样点的 RTT(ms) 到文件 ----
# 使用 curl 的 time_* 指标近似 Cloudflare speedtest 的“request->first byte”延迟。
# 这里用 (time_starttransfer - time_pretransfer) * 1000 作为每次的 RTT(ms)。
latency_collect() {
  local url="$1"
  local samples="$2"
  local interval="$3"
  local outfile="$4"

  {
    for _ in $(seq 1 "$samples"); do
      # 输出：http_code time_pretransfer time_starttransfer
      # curl 失败则输出占位行，避免 set -e 退出
      curl -4 -sS --max-time 2 -o /dev/null \
        -w '%{http_code} %{time_pretransfer} %{time_starttransfer}\n' \
        "$url" || echo "000 0 0"
      sleep "$interval"
    done
  } | awk '
    ($1+0)>=200 && ($1+0)<300 {
      rtt_ms = ($3 - $2) * 1000
      if (rtt_ms < 0) rtt_ms = 0
      printf "%.3f\n", rtt_ms
    }
  ' > "$outfile"
}

# ---- 汇总 latency：min/avg/p50/p90/max + jitter(ms) ----
latency_summary() {
  local raw="$1"
  local prefix="$2"
  local label="$3"

  local sorted="${raw}.sorted"
  grep -E '^[0-9]' "$raw" | sort -n > "$sorted" || true

  local n
  n="$(wc -l < "$sorted" | tr -d ' ')"

  if [[ "${n:-0}" -lt 1 ]]; then
    echo "${label}: no samples" >&2
    return 1
  fi

  local min max avg p50 p90 jitter
  min="$(head -n1 "$sorted")"
  max="$(tail -n1 "$sorted")"
  avg="$(awk '{s+=$1} END{printf "%.3f", s/NR}' "$sorted")"

  local p50i p90i
  p50i=$(( (n*50 + 99) / 100 ))
  p90i=$(( (n*90 + 99) / 100 ))
  p50="$(sed -n "${p50i}p" "$sorted")"
  p90="$(sed -n "${p90i}p" "$sorted")"

  jitter="$(awk '
    NR==1 { prev=$1; next }
    {
      d=$1 - prev
      if (d < 0) d=-d
      s+=d
      c++
      prev=$1
    }
    END { if (c>0) printf "%.3f", s/c; else print "0.000" }
  ' "$raw")"

  write_result "${prefix}_N" "$n"
  write_result "${prefix}_MIN" "$min"
  write_result "${prefix}_AVG" "$avg"
  write_result "${prefix}_P50" "$p50"
  write_result "${prefix}_P90" "$p90"
  write_result "${prefix}_MAX" "$max"
  write_result "${prefix}_JITTER" "$jitter"
}

# ---- 下载测试：你原来的“总字节/总耗时”思路，但加上 http_code 检查 ----
download_test() {
  local bytes="$1"
  local n="$2"
  local url="${BASE}/__down?bytes=${bytes}&measId=${MEAS_ID}"

  local start_ns end_ns total_bytes elapsed_ns code
  start_ns="$(date +%s%N)"

  for _ in $(seq 1 "$n"); do
    code="$(curl -4 -sS -o /dev/null -w '%{http_code}' "$url" || echo "000")"
    case "$code" in
      2*) : ;;
      *) echo "download blocked/failed: http_code=$code (bytes=$bytes)" >&2; exit 1 ;;
    esac
  done

  end_ns="$(date +%s%N)"
  total_bytes=$((bytes * n))
  elapsed_ns=$((end_ns - start_ns))

  local sec mbps
  sec="$(awk -v ns="$elapsed_ns" 'BEGIN{printf "%.3f", ns/1e9}')"
  mbps="$(awk -v bytes="$total_bytes" -v ns="$elapsed_ns" 'BEGIN{printf "%.2f", bytes*8/1000000/(ns/1e9)}')"

  write_result "DL_BYTES_PER_REQ" "$bytes"
  write_result "DL_REQS" "$n"
  write_result "DL_TOTAL_BYTES" "$total_bytes"
  write_result "DL_TIME_SEC" "$sec"
  write_result "DL_MBPS" "$mbps"
}

# ---- 上传：先选一个可用的包大小（从大到小尝试），再跑 UP_N 次求平均 ----
upload_test() {
  local url="${BASE}/__up?measId=${MEAS_ID}"

  local chosen_bytes="" chosen_file="" code

  for b in "${UP_CANDIDATES[@]}"; do
    local f="${tmpdir}/up_${b}.bin"
    truncate -s "$b" "$f"

    # 关闭 Expect: 100-continue，避免额外 RTT 干扰（尤其大包）
    code="$(curl -4 -sS -o /dev/null -w '%{http_code}' \
      -H 'Expect:' \
      -X POST --data-binary "@${f}" \
      "$url" || echo "000")"

    case "$code" in
      2*) chosen_bytes="$b"; chosen_file="$f"; break ;;
      *) echo "upload probe failed: bytes=$b http_code=$code, try smaller..." >&2 ;;
    esac
  done

  if [[ -z "$chosen_bytes" ]]; then
    echo "upload: no candidate size succeeded" >&2
    exit 1
  fi
  
  local start_ns end_ns total_bytes elapsed_ns
  start_ns="$(date +%s%N)"

  for _ in $(seq 1 "$UP_N"); do
    code="$(curl -4 -sS -o /dev/null -w '%{http_code}' \
      -H 'Expect:' \
      -X POST --data-binary "@${chosen_file}" \
      "$url" || echo "000")"
    case "$code" in
      2*) : ;;
      *) echo "upload blocked/failed: http_code=$code (bytes=$chosen_bytes)" >&2; exit 1 ;;
    esac
  done

  end_ns="$(date +%s%N)"
  total_bytes=$((chosen_bytes * UP_N))
  elapsed_ns=$((end_ns - start_ns))

  local sec mbps
  sec="$(awk -v ns="$elapsed_ns" 'BEGIN{printf "%.3f", ns/1e9}')"
  mbps="$(awk -v bytes="$total_bytes" -v ns="$elapsed_ns" 'BEGIN{printf "%.2f", bytes*8/1000000/(ns/1e9)}')"

  write_result "UP_BYTES_PER_REQ" "$chosen_bytes"
  write_result "UP_REQS" "$UP_N"
  write_result "UP_TOTAL_BYTES" "$total_bytes"
  write_result "UP_TIME_SEC" "$sec"
  write_result "UP_MBPS" "$mbps"
}

# ---- 写入元信息 ----
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
write_result "MEAS_ID" "$MEAS_ID"
write_result "TIMESTAMP" "\"$TIMESTAMP\""
write_result "TARGET" "$BASE"
write_result "IPV4_FORCED" "yes"

# 1) Idle latency
lat_idle="${tmpdir}/lat_idle.txt"
latency_collect "${BASE}/__down?bytes=0&measId=${MEAS_ID}" "$LAT_SAMPLES" "$LAT_INTERVAL" "$lat_idle"
latency_summary "$lat_idle" "IDLE_LAT" "idle latency"

# 2) Download (+ optional loaded latency during download)
if [[ "$MEASURE_LOADED_LATENCY" == "1" ]]; then
  lat_d="${tmpdir}/lat_dload.txt"
  latency_collect "${BASE}/__down?bytes=0&during=download&measId=${MEAS_ID}" "$LAT_SAMPLES" "$LAT_INTERVAL" "$lat_d" &
  pid_d=$!
fi

download_test "$DL_BYTES" "$DL_N"

if [[ "$MEASURE_LOADED_LATENCY" == "1" ]]; then
  wait "$pid_d" || true
  latency_summary "$lat_d" "DL_LAT" "download latency"
fi

# 3) Upload (+ optional loaded latency during upload)
if [[ "$MEASURE_LOADED_LATENCY" == "1" ]]; then
  lat_u="${tmpdir}/lat_uload.txt"
  latency_collect "${BASE}/__down?bytes=0&during=upload&measId=${MEAS_ID}" "$LAT_SAMPLES" "$LAT_INTERVAL" "$lat_u" &
  pid_u=$!
fi

upload_test

if [[ "$MEASURE_LOADED_LATENCY" == "1" ]]; then
  wait "$pid_u" || true
  latency_summary "$lat_u" "UP_LAT" "upload latency"
fi

# ---- 渲染结果 ----
render_terminal
render_html
