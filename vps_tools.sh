#!/usr/bin/env bash
set -euo pipefail

BASE="https://speed.cloudflare.com"

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
#   - UP_N：上传次数（同样走"总字节/总耗时"的平均值）
#   - UP_CANDIDATES：如果大包被拒绝/失败，自动降级到更小的包
# -----------------------
UP_N=6
UP_CANDIDATES=(50000000 25000000 10000000 1000000)

# -----------------------
# 是否测 Loaded latency（下载/上传进行时的延迟）
#   1 = 开启；0 = 关闭
# -----------------------
MEASURE_LOADED_LATENCY=1

# ---- 颜色设置（自动检测 TTY）----
if [[ -t 1 ]]; then
  C_RESET='\033[0m'
  C_CYAN='\033[36m'
  C_BOLD_WHITE='\033[1;37m'
  C_GRAY='\033[90m'
  C_GREEN='\033[32m'
  C_YELLOW='\033[33m'
  C_RED='\033[31m'
else
  C_RESET='' C_CYAN='' C_BOLD_WHITE='' C_GRAY='' C_GREEN='' C_YELLOW='' C_RED=''
fi

# ---- Root 权限检测 ----
check_root() {
  [[ "$EUID" -eq 0 ]]
}

require_root() {
  if ! check_root; then
    echo -e "\n${C_CYAN}此功能需要 root 权限，请使用 sudo 或以 root 用户运行${C_RESET}"
    return 1
  fi
}

# ---- 对齐提示框（自动计算 CJK 宽字符）----
print_box() {
  local lines=("$@")
  local max_dw=0 dw

  for line in "${lines[@]}"; do
    dw=$(printf '%s' "$line" | wc -L | tr -d ' ')
    (( dw > max_dw )) && max_dw=$dw
  done

  local inner_w=$((max_dw + 4))
  local border
  border=$(printf '═%.0s' $(seq 1 $inner_w))

  echo ""
  echo -e "  ${C_YELLOW}╔${border}╗${C_RESET}"
  for line in "${lines[@]}"; do
    dw=$(printf '%s' "$line" | wc -L | tr -d ' ')
    local pad=$((max_dw - dw))
    local pad_str
    pad_str=$(printf '%*s' "$pad" '')
    echo -e "  ${C_YELLOW}║${C_RESET}  ${C_BOLD_WHITE}${line}${C_RESET}${pad_str}  ${C_YELLOW}║${C_RESET}"
  done
  echo -e "  ${C_YELLOW}╚${border}╝${C_RESET}"
  echo ""
}

# 写入结果键值对到 results.dat
write_result() {
  echo "$1=$2" >> "$RESULTS_FILE"
}

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
<div class="footer">Generated by vps_tools.sh &middot; ${TIMESTAMP}</div>
</body>
</html>
HTMLFOOTER

  printf "   Report saved: ${C_BOLD_WHITE}%s${C_RESET}\n" "$report_file"
}

# ---- 采集 latency：输出每个采样点的 RTT(ms) 到文件 ----
# 使用 curl 的 time_* 指标近似 Cloudflare speedtest 的"request->first byte"延迟。
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

# ---- 下载测试：总字节/总耗时，加上 http_code 检查 ----
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
      *) echo "download blocked/failed: http_code=$code (bytes=$bytes)" >&2; return 1 ;;
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
    return 1
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
      *) echo "upload blocked/failed: http_code=$code (bytes=$chosen_bytes)" >&2; return 1 ;;
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

# ============================================================
#  1) SSH 安全加固
# ============================================================
do_ssh_harden() {
  echo -e "\n${C_BOLD_WHITE}━━━━━━━━━━ SSH 安全加固 ━━━━━━━━━━${C_RESET}\n"

  # --- [1/6] 获取新端口 ---
  echo -e "${C_CYAN}[1/6] 设置 SSH 端口${C_RESET}"
  local new_port
  read -rp "      请输入新的 SSH 端口 [默认 2222]: " new_port
  new_port="${new_port:-2222}"

  if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
    echo -e "      ${C_RED}✗ 端口无效，请输入 1-65535 之间的数字${C_RESET}"
    return 1
  fi
  echo -e "      ${C_GREEN}✓ 端口设置为 ${new_port}${C_RESET}\n"

  # --- [2/6] 获取公钥并写入 ---
  echo -e "${C_CYAN}[2/6] 配置 SSH 公钥${C_RESET}"
  echo "      请粘贴你的 SSH 公钥（以 ssh-rsa / ssh-ed25519 / ecdsa-sha2 开头）："
  local pubkey
  read -r pubkey

  if ! [[ "$pubkey" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2|ssh-dss)[[:space:]] ]]; then
    echo -e "      ${C_RED}✗ 公钥格式无效，请检查后重试${C_RESET}"
    return 1
  fi

  local ssh_dir="$HOME/.ssh"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  if grep -qF "$pubkey" "$ssh_dir/authorized_keys" 2>/dev/null; then
    echo -e "      ${C_YELLOW}● 该公钥已存在，跳过写入${C_RESET}\n"
  else
    echo "$pubkey" >> "$ssh_dir/authorized_keys"
    chmod 600 "$ssh_dir/authorized_keys"
    echo -e "      ${C_GREEN}✓ 公钥已写入 ${ssh_dir}/authorized_keys${C_RESET}\n"
  fi

  # --- [3/6] 备份并修改 sshd_config ---
  echo -e "${C_CYAN}[3/6] 修改 SSH 配置${C_RESET}"
  local sshd_config="/etc/ssh/sshd_config"
  local backup="${sshd_config}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$sshd_config" "$backup"
  echo -e "      ${C_GREEN}✓ 已备份 → ${backup}${C_RESET}"

  sed -i \
    -e "s/^#\?Port .*/Port ${new_port}/" \
    -e "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" \
    -e "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" \
    -e "s/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/" \
    "$sshd_config"

  # 如果配置项不存在则追加
  grep -q "^Port " "$sshd_config" || echo "Port ${new_port}" >> "$sshd_config"
  grep -q "^PubkeyAuthentication " "$sshd_config" || echo "PubkeyAuthentication yes" >> "$sshd_config"
  grep -q "^PasswordAuthentication " "$sshd_config" || echo "PasswordAuthentication no" >> "$sshd_config"
  grep -q "^PermitRootLogin " "$sshd_config" || echo "PermitRootLogin prohibit-password" >> "$sshd_config"

  # 处理 sshd_config.d/ 下可能覆盖主配置的文件（OpenSSH Include 使用 first-match-wins）
  local sshd_config_d="/etc/ssh/sshd_config.d"
  if [[ -d "$sshd_config_d" ]]; then
    local conf_file
    local found_override=false
    for conf_file in "$sshd_config_d"/*.conf; do
      [[ -f "$conf_file" ]] || continue
      if grep -qE '^(Port|PubkeyAuthentication|PasswordAuthentication|PermitRootLogin) ' "$conf_file" 2>/dev/null; then
        found_override=true
        sed -i \
          -e "s/^Port .*/Port ${new_port}/" \
          -e "s/^PubkeyAuthentication .*/PubkeyAuthentication yes/" \
          -e "s/^PasswordAuthentication .*/PasswordAuthentication no/" \
          -e "s/^PermitRootLogin .*/PermitRootLogin prohibit-password/" \
          "$conf_file"
        echo -e "      ${C_YELLOW}⚠ 已同步修改 ${conf_file}${C_RESET}"
      fi
    done
    if $found_override; then
      echo -e "      ${C_YELLOW}  (sshd_config.d/ 下的配置会覆盖主配置，已确保一致)${C_RESET}"
    fi
  fi

  echo -e "      ${C_GREEN}✓ Port=${new_port}, 密钥登录, 禁用密码${C_RESET}\n"

  # --- [4/6] Ubuntu ssh.socket ---
  echo -e "${C_CYAN}[4/6] 检查 Ubuntu ssh.socket${C_RESET}"
  local socket_file="/lib/systemd/system/ssh.socket"
  if [[ -f "$socket_file" ]]; then
    local socket_backup="${socket_file}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$socket_file" "$socket_backup"
    sed -i "s/^ListenStream=.*/ListenStream=${new_port}/" "$socket_file"
    systemctl daemon-reload
    echo -e "      ${C_GREEN}✓ ssh.socket 已更新端口并重载 daemon${C_RESET}\n"
  else
    echo -e "      ${C_GRAY}─ 未检测到 ssh.socket，跳过${C_RESET}\n"
  fi

  # --- [5/6] 配置 ufw ---
  echo -e "${C_CYAN}[5/6] 配置防火墙${C_RESET}"
  if command -v ufw &>/dev/null; then
    ufw allow "${new_port}/tcp"
    ufw --force enable
    echo -e "      ${C_GREEN}✓ ufw 已放行端口 ${new_port}/tcp${C_RESET}\n"
  else
    echo -e "      ${C_YELLOW}⚠ 未检测到 ufw，请手动配置防火墙放行端口 ${new_port}${C_RESET}\n"
  fi

  # --- [6/6] 重启 SSH 服务 ---
  echo -e "${C_CYAN}[6/6] 重启 SSH 服务${C_RESET}"
  if systemctl is-active --quiet sshd 2>/dev/null; then
    systemctl restart sshd
    echo -e "      ${C_GREEN}✓ sshd 已重启${C_RESET}"
  elif systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl restart ssh
    echo -e "      ${C_GREEN}✓ ssh 已重启${C_RESET}"
  else
    echo -e "      ${C_YELLOW}⚠ 无法确定 SSH 服务名，请手动重启${C_RESET}"
  fi

  # --- 完成提示框 ---
  print_box \
    "⚠  重要提示" \
    "" \
    "请用新端口 ${new_port} 新开一个终端测试 SSH 连接" \
    "确认能正常登录后，再关闭当前会话！" \
    "" \
    "ssh -p ${new_port} root@<服务器IP>"
}

# ============================================================
#  2) 系统更新
# ============================================================
do_system_update() {
  echo -e "${C_CYAN}=== 系统更新 ===${C_RESET}"

  if command -v apt &>/dev/null; then
    echo "检测到 apt，开始更新..."
    apt update && apt upgrade -y
  elif command -v dnf &>/dev/null; then
    echo "检测到 dnf，开始更新..."
    dnf upgrade -y
  elif command -v yum &>/dev/null; then
    echo "检测到 yum，开始更新..."
    yum update -y
  else
    echo "未检测到支持的包管理器（apt/dnf/yum）"
    return 1
  fi

  echo -e "\n${C_CYAN}系统更新完成${C_RESET}"
}

# ============================================================
#  3) 安装Nezha探针 (Nezha Agent)
# ============================================================
do_nezha_install() {
  echo -e "${C_CYAN}=== 安装Nezha探针 (Nezha Agent) ===${C_RESET}"
  echo ""

  # 检查并安装 unzip（探针安装脚本依赖 unzip）
  if ! command -v unzip &>/dev/null; then
    echo -e "${C_YELLOW}未检测到 unzip，正在自动安装...${C_RESET}"
    if command -v apt-get &>/dev/null; then
      apt-get update -qq && apt-get install -y -qq unzip
    elif command -v yum &>/dev/null; then
      yum install -y unzip
    elif command -v dnf &>/dev/null; then
      dnf install -y unzip
    elif command -v apk &>/dev/null; then
      apk add unzip
    else
      echo -e "${C_RED}无法自动安装 unzip，请手动安装后重试${C_RESET}"
      return 1
    fi
    if command -v unzip &>/dev/null; then
      echo -e "${C_GREEN}unzip 安装成功${C_RESET}"
    else
      echo -e "${C_RED}unzip 安装失败，请手动安装后重试${C_RESET}"
      return 1
    fi
  fi

  echo "请粘贴完整的安装命令（包含 NZ_SERVER、NZ_CLIENT_SECRET 等参数）："
  echo -e "${C_GRAY}示例: curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh && chmod +x agent.sh && env NZ_SERVER=... NZ_TLS=true NZ_CLIENT_SECRET=... NZ_UUID=... ./agent.sh${C_RESET}"
  echo ""

  local cmd
  read -r cmd

  if [[ -z "$cmd" ]]; then
    echo "命令为空，已取消"
    return 1
  fi

  if ! echo "$cmd" | grep -q "NZ_SERVER" || ! echo "$cmd" | grep -q "NZ_CLIENT_SECRET"; then
    echo "命令中未找到 NZ_SERVER 或 NZ_CLIENT_SECRET，请检查"
    return 1
  fi

  echo ""
  echo -e "即将执行：\n${C_GRAY}${cmd}${C_RESET}"
  read -rp "确认执行？[y/N]: " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "已取消"
    return 0
  fi

  eval "$cmd"
  echo -e "\n${C_CYAN}探针安装命令已执行${C_RESET}"
}

# ============================================================
#  4) 服务器质量检测 (NodeQuality)
# ============================================================
do_node_quality() {
  echo -e "${C_CYAN}=== 服务器质量检测 (NodeQuality) ===${C_RESET}"
  bash <(curl -sL https://run.NodeQuality.com)
}

# ============================================================
#  5) Snell 安装
# ============================================================
do_snell_install() {
  echo -e "${C_CYAN}=== Snell 安装 ===${C_RESET}"
  bash <(curl -L -s menu.jinqians.com)
}

# ============================================================
#  6) 清理备份文件
# ============================================================
do_cleanup_backups() {
  echo -e "\n${C_BOLD_WHITE}━━━━━━━━━━ 清理备份文件 ━━━━━━━━━━${C_RESET}\n"

  local -a files=()
  local f

  # 收集 SSH 加固产生的备份文件
  for f in /etc/ssh/sshd_config.bak.* /lib/systemd/system/ssh.socket.bak.*; do
    [[ -f "$f" ]] 2>/dev/null && files+=("$f")
  done

  if [[ ${#files[@]} -eq 0 ]]; then
    echo -e "  ${C_GREEN}✓ 未发现备份文件，无需清理${C_RESET}\n"
    return 0
  fi

  echo -e "  ${C_CYAN}发现以下备份文件：${C_RESET}"
  for f in "${files[@]}"; do
    local size
    size=$(du -h "$f" 2>/dev/null | cut -f1)
    echo -e "    ${C_GRAY}${f}${C_RESET}  (${size})"
  done

  echo ""
  read -rp "  确认删除以上 ${#files[@]} 个备份文件？[y/N]: " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo -e "  ${C_YELLOW}● 已取消${C_RESET}\n"
    return 0
  fi

  for f in "${files[@]}"; do
    rm -f "$f"
  done
  echo -e "  ${C_GREEN}✓ 已删除 ${#files[@]} 个备份文件${C_RESET}\n"
}

# ============================================================
#  7) Cloudflare 测速
# ============================================================
do_speedtest() {
  local tmpdir MEAS_ID RESULTS_FILE TIMESTAMP
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  MEAS_ID="$(date +%s%N)"
  RESULTS_FILE="${tmpdir}/results.dat"
  TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

  echo -e "\n${C_BOLD_WHITE}━━━━━━━━━━ Cloudflare 测速 ━━━━━━━━━━${C_RESET}\n"

  write_result "MEAS_ID" "$MEAS_ID"
  write_result "TIMESTAMP" "\"$TIMESTAMP\""
  write_result "TARGET" "$BASE"
  write_result "IPV4_FORCED" "yes"

  # 1) Idle latency
  echo -ne "   ${C_CYAN}[1/3]${C_RESET} 测量空闲延迟 (${LAT_SAMPLES} 个采样点)..."
  local lat_idle="${tmpdir}/lat_idle.txt"
  latency_collect "${BASE}/__down?bytes=0&measId=${MEAS_ID}" "$LAT_SAMPLES" "$LAT_INTERVAL" "$lat_idle"
  latency_summary "$lat_idle" "IDLE_LAT" "idle latency"
  echo -e " ${C_GREEN}✓${C_RESET}"

  # 2) Download (+ optional loaded latency during download)
  echo -ne "   ${C_CYAN}[2/3]${C_RESET} 下载测试 (${DL_N}×$(awk -v b="$DL_BYTES" 'BEGIN{printf "%.0fMB", b/1000000}'))..."
  if [[ "$MEASURE_LOADED_LATENCY" == "1" ]]; then
    local lat_d="${tmpdir}/lat_dload.txt"
    latency_collect "${BASE}/__down?bytes=0&during=download&measId=${MEAS_ID}" "$LAT_SAMPLES" "$LAT_INTERVAL" "$lat_d" &
    local pid_d=$!
  fi

  download_test "$DL_BYTES" "$DL_N"

  if [[ "$MEASURE_LOADED_LATENCY" == "1" ]]; then
    wait "$pid_d" || true
    latency_summary "$lat_d" "DL_LAT" "download latency"
  fi
  echo -e " ${C_GREEN}✓${C_RESET}"

  # 3) Upload (+ optional loaded latency during upload)
  echo -ne "   ${C_CYAN}[3/3]${C_RESET} 上传测试 (${UP_N} 次)..."
  if [[ "$MEASURE_LOADED_LATENCY" == "1" ]]; then
    local lat_u="${tmpdir}/lat_uload.txt"
    latency_collect "${BASE}/__down?bytes=0&during=upload&measId=${MEAS_ID}" "$LAT_SAMPLES" "$LAT_INTERVAL" "$lat_u" &
    local pid_u=$!
  fi

  upload_test

  if [[ "$MEASURE_LOADED_LATENCY" == "1" ]]; then
    wait "$pid_u" || true
    latency_summary "$lat_u" "UP_LAT" "upload latency"
  fi
  echo -e " ${C_GREEN}✓${C_RESET}"

  echo ""
  render_terminal
  render_html
}

# ============================================================
#  8) 防火墙管理 (ufw)
# ============================================================

# 获取当前 SSH 端口
_get_ssh_port() {
  local port
  # 优先检查 sshd_config.d/（Include first-match-wins），再检查主配置
  if [[ -d /etc/ssh/sshd_config.d ]]; then
    port="$(grep -hE '^Port ' /etc/ssh/sshd_config.d/*.conf 2>/dev/null | head -n1 | awk '{print $2}')"
  fi
  if [[ -z "$port" ]]; then
    port="$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)"
  fi
  echo "${port:-22}"
}

# 确保 ufw 已安装
_ensure_ufw() {
  if command -v ufw &>/dev/null; then
    return 0
  fi
  echo -ne "   安装 ufw..."
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq ufw >/dev/null 2>&1
  if command -v ufw &>/dev/null; then
    echo -e " ${C_GREEN}✓${C_RESET}"
    return 0
  else
    echo -e " ${C_RED}✗ 安装失败${C_RESET}"
    return 1
  fi
}

# 验证端口或端口范围格式
_validate_port() {
  local input="$1"
  # 单端口: 1-65535
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    (( input >= 1 && input <= 65535 )) && return 0
  fi
  # 端口范围: start:end
  if [[ "$input" =~ ^([0-9]+):([0-9]+)$ ]]; then
    local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}"
    (( s >= 1 && s <= 65535 && e >= 1 && e <= 65535 && s <= e )) && return 0
  fi
  return 1
}

# 验证 IP 地址或 CIDR 网段
_validate_ip_or_cidr() {
  local input="$1"
  local ip prefix

  # 分离 IP 和 CIDR 前缀长度
  if [[ "$input" == */* ]]; then
    ip="${input%/*}"
    prefix="${input#*/}"
    # 前缀长度必须是 0-32 的数字
    if ! [[ "$prefix" =~ ^[0-9]+$ ]] || (( prefix > 32 )); then
      return 1
    fi
  else
    ip="$input"
  fi

  # 验证 IP 格式
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then return 1; fi
  if [[ "$ip" =~ (^|\.)0[0-9] ]]; then return 1; fi
  local IFS='.'
  read -ra octets <<< "$ip"
  for octet in "${octets[@]}"; do
    (( octet > 255 )) && return 1
  done
  return 0
}

# 交互询问来源 IP（可选）
_ask_source_ip() {
  echo "   来源 IP 限制（留空表示允许所有来源）：" >&2
  echo "     支持单个 IP (如 1.2.3.4) 或 CIDR 网段 (如 10.0.0.0/8)" >&2
  local src_ip
  read -rp "   请输入来源 IP [默认 any]: " src_ip
  src_ip="${src_ip// /}"
  if [[ -z "$src_ip" ]]; then
    echo ""
  else
    echo "$src_ip"
  fi
}

# 交互选择协议
_ask_protocol() {
  echo "   选择协议：" >&2
  echo "     1) tcp" >&2
  echo "     2) udp" >&2
  echo "     3) tcp+udp (两者都开)" >&2
  local proto_choice
  read -rp "   请选择协议 [默认 3]: " proto_choice
  proto_choice="${proto_choice:-3}"
  case "$proto_choice" in
    1) echo "tcp" ;;
    2) echo "udp" ;;
    *) echo "both" ;;
  esac
}

# 子功能：开启防火墙
_fw_enable() {
  local ssh_port
  ssh_port="$(_get_ssh_port)"

  echo -e "   ${C_YELLOW}● 检测到当前 SSH 端口: ${ssh_port}${C_RESET}"
  echo -e "   ${C_YELLOW}● 开启前将自动放行该端口，防止连接中断${C_RESET}"
  echo ""
  read -rp "   确认开启防火墙？[y/N]: " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo -e "   ${C_YELLOW}● 已取消${C_RESET}"
    return 0
  fi

  ufw allow "${ssh_port}/tcp" >/dev/null 2>&1
  echo -e "   ${C_GREEN}✓ 已放行 SSH 端口 ${ssh_port}/tcp${C_RESET}"

  ufw --force enable >/dev/null 2>&1
  echo -e "   ${C_GREEN}✓ 防火墙已开启${C_RESET}"
}

# 子功能：关闭防火墙
_fw_disable() {
  read -rp "   确认关闭防火墙？[y/N]: " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo -e "   ${C_YELLOW}● 已取消${C_RESET}"
    return 0
  fi
  ufw disable >/dev/null 2>&1
  echo -e "   ${C_GREEN}✓ 防火墙已关闭${C_RESET}"
}

# 子功能：开放端口
_fw_allow() {
  local port proto src_ip
  read -rp "   请输入端口号或范围 (如 443 或 8000:9000): " port
  if ! _validate_port "$port"; then
    echo -e "   ${C_RED}✗ 端口格式无效${C_RESET}"
    return 1
  fi

  proto="$(_ask_protocol)"
  src_ip="$(_ask_source_ip)"

  if [[ -n "$src_ip" ]] && ! _validate_ip_or_cidr "$src_ip"; then
    echo -e "   ${C_RED}✗ IP 地址格式无效${C_RESET}"
    return 1
  fi
  echo ""

  if [[ -z "$src_ip" ]]; then
    # 无来源限制
    if [[ "$proto" == "both" ]]; then
      ufw allow "$port" >/dev/null 2>&1
      echo -e "   ${C_GREEN}✓ 已开放 ${port}/tcp+udp${C_RESET}"
    else
      ufw allow "${port}/${proto}" >/dev/null 2>&1
      echo -e "   ${C_GREEN}✓ 已开放 ${port}/${proto}${C_RESET}"
    fi
  else
    # 指定来源 IP
    if [[ "$proto" == "both" ]]; then
      ufw allow from "$src_ip" to any port "$port" >/dev/null 2>&1
      echo -e "   ${C_GREEN}✓ 已开放 ${port}/tcp+udp (来源: ${src_ip})${C_RESET}"
    else
      ufw allow from "$src_ip" to any port "$port" proto "$proto" >/dev/null 2>&1
      echo -e "   ${C_GREEN}✓ 已开放 ${port}/${proto} (来源: ${src_ip})${C_RESET}"
    fi
  fi
}

# 子功能：关闭端口
_fw_deny() {
  local port proto src_ip
  read -rp "   请输入端口号或范围 (如 443 或 8000:9000): " port
  if ! _validate_port "$port"; then
    echo -e "   ${C_RED}✗ 端口格式无效${C_RESET}"
    return 1
  fi

  proto="$(_ask_protocol)"
  src_ip="$(_ask_source_ip)"

  if [[ -n "$src_ip" ]] && ! _validate_ip_or_cidr "$src_ip"; then
    echo -e "   ${C_RED}✗ IP 地址格式无效${C_RESET}"
    return 1
  fi
  echo ""

  if [[ -z "$src_ip" ]]; then
    # 无来源限制
    if [[ "$proto" == "both" ]]; then
      ufw deny "$port" >/dev/null 2>&1
      echo -e "   ${C_GREEN}✓ 已关闭 ${port}/tcp+udp${C_RESET}"
    else
      ufw deny "${port}/${proto}" >/dev/null 2>&1
      echo -e "   ${C_GREEN}✓ 已关闭 ${port}/${proto}${C_RESET}"
    fi
  else
    # 指定来源 IP
    if [[ "$proto" == "both" ]]; then
      ufw deny from "$src_ip" to any port "$port" >/dev/null 2>&1
      echo -e "   ${C_GREEN}✓ 已关闭 ${port}/tcp+udp (来源: ${src_ip})${C_RESET}"
    else
      ufw deny from "$src_ip" to any port "$port" proto "$proto" >/dev/null 2>&1
      echo -e "   ${C_GREEN}✓ 已关闭 ${port}/${proto} (来源: ${src_ip})${C_RESET}"
    fi
  fi
}

# 子功能：查看当前规则
_fw_status() {
  echo -e "   ${C_CYAN}当前防火墙规则：${C_RESET}"
  echo ""
  ufw status numbered
}

# 子功能：删除指定规则
_fw_delete() {
  echo -e "   ${C_CYAN}当前防火墙规则：${C_RESET}"
  echo ""
  ufw status numbered
  echo ""

  local rule_num
  read -rp "   请输入要删除的规则编号: " rule_num
  if ! [[ "$rule_num" =~ ^[0-9]+$ ]] || (( rule_num < 1 )); then
    echo -e "   ${C_RED}✗ 编号无效${C_RESET}"
    return 1
  fi

  read -rp "   确认删除规则 #${rule_num}？[y/N]: " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo -e "   ${C_YELLOW}● 已取消${C_RESET}"
    return 0
  fi

  yes | ufw delete "$rule_num" >/dev/null 2>&1
  echo -e "   ${C_GREEN}✓ 规则 #${rule_num} 已删除${C_RESET}"
}

# 子功能：重置防火墙
_fw_reset() {
  echo -e "   ${C_RED}⚠ 这将清除所有防火墙规则并禁用防火墙！${C_RESET}"
  read -rp "   确认重置？[y/N]: " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo -e "   ${C_YELLOW}● 已取消${C_RESET}"
    return 0
  fi

  yes | ufw reset >/dev/null 2>&1
  echo -e "   ${C_GREEN}✓ 防火墙已重置${C_RESET}"
}

do_firewall() {
  _ensure_ufw || return 1

  while true; do
    echo -e "\n${C_BOLD_WHITE}━━━━━━━━━━ 防火墙管理 (ufw) ━━━━━━━━━━${C_RESET}\n"

    # 显示当前状态
    if ufw status 2>/dev/null | grep -qw "active"; then
      echo -e "   状态: ${C_GREEN}● 已开启${C_RESET}"
    else
      echo -e "   状态: ${C_RED}● 未开启${C_RESET}"
    fi
    echo ""

    echo " 1) 开启防火墙"
    echo " 2) 关闭防火墙"
    echo " 3) 开放端口"
    echo " 4) 关闭端口"
    echo " 5) 查看当前规则"
    echo " 6) 删除指定规则"
    echo " 7) 重置防火墙"
    echo " 0) 返回主菜单"
    echo ""

    local fw_choice
    read -rp "请输入选项 [0-7]: " fw_choice
    echo ""
    case "$fw_choice" in
      1) _fw_enable ;;
      2) _fw_disable ;;
      3) _fw_allow ;;
      4) _fw_deny ;;
      5) _fw_status ;;
      6) _fw_delete ;;
      7) _fw_reset ;;
      0) return 0 ;;
      *) echo "   无效选项" ;;
    esac
  done
}

# ============================================================
#  9) 端口转发 (nftables)
# ============================================================

NFT_CONF_DIR="/etc/nftables.d"
NFT_CONF_FILE="${NFT_CONF_DIR}/port-forward.conf"
NFT_BACKUP_DIR="${NFT_CONF_DIR}/backups"
NFT_MAIN_CONF="/etc/nftables.conf"
NFT_SYSCTL_CONF="/etc/sysctl.d/99-nft-forward.conf"
NFT_LOG_FILE="/var/log/nft-forward.log"
NFT_LOGROTATE_CONF="/etc/logrotate.d/nft-forward"
NFT_TABLE_NAME="port_forward"
declare -a NFT_RULES=()

_nft_validate_port() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" =~ ^0[0-9] ]]; then
    return 1
  fi
  (( port >= 1 && port <= 65535 ))
}

_nft_validate_ip() {
  local ip="$1"
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then return 1; fi
  if [[ "$ip" =~ (^|\.)0[0-9] ]]; then return 1; fi
  local IFS='.'
  read -ra octets <<< "$ip"
  for octet in "${octets[@]}"; do
    (( octet > 255 )) && return 1
  done
  return 0
}

_nft_get_local_ip() {
  local ip
  ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1) || true
  if [[ -n "$ip" ]]; then echo "$ip"; return; fi
  ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1) || true
  if [[ -n "$ip" ]]; then echo "$ip"; return; fi
  hostname -I 2>/dev/null | awk '{print $1}' || true
}

# 用法: _nft_firewall_port open|close <lport> <dest_ip> <dport> [src_ip] [force]
_nft_firewall_port() {
  local action="$1" lport="$2" dest_ip="$3" dport="$4" src_ip="${5:-}" force="${6:-}"

  if [[ "$action" == "open" ]]; then
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      firewall-cmd --add-port="${lport}/tcp" --permanent >/dev/null 2>&1 || true
      firewall-cmd --add-port="${lport}/udp" --permanent >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      echo -e "${C_GREEN}[信息]${C_RESET} 已在 firewalld 中放行端口 ${lport} (tcp+udp)。"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] firewalld 放行端口 ${lport}" >> "$NFT_LOG_FILE" 2>/dev/null || true
      return
    fi
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
      local _src_info=""
      if [[ -n "$src_ip" ]]; then
        ufw allow from "$src_ip" to any port "${lport}" proto tcp >/dev/null 2>&1 || true
        ufw allow from "$src_ip" to any port "${lport}" proto udp >/dev/null 2>&1 || true
        ufw route allow proto tcp from "$src_ip" to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
        ufw route allow proto udp from "$src_ip" to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
        _src_info=" (来源: ${src_ip})"
      else
        ufw allow "${lport}/tcp" >/dev/null 2>&1 || true
        ufw allow "${lport}/udp" >/dev/null 2>&1 || true
        ufw route allow proto tcp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
        ufw route allow proto udp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
      fi
      echo -e "${C_GREEN}[信息]${C_RESET} 已在 UFW 中放行端口 ${lport} 及转发到 ${dest_ip}:${dport} (tcp+udp)${_src_info}。"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] UFW 放行端口 ${lport} 转发到 ${dest_ip}:${dport}${_src_info}" >> "$NFT_LOG_FILE" 2>/dev/null || true
      return
    fi
    if command -v iptables &>/dev/null && iptables -S &>/dev/null; then
      iptables -C INPUT -p tcp --dport "${lport}" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "${lport}" -j ACCEPT 2>/dev/null || true
      iptables -C INPUT -p udp --dport "${lport}" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport "${lport}" -j ACCEPT 2>/dev/null || true
      iptables -C FORWARD -d "${dest_ip}" -p tcp --dport "${dport}" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -d "${dest_ip}" -p tcp --dport "${dport}" -j ACCEPT 2>/dev/null || true
      iptables -C FORWARD -d "${dest_ip}" -p udp --dport "${dport}" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -d "${dest_ip}" -p udp --dport "${dport}" -j ACCEPT 2>/dev/null || true
      iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
      echo -e "${C_GREEN}[信息]${C_RESET} 已在 iptables 中放行: INPUT ${lport}, FORWARD → ${dest_ip}:${dport} (tcp+udp)。"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] iptables 放行 INPUT:${lport} FORWARD:${dest_ip}:${dport}" >> "$NFT_LOG_FILE" 2>/dev/null || true
      local _persisted=false
      if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 && _persisted=true
      fi
      if ! $_persisted && command -v iptables-save &>/dev/null; then
        if [[ -d /etc/iptables ]]; then
          iptables-save > /etc/iptables/rules.v4 2>/dev/null && _persisted=true
        elif [[ -d /etc/sysconfig ]]; then
          iptables-save > /etc/sysconfig/iptables 2>/dev/null && _persisted=true
        fi
      fi
      if ! $_persisted && command -v service &>/dev/null; then
        service iptables save >/dev/null 2>&1 && _persisted=true
      fi
      if ! $_persisted; then
        echo -e "${C_YELLOW}[警告]${C_RESET} iptables 规则已生效但未能自动持久化，重启后可能丢失。"
      fi
    fi
  else
    # --- close ---
    local _still_used=false
    if [[ "$force" != "force" ]]; then
      local _rule _lp _di _dp _
      for _rule in "${NFT_RULES[@]}"; do
        IFS='|' read -r _lp _di _dp _ _ <<< "$_rule"
        [[ "$_lp" == "$lport" ]] && continue
        if [[ "$_di" == "$dest_ip" && "$_dp" == "$dport" ]]; then
          _still_used=true; break
        fi
      done
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      firewall-cmd --remove-port="${lport}/tcp" --permanent >/dev/null 2>&1 || true
      firewall-cmd --remove-port="${lport}/udp" --permanent >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      echo -e "${C_GREEN}[信息]${C_RESET} 已从 firewalld 中移除端口 ${lport} 的放行规则。"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] firewalld 移除端口 ${lport}" >> "$NFT_LOG_FILE" 2>/dev/null || true
      return
    fi
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
      if [[ -n "$src_ip" ]]; then
        yes | ufw delete allow from "$src_ip" to any port "${lport}" proto tcp >/dev/null 2>&1 || true
        yes | ufw delete allow from "$src_ip" to any port "${lport}" proto udp >/dev/null 2>&1 || true
        if ! $_still_used; then
          yes | ufw route delete allow proto tcp from "$src_ip" to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
          yes | ufw route delete allow proto udp from "$src_ip" to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
        fi
      else
        yes | ufw delete allow "${lport}/tcp" >/dev/null 2>&1 || true
        yes | ufw delete allow "${lport}/udp" >/dev/null 2>&1 || true
        if ! $_still_used; then
          yes | ufw route delete allow proto tcp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
          yes | ufw route delete allow proto udp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
        fi
      fi
      echo -e "${C_GREEN}[信息]${C_RESET} 已从 UFW 中移除端口 ${lport} 的放行规则。"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] UFW 移除端口 ${lport}" >> "$NFT_LOG_FILE" 2>/dev/null || true
      return
    fi
    if command -v iptables &>/dev/null && iptables -S &>/dev/null; then
      iptables -D INPUT -p tcp --dport "${lport}" -j ACCEPT 2>/dev/null || true
      iptables -D INPUT -p udp --dport "${lport}" -j ACCEPT 2>/dev/null || true
      if ! $_still_used; then
        iptables -D FORWARD -d "${dest_ip}" -p tcp --dport "${dport}" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -d "${dest_ip}" -p udp --dport "${dport}" -j ACCEPT 2>/dev/null || true
      fi
      echo -e "${C_GREEN}[信息]${C_RESET} 已从 iptables 中移除: INPUT ${lport}, FORWARD → ${dest_ip}:${dport}。"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] iptables 移除 INPUT:${lport} FORWARD:${dest_ip}:${dport}" >> "$NFT_LOG_FILE" 2>/dev/null || true
      if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
      elif command -v iptables-save &>/dev/null; then
        if [[ -d /etc/iptables ]]; then iptables-save > /etc/iptables/rules.v4 2>/dev/null
        elif [[ -d /etc/sysconfig ]]; then iptables-save > /etc/sysconfig/iptables 2>/dev/null
        fi
      elif command -v service &>/dev/null; then
        service iptables save >/dev/null 2>&1
      fi
    fi
  fi
}

_nft_init_conf() {
  mkdir -p "$NFT_CONF_DIR" "$NFT_BACKUP_DIR" 2>/dev/null || {
    echo -e "${C_RED}[错误]${C_RESET} 无法创建配置目录 ${NFT_CONF_DIR}，请检查权限。"
    return 1
  }
  touch "$NFT_LOG_FILE" 2>/dev/null || true
  if [[ ! -f "$NFT_LOGROTATE_CONF" ]]; then
    cat > "$NFT_LOGROTATE_CONF" <<'LOGROTATE'
/var/log/nft-forward.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
LOGROTATE
  fi
  if [[ ! -f "$NFT_MAIN_CONF" ]]; then
    cat > "$NFT_MAIN_CONF" <<'NFTCONF'
#!/usr/sbin/nft -f
include "/etc/nftables.d/*.conf"
NFTCONF
    echo -e "${C_GREEN}[信息]${C_RESET} 已创建 ${NFT_MAIN_CONF}。"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 创建 ${NFT_MAIN_CONF}" >> "$NFT_LOG_FILE" 2>/dev/null || true
  elif ! grep -qF 'include "/etc/nftables.d/*.conf"' "$NFT_MAIN_CONF" 2>/dev/null; then
    echo 'include "/etc/nftables.d/*.conf"' >> "$NFT_MAIN_CONF"
    echo -e "${C_GREEN}[信息]${C_RESET} 已在 ${NFT_MAIN_CONF} 中添加 include 指令。"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 在 ${NFT_MAIN_CONF} 中添加 include 指令" >> "$NFT_LOG_FILE" 2>/dev/null || true
  fi
  if [[ ! -f "$NFT_CONF_FILE" ]]; then
    _nft_save_and_reload no-reload || return 1
  fi
}

_nft_load_rules() {
  NFT_RULES=()
  [[ ! -f "$NFT_CONF_FILE" ]] && return
  local _comment="" _src_ip=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*#\ *转发: ]]; then
      _comment=""
      _src_ip=""
      if [[ "$line" =~ \|\ *备注:\ *([^|]*) ]]; then
        _comment="${BASH_REMATCH[1]}"
        _comment="${_comment% }"
      fi
      if [[ "$line" =~ \|\ *来源:\ *([^|]*) ]]; then
        _src_ip="${BASH_REMATCH[1]}"
        _src_ip="${_src_ip% }"
      fi
      continue
    elif [[ "$line" =~ ^[[:space:]]*# ]]; then
      _comment=""
      _src_ip=""
      continue
    fi
    if [[ "$line" =~ tcp\ dport\ ([0-9]+)\ dnat\ to\ ([0-9.]+):([0-9]+) ]]; then
      NFT_RULES+=("${BASH_REMATCH[1]}|${BASH_REMATCH[2]}|${BASH_REMATCH[3]}|${_comment}|${_src_ip}")
      _comment=""
      _src_ip=""
    fi
  done < "$NFT_CONF_FILE"
}

_nft_save_and_reload() {
  local skip_reload="${1:-}"
  # backup
  if [[ -f "$NFT_CONF_FILE" ]]; then
    cp "$NFT_CONF_FILE" "${NFT_BACKUP_DIR}/port-forward.conf.$(date '+%Y%m%d_%H%M%S')" 2>/dev/null || true
  fi
  # write
  local local_ip
  local_ip=$(_nft_get_local_ip)
  if [[ -z "$local_ip" ]]; then
    echo -e "${C_RED}[错误]${C_RESET} 无法获取本机 IP 地址，请检查网络配置。"
    return 1
  fi
  local tmp_file="${NFT_CONF_FILE}.tmp.$$"
  cat > "$tmp_file" <<EOF
#!/usr/sbin/nft -f

# --- 本机 IP（自动获取，用于 SNAT 回源）
define LOCAL_IP = ${local_ip}

table ip ${NFT_TABLE_NAME} {
    # --- PREROUTING (DNAT) ---
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
EOF
  local rule lport dip dport comment src_ip comment_suffix
  for rule in "${NFT_RULES[@]}"; do
    IFS='|' read -r lport dip dport comment src_ip <<< "$rule"
    comment_suffix=""
    [[ -n "$comment" ]] && comment_suffix+=" | 备注: ${comment}"
    [[ -n "$src_ip" ]] && comment_suffix+=" | 来源: ${src_ip}"
    cat >> "$tmp_file" <<EOF

        # 转发: 本机:${lport} -> ${dip}:${dport}${comment_suffix}
        ${src_ip:+ip saddr ${src_ip} }tcp dport ${lport} dnat to ${dip}:${dport}
        ${src_ip:+ip saddr ${src_ip} }udp dport ${lport} dnat to ${dip}:${dport}
EOF
  done
  cat >> "$tmp_file" <<EOF
    }

    # --- POSTROUTING (SNAT) ---
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
EOF
  for rule in "${NFT_RULES[@]}"; do
    IFS='|' read -r lport dip dport comment src_ip <<< "$rule"
    comment_suffix=""
    [[ -n "$comment" ]] && comment_suffix+=" | 备注: ${comment}"
    [[ -n "$src_ip" ]] && comment_suffix+=" | 来源: ${src_ip}"
    cat >> "$tmp_file" <<EOF

        # 回源: 发往 ${dip}:${dport} 的已 DNAT 流量, SNAT 为本机 IP${comment_suffix}
        ip daddr ${dip} tcp dport ${dport} ct status dnat snat to \$LOCAL_IP
        ip daddr ${dip} udp dport ${dport} ct status dnat snat to \$LOCAL_IP
EOF
  done
  cat >> "$tmp_file" <<EOF
    }
}
EOF
  mv -f "$tmp_file" "$NFT_CONF_FILE" 2>/dev/null || {
    echo -e "${C_RED}[错误]${C_RESET} 无法写入配置文件 ${NFT_CONF_FILE}"
    rm -f "$tmp_file" 2>/dev/null || true
    return 1
  }
  # reload
  if [[ "$skip_reload" != "no-reload" ]]; then
    nft flush table ip "$NFT_TABLE_NAME" 2>/dev/null || true
    nft delete table ip "$NFT_TABLE_NAME" 2>/dev/null || true
    if ! nft -f "$NFT_CONF_FILE"; then
      echo -e "${C_RED}[错误]${C_RESET} 加载配置文件失败，请检查 ${NFT_CONF_FILE}"
      return 1
    fi
  fi
  return 0
}

_nft_setup_kernel() {
  local current
  current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || current="0"
  if [[ "$current" != "1" ]]; then
    if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
      echo -e "${C_GREEN}[信息]${C_RESET} 已开启 IPv4 转发。"
    else
      echo -e "${C_YELLOW}[警告]${C_RESET} 无法开启 IPv4 转发，请手动执行: sysctl -w net.ipv4.ip_forward=1"
    fi
  fi
  mkdir -p "$(dirname "$NFT_SYSCTL_CONF")" 2>/dev/null || true
  touch "$NFT_SYSCTL_CONF" 2>/dev/null || true
  if grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' "$NFT_SYSCTL_CONF" 2>/dev/null; then
    sed -i -E 's|^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=.*|net.ipv4.ip_forward=1|' "$NFT_SYSCTL_CONF" 2>/dev/null || true
  else
    echo "net.ipv4.ip_forward=1" >> "$NFT_SYSCTL_CONF" 2>/dev/null || true
  fi
  sysctl -p "$NFT_SYSCTL_CONF" >/dev/null 2>&1 || true
  # BBR + fq
  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    echo -e "${C_YELLOW}[警告]${C_RESET} 内核不支持 BBR，已跳过。"
    return 0
  fi
  local cur_cc cur_qd
  cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || cur_cc=""
  cur_qd=$(sysctl -n net.core.default_qdisc 2>/dev/null) || cur_qd=""
  if [[ "$cur_cc" == "bbr" && "$cur_qd" == "fq" ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} BBR + fq 已启用（无需修改）。"
    return 0
  fi
  sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
  cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || cur_cc=""
  cur_qd=$(sysctl -n net.core.default_qdisc 2>/dev/null) || cur_qd=""
  if [[ "$cur_cc" == "bbr" && "$cur_qd" == "fq" ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} 已开启 BBR + fq。"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开启 BBR+fq" >> "$NFT_LOG_FILE" 2>/dev/null || true
  else
    echo -e "${C_YELLOW}[警告]${C_RESET} 尝试开启 BBR+fq 后未确认生效（当前: cc=${cur_cc:-?}, qdisc=${cur_qd:-?}）。"
  fi
  if grep -qE '^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=' "$NFT_SYSCTL_CONF"; then
    sed -i -E 's|^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=.*|net.core.default_qdisc=fq|' "$NFT_SYSCTL_CONF" 2>/dev/null || true
  else
    echo "net.core.default_qdisc=fq" >> "$NFT_SYSCTL_CONF" 2>/dev/null || true
  fi
  if grep -qE '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=' "$NFT_SYSCTL_CONF"; then
    sed -i -E 's/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=.*/net.ipv4.tcp_congestion_control=bbr/' "$NFT_SYSCTL_CONF" 2>/dev/null || true
  else
    echo "net.ipv4.tcp_congestion_control=bbr" >> "$NFT_SYSCTL_CONF" 2>/dev/null || true
  fi
  sysctl -p "$NFT_SYSCTL_CONF" >/dev/null 2>&1 || true
  echo -e "${C_GREEN}[信息]${C_RESET} 已持久化 BBR + fq 到 ${NFT_SYSCTL_CONF}。"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 持久化 BBR+fq 到 ${NFT_SYSCTL_CONF}" >> "$NFT_LOG_FILE" 2>/dev/null || true
}

_nft_do_install() {
  echo ""
  if command -v nft &>/dev/null; then
    echo -e "${C_GREEN}[信息]${C_RESET} nftables 已安装。"
    nft --version 2>/dev/null || true
    echo ""
    echo -e "${C_YELLOW}[警告]${C_RESET} 安装将清空所有已有 nftables 配置，由本脚本统一接管。"
    echo -e "${C_YELLOW}[警告]${C_RESET} 已有的配置文件将被备份（重命名为 .bak）。"
    read -rp "是否继续？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo -e "${C_GREEN}[信息]${C_RESET} 已取消。"
      return 0
    fi
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    if [[ -f "$NFT_MAIN_CONF" ]]; then
      mv "$NFT_MAIN_CONF" "${NFT_MAIN_CONF}.bak.${ts}" 2>/dev/null || true
      echo -e "${C_GREEN}[信息]${C_RESET} 已备份 ${NFT_MAIN_CONF} → ${NFT_MAIN_CONF}.bak.${ts}"
    fi
    if [[ -d "$NFT_CONF_DIR" ]]; then
      local f
      for f in "${NFT_CONF_DIR}"/*.conf; do
        [[ -f "$f" ]] || continue
        mv "$f" "${f}.bak.${ts}" 2>/dev/null || true
        echo -e "${C_GREEN}[信息]${C_RESET} 已备份 ${f} → ${f}.bak.${ts}"
      done
    fi
    nft flush ruleset 2>/dev/null || true
    echo -e "${C_GREEN}[信息]${C_RESET} 已清空当前 nftables 规则集。"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 清空已有配置并由脚本接管 (备份时间戳: ${ts})" >> "$NFT_LOG_FILE" 2>/dev/null || true
    _nft_setup_kernel
    # 检测防火墙状态
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      echo -e "${C_GREEN}[信息]${C_RESET} 检测到 firewalld 正在运行，添加转发规则时将自动放行对应端口。"
    elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
      echo -e "${C_GREEN}[信息]${C_RESET} 检测到 UFW 正在运行，添加转发规则时将自动放行对应端口。"
    elif command -v iptables &>/dev/null && iptables -S &>/dev/null; then
      echo -e "${C_GREEN}[信息]${C_RESET} 检测到 iptables 规则集存在，添加转发规则时将自动放行对应端口。"
    fi
    _nft_init_conf
    if ! nft -f "$NFT_MAIN_CONF"; then
      echo -e "${C_RED}[错误]${C_RESET} 加载 ${NFT_MAIN_CONF} 失败，请检查配置。"
      return 1
    fi
    if systemctl enable --now nftables 2>/dev/null; then
      echo -e "${C_GREEN}[信息]${C_RESET} 已启用 nftables 服务。"
    else
      echo -e "${C_YELLOW}[警告]${C_RESET} nftables 服务启用失败，请手动执行: systemctl enable --now nftables"
    fi
    echo -e "${C_GREEN}[信息]${C_RESET} 初始化完成，所有配置已由本脚本接管。"
    return 0
  fi

  echo -e "${C_GREEN}[信息]${C_RESET} 未检测到 nftables，准备安装..."
  local pkg_mgr="unknown"
  if command -v apt-get &>/dev/null; then pkg_mgr="apt"
  elif command -v dnf &>/dev/null; then pkg_mgr="dnf"
  elif command -v yum &>/dev/null; then pkg_mgr="yum"
  elif command -v pacman &>/dev/null; then pkg_mgr="pacman"
  fi
  case "$pkg_mgr" in
    apt) apt-get update -y && apt-get install -y nftables ;;
    dnf) dnf install -y nftables ;;
    yum) yum install -y nftables ;;
    pacman) pacman -Sy --noconfirm nftables ;;
    *) echo -e "${C_RED}[错误]${C_RESET} 无法识别包管理器，请手动安装 nftables。"; return 1 ;;
  esac
  if ! command -v nft &>/dev/null; then
    echo -e "${C_RED}[错误]${C_RESET} 安装失败，请手动安装 nftables。"
    return 1
  fi
  echo -e "${C_GREEN}[信息]${C_RESET} nftables 安装成功。"
  nft --version 2>/dev/null || true
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 安装 nftables" >> "$NFT_LOG_FILE" 2>/dev/null || true
  _nft_setup_kernel
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo -e "${C_GREEN}[信息]${C_RESET} 检测到 firewalld 正在运行，添加转发规则时将自动放行对应端口。"
  elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
    echo -e "${C_GREEN}[信息]${C_RESET} 检测到 UFW 正在运行，添加转发规则时将自动放行对应端口。"
  elif command -v iptables &>/dev/null && iptables -S &>/dev/null; then
    echo -e "${C_GREEN}[信息]${C_RESET} 检测到 iptables 规则集存在，添加转发规则时将自动放行对应端口。"
  fi
  _nft_init_conf
  if systemctl enable --now nftables 2>/dev/null; then
    echo -e "${C_GREEN}[信息]${C_RESET} 已启用 nftables 服务。"
  else
    echo -e "${C_YELLOW}[警告]${C_RESET} nftables 服务启用失败，请手动执行: systemctl enable --now nftables"
  fi
  echo -e "${C_GREEN}[信息]${C_RESET} 安装与初始化完成。"
}

_nft_get_ufw_src_for_port() {
  local lport="$1" ufw_rules="$2"
  local sources
  # 匹配 IN 规则（兼容 "ALLOW IN" 和 "ALLOW" 两种格式），排除 FWD 规则
  sources=$(echo "$ufw_rules" | grep -v "ALLOW FWD" | grep -E "^${lport}(/[a-z]+)?[[:space:]]+" | awk '{print $NF}' | sort -u)
  if [[ -z "$sources" ]]; then
    echo "-"
  else
    sources="${sources//Anywhere/any}"
    echo "$sources" | tr '\n' ',' | sed 's/,$//'
  fi
}

_nft_do_list() {
  echo ""
  _nft_load_rules
  if [[ ${#NFT_RULES[@]} -eq 0 ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} 当前没有端口转发规则。"
    return
  fi
  # 检测 UFW 是否激活，提前获取规则
  local ufw_active=false ufw_rules=""
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
    ufw_active=true
    ufw_rules=$(ufw status 2>/dev/null | grep "ALLOW" | grep -v '(v6)' || true)
  fi
  printf "\n\033[1m%-8s %-12s %-14s    %-26s  %-22s  %s\033[0m\n" "序号" "协议" "本机端口" "目标地址" "来源限制" "备注"
  echo "──────────────────────────────────────────────────────────────────────────────────────"
  local idx=1 rule lport dip dport comment src_ip
  for rule in "${NFT_RULES[@]}"; do
    IFS='|' read -r lport dip dport comment src_ip <<< "$rule"
    local display_src="${src_ip:-any}"
    if $ufw_active; then
      local ufw_src
      ufw_src=$(_nft_get_ufw_src_for_port "$lport" "$ufw_rules")
      [[ "$ufw_src" != "-" ]] && display_src="$ufw_src"
    fi
    printf "%-6s %-10s %-10s -> %-22s  %-18s  %s\n" "$idx" "tcp+udp" "$lport" "${dip}:${dport}" "$display_src" "$comment"
    ((idx++))
  done
  echo ""
}

_nft_do_add() {
  echo ""
  if ! command -v nft &>/dev/null; then
    echo -e "${C_RED}[错误]${C_RESET} nftables 未安装，请先选择 [1] 安装。"
    return
  fi
  _nft_init_conf || return
  _nft_setup_kernel
  _nft_load_rules
  local local_ip
  local_ip=$(_nft_get_local_ip)
  if [[ -z "$local_ip" ]]; then
    echo -e "${C_RED}[错误]${C_RESET} 无法获取本机 IP 地址，请检查网络配置。"
    return
  fi
  local lport
  while true; do
    read -rp "请输入本机监听端口 (1-65535): " lport
    if _nft_validate_port "$lport"; then break; fi
    echo -e "${C_RED}[错误]${C_RESET} 端口无效，请输入 1-65535 之间的数字。"
  done
  local rule rp
  for rule in "${NFT_RULES[@]}"; do
    IFS='|' read -r rp _ _ <<< "$rule"
    if [[ "$rp" == "$lport" ]]; then
      echo -e "${C_RED}[错误]${C_RESET} 本机端口 ${lport} 已存在转发规则，请先删除后再添加。"
      return
    fi
  done
  # 端口占用检测（内联）
  local conflict=""
  if ss -tlnp 2>/dev/null | grep -qE ":${lport}\b"; then conflict="TCP"; fi
  if ss -ulnp 2>/dev/null | grep -qE ":${lport}\b"; then
    [[ -n "$conflict" ]] && conflict="TCP+UDP" || conflict="UDP"
  fi
  if [[ -n "$conflict" ]]; then
    echo -e "${C_YELLOW}[警告]${C_RESET} 本机端口 ${lport} 已被其他服务占用（${conflict}）。"
    echo -e "${C_YELLOW}[警告]${C_RESET} 添加转发后，该端口的外部流量将被转发，本地服务可能无法从外部访问。"
    read -rp "是否仍要继续添加转发规则？[y/N]: " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
      echo -e "${C_GREEN}[信息]${C_RESET} 已取消。"
      return
    fi
  fi
  local dip
  while true; do
    read -rp "请输入目标 IP 地址: " dip
    if _nft_validate_ip "$dip"; then break; fi
    echo -e "${C_RED}[错误]${C_RESET} IP 地址格式无效，请重新输入（如 192.168.1.100，不含前导零）。"
  done
  local dport
  while true; do
    read -rp "请输入目标端口 (1-65535) [默认: ${lport}]: " dport
    dport="${dport:-$lport}"
    if _nft_validate_port "$dport"; then break; fi
    echo -e "${C_RED}[错误]${C_RESET} 端口无效，请输入 1-65535 之间的数字。"
  done
  local comment
  read -rp "请输入备注（可选，直接回车跳过）: " comment
  # 备注中不允许包含管道符，避免破坏分隔格式
  comment="${comment//|/}"
  # 询问是否限制转发来源 IP
  local src_ip=""
  echo ""
  echo "是否限制转发来源 IP？（留空表示允许所有来源）"
  echo "  支持单个 IP (如 1.2.3.4) 或 CIDR 网段 (如 10.0.0.0/8)"
  read -rp "请输入来源 IP [默认 any]: " src_ip
  src_ip="${src_ip// /}"
  if [[ -n "$src_ip" ]] && ! _validate_ip_or_cidr "$src_ip"; then
    echo -e "${C_RED}[错误]${C_RESET} IP 地址/网段格式无效，将不限制来源。"
    src_ip=""
  fi
  echo ""
  echo "即将添加转发规则:"
  echo "  本机端口 ${lport} (tcp+udp) → ${dip}:${dport}"
  [[ -n "$comment" ]] && echo "  备注: ${comment}"
  [[ -n "$src_ip" ]] && echo "  来源限制: ${src_ip}"
  read -rp "确认添加？[Y/n]: " confirm
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} 已取消。"
    return
  fi
  NFT_RULES+=("${lport}|${dip}|${dport}|${comment}|${src_ip}")
  if ! _nft_save_and_reload; then return; fi
  _nft_firewall_port open "$lport" "$dip" "$dport" "$src_ip"
  echo -e "${C_GREEN}[信息]${C_RESET} 转发规则添加成功: ${lport} → ${dip}:${dport}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 新增转发: ${lport} -> ${dip}:${dport}${comment:+ (${comment})}${src_ip:+ [来源: ${src_ip}]}" >> "$NFT_LOG_FILE" 2>/dev/null || true
  echo -e "${C_GREEN}[信息]${C_RESET} 若转发不通，请使用菜单中的【诊断/自检】排查。"
}

_nft_do_delete() {
  echo ""
  if ! command -v nft &>/dev/null; then
    echo -e "${C_RED}[错误]${C_RESET} nftables 未安装，请先选择 [1] 安装。"
    return
  fi
  _nft_load_rules
  if [[ ${#NFT_RULES[@]} -eq 0 ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} 当前没有端口转发规则，无需删除。"
    return
  fi
  printf "\n\033[1m%-8s %-12s %-14s    %-26s  %-22s  %s\033[0m\n" "序号" "协议" "本机端口" "目标地址" "来源限制" "备注"
  echo "──────────────────────────────────────────────────────────────────────────────────────"
  local idx=1 rule lport dip dport comment src_ip
  for rule in "${NFT_RULES[@]}"; do
    IFS='|' read -r lport dip dport comment src_ip <<< "$rule"
    printf "%-6s %-10s %-10s -> %-22s  %-18s  %s\n" "$idx" "tcp+udp" "$lport" "${dip}:${dport}" "${src_ip:-any}" "$comment"
    ((idx++))
  done
  echo ""
  local choice
  read -rp "请输入要删除的序号 (0 取消): " choice
  if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} 已取消。"
    return
  fi
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#NFT_RULES[@]} )); then
    echo -e "${C_RED}[错误]${C_RESET} 无效的序号。"
    return
  fi
  local target="${NFT_RULES[$((choice-1))]}"
  IFS='|' read -r lport dip dport comment src_ip <<< "$target"
  echo "即将删除转发规则:"
  echo "  本机端口 ${lport} (tcp+udp) → ${dip}:${dport}"
  [[ -n "$comment" ]] && echo "  备注: ${comment}"
  [[ -n "$src_ip" ]] && echo "  来源限制: ${src_ip}"
  read -rp "确认删除？[Y/n]: " confirm
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} 已取消。"
    return
  fi
  unset 'NFT_RULES[$((choice-1))]'
  NFT_RULES=("${NFT_RULES[@]}")
  if ! _nft_save_and_reload; then return; fi
  _nft_firewall_port close "$lport" "$dip" "$dport" "$src_ip"
  echo -e "${C_GREEN}[信息]${C_RESET} 转发规则已删除: ${lport} → ${dip}:${dport}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 删除转发: ${lport} -> ${dip}:${dport}${comment:+ (${comment})}${src_ip:+ [来源: ${src_ip}]}" >> "$NFT_LOG_FILE" 2>/dev/null || true
}

_nft_do_clear_all() {
  echo ""
  if ! command -v nft &>/dev/null; then
    echo -e "${C_RED}[错误]${C_RESET} nftables 未安装，请先选择 [1] 安装。"
    return
  fi
  _nft_load_rules
  if [[ ${#NFT_RULES[@]} -eq 0 ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} 当前没有端口转发规则，无需清空。"
    return
  fi
  echo -e "${C_YELLOW}[警告]${C_RESET} 即将清空全部 ${#NFT_RULES[@]} 条转发规则！"
  read -rp "确认清空？[y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} 已取消。"
    return
  fi
  local rule lport dip dport comment src_ip
  for rule in "${NFT_RULES[@]}"; do
    IFS='|' read -r lport dip dport comment src_ip <<< "$rule"
    _nft_firewall_port close "$lport" "$dip" "$dport" "$src_ip" "force"
  done
  NFT_RULES=()
  if ! _nft_save_and_reload; then return; fi
  echo -e "${C_GREEN}[信息]${C_RESET} 所有转发规则已清空。"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 清空所有转发规则" >> "$NFT_LOG_FILE" 2>/dev/null || true
}

_nft_do_edit_comment() {
  echo ""
  if ! command -v nft &>/dev/null; then
    echo -e "${C_RED}[错误]${C_RESET} nftables 未安装，请先选择 [1] 安装。"
    return
  fi
  _nft_load_rules
  if [[ ${#NFT_RULES[@]} -eq 0 ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} 当前没有端口转发规则。"
    return
  fi
  printf "\n\033[1m%-8s %-12s %-14s    %-26s  %-22s  %s\033[0m\n" "序号" "协议" "本机端口" "目标地址" "来源限制" "备注"
  echo "──────────────────────────────────────────────────────────────────────────────────────"
  local idx=1 rule lport dip dport comment src_ip
  for rule in "${NFT_RULES[@]}"; do
    IFS='|' read -r lport dip dport comment src_ip <<< "$rule"
    printf "%-6s %-10s %-10s -> %-22s  %-18s  %s\n" "$idx" "tcp+udp" "$lport" "${dip}:${dport}" "${src_ip:-any}" "$comment"
    ((idx++))
  done
  echo ""
  local choice
  read -rp "请输入要修改备注的序号 (0 取消): " choice
  if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} 已取消。"
    return
  fi
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#NFT_RULES[@]} )); then
    echo -e "${C_RED}[错误]${C_RESET} 无效的序号。"
    return
  fi
  local target="${NFT_RULES[$((choice-1))]}"
  IFS='|' read -r lport dip dport comment src_ip <<< "$target"
  if [[ -n "$comment" ]]; then
    echo "当前备注: ${comment}"
  else
    echo "当前无备注"
  fi
  local new_comment
  read -rp "请输入新备注（留空则清除备注）: " new_comment
  new_comment="${new_comment//|/}"
  NFT_RULES[$((choice-1))]="${lport}|${dip}|${dport}|${new_comment}|${src_ip}"
  if ! _nft_save_and_reload; then return; fi
  if [[ -n "$new_comment" ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} 备注已更新: ${lport} → ${dip}:${dport} (${new_comment})"
  else
    echo -e "${C_GREEN}[信息]${C_RESET} 备注已清除: ${lport} → ${dip}:${dport}"
  fi
}

# ============================================================
#  UFW 与 nftables 转发规则同步检查
# ============================================================
_nft_ufw_delete_related() {
  local lport="$1" dip="$2" dport="$3"
  local esc_dip="${dip//./\\.}"
  local numbered
  numbered=$(ufw status numbered 2>/dev/null) || return

  local -a del_nums=()
  local line num
  while IFS= read -r line; do
    [[ "$line" =~ ^\[\ *([0-9]+)\] ]] || continue
    num="${BASH_REMATCH[1]}"
    # IN 规则: 匹配本机端口 (如 12340, 12340/tcp, 12340/udp)
    if echo "$line" | grep -v "ALLOW FWD" | grep -qE "^\[.*\][[:space:]]+${lport}(/[a-z]+)?[[:space:]]+ALLOW"; then
      del_nums+=("$num")
    # FWD 规则: 匹配目标地址 (如 23.249.27.138 1234/tcp)
    elif echo "$line" | grep -qE "^\[.*\][[:space:]]+${esc_dip} ${dport}/(tcp|udp)[[:space:]]+ALLOW FWD"; then
      del_nums+=("$num")
    fi
  done <<< "$numbered"

  # 从大到小删除，避免编号偏移
  local i
  for (( i=${#del_nums[@]}-1; i>=0; i-- )); do
    yes | ufw delete "${del_nums[$i]}" >/dev/null 2>&1 || true
  done
}

_nft_check_ufw_sync() {
  # 仅在 UFW 激活时检查
  if ! command -v ufw &>/dev/null || ! ufw status 2>/dev/null | grep -qw "active"; then
    return
  fi
  [[ ${#NFT_RULES[@]} -eq 0 ]] && return

  echo ""
  echo "--- UFW 规则同步检查 ---"

  # 获取 UFW 规则（排除 v6 和表头）
  local ufw_rules
  ufw_rules=$(ufw status 2>/dev/null | grep "ALLOW" | grep -v '(v6)' || true)

  local rule lport dip dport comment src_ip
  local has_mismatch=false
  local -a fix_rules=()

  for rule in "${NFT_RULES[@]}"; do
    IFS='|' read -r lport dip dport comment src_ip <<< "$rule"
    local issues=""
    local esc_dip="${dip//./\\.}"

    # 提取该端口的 IN 规则（排除 FWD）
    local port_in_rules
    port_in_rules=$(echo "$ufw_rules" | grep -v "ALLOW FWD" | grep -E "^${lport}(/[a-z]+)?[[:space:]]+" || true)

    if [[ -n "$src_ip" ]]; then
      local esc_src="${src_ip//./\\.}"
      # 期望: 有来源限制的 IN 规则
      if ! echo "$port_in_rules" | grep -qE "${esc_src}"; then
        issues+="缺少IN规则(需要来源${src_ip}); "
      fi
      # 检查是否存在不应有的无限制 IN 规则
      if echo "$port_in_rules" | grep -q "Anywhere"; then
        issues+="存在多余的无限制IN规则; "
      fi
      # 期望: 有来源限制的 FWD 规则
      if ! echo "$ufw_rules" | grep -qE "${esc_dip} ${dport}/(tcp|udp)[[:space:]]+ALLOW FWD.*${esc_src}"; then
        issues+="缺少FWD规则(需要来源${src_ip}); "
      fi
    else
      # 期望: 无限制的 IN 规则
      if ! echo "$port_in_rules" | grep -q "Anywhere"; then
        issues+="缺少IN规则; "
      fi
      # 检查是否存在不应有的来源限制 IN 规则
      if echo "$port_in_rules" | grep -qv "Anywhere" | grep -q .; then
        issues+="存在多余的来源限制IN规则; "
      fi
      # 期望: 无限制的 FWD 规则
      if ! echo "$ufw_rules" | grep -qE "${esc_dip} ${dport}/(tcp|udp)[[:space:]]+ALLOW FWD.*Anywhere"; then
        issues+="缺少FWD规则; "
      fi
    fi

    if [[ -n "$issues" ]]; then
      has_mismatch=true
      echo -e "  ${C_YELLOW}[不匹配]${C_RESET} ${lport} → ${dip}:${dport} (nftables来源: ${src_ip:-any})"
      echo "           ${issues}"
      fix_rules+=("$rule")
    else
      echo -e "  ${C_GREEN}[匹配]${C_RESET} ${lport} → ${dip}:${dport} (来源: ${src_ip:-any})"
    fi
  done

  if $has_mismatch; then
    echo ""
    read -rp "是否自动修复不匹配的 UFW 规则？[y/N]: " fix_ans
    if [[ "$fix_ans" =~ ^[Yy]$ ]]; then
      # 收集需要重建 FWD 规则的目标（删除后需从所有 nftables 规则重建）
      local -A fix_dests=()
      local r
      for r in "${fix_rules[@]}"; do
        IFS='|' read -r lport dip dport comment src_ip <<< "$r"
        echo -e "  修复: ${lport} → ${dip}:${dport} (来源: ${src_ip:-any}) ..."
        fix_dests["${dip}|${dport}"]=1
        # 删除该端口和目标的所有 UFW 规则
        _nft_ufw_delete_related "$lport" "$dip" "$dport"
        # 添加正确的 IN 规则
        if [[ -n "$src_ip" ]]; then
          ufw allow from "$src_ip" to any port "${lport}" proto tcp >/dev/null 2>&1 || true
          ufw allow from "$src_ip" to any port "${lport}" proto udp >/dev/null 2>&1 || true
        else
          ufw allow "${lport}/tcp" >/dev/null 2>&1 || true
          ufw allow "${lport}/udp" >/dev/null 2>&1 || true
        fi
      done
      # 重建受影响目标的 FWD 规则（从所有 nftables 规则中，避免遗漏共享目标的规则）
      local dest _lp _di _dp _c _si
      for dest in "${!fix_dests[@]}"; do
        IFS='|' read -r _di _dp <<< "$dest"
        for r in "${NFT_RULES[@]}"; do
          IFS='|' read -r _lp _di2 _dp2 _c _si <<< "$r"
          if [[ "$_di2" == "$_di" && "$_dp2" == "$_dp" ]]; then
            if [[ -n "$_si" ]]; then
              ufw route allow proto tcp from "$_si" to "${_di}" port "${_dp}" >/dev/null 2>&1 || true
              ufw route allow proto udp from "$_si" to "${_di}" port "${_dp}" >/dev/null 2>&1 || true
            else
              ufw route allow proto tcp to "${_di}" port "${_dp}" >/dev/null 2>&1 || true
              ufw route allow proto udp to "${_di}" port "${_dp}" >/dev/null 2>&1 || true
            fi
          fi
        done
      done
      echo ""
      echo -e "${C_GREEN}[信息]${C_RESET} UFW 规则同步修复完成。"
    fi
  else
    echo -e "  ${C_GREEN}[信息]${C_RESET} 所有转发规则与 UFW 配置一致"
  fi
}

_nft_do_diagnose() {
  echo ""
  echo "========================================"
  echo "           诊断 / 自检"
  echo "========================================"
  local ip_fwd
  ip_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || ip_fwd="未知"
  if [[ "$ip_fwd" == "1" ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} IPv4 转发: 已开启"
  else
    echo -e "${C_RED}[错误]${C_RESET} IPv4 转发: 未开启 (当前值: ${ip_fwd})"
    echo "  → 修复: 选择菜单【安装 nftables】会自动开启"
  fi
  if command -v nft &>/dev/null; then
    echo -e "${C_GREEN}[信息]${C_RESET} nftables: 已安装 ($(nft --version 2>/dev/null || echo '未知版本'))"
  else
    echo -e "${C_RED}[错误]${C_RESET} nftables: 未安装"
    echo "  → 修复: 选择菜单【安装 nftables】"
  fi
  local svc_enabled svc_active
  svc_enabled=$(systemctl is-enabled nftables 2>/dev/null) || svc_enabled="unknown"
  svc_active=$(systemctl is-active nftables 2>/dev/null) || svc_active="unknown"
  if [[ "$svc_enabled" == "enabled" ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} nftables 开机启动: 是"
  else
    echo -e "${C_YELLOW}[警告]${C_RESET} nftables 开机启动: 否（重启后规则可能丢失）"
    echo "  → 修复: systemctl enable nftables"
  fi
  if [[ "$svc_active" == "active" ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} nftables 服务状态: 运行中"
  else
    echo -e "${C_YELLOW}[警告]${C_RESET} nftables 服务状态: 未运行"
    echo "  → 修复: systemctl start nftables"
  fi
  if nft list table ip "$NFT_TABLE_NAME" &>/dev/null; then
    _nft_load_rules
    echo -e "${C_GREEN}[信息]${C_RESET} 转发规则表: 已加载（${#NFT_RULES[@]} 条转发规则）"
  else
    echo -e "${C_YELLOW}[警告]${C_RESET} 转发规则表: 未加载（可能无规则或服务未启动）"
  fi
  echo ""
  echo "--- 防火墙状态 ---"
  local fw_found=false
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    fw_found=true
    echo -e "${C_GREEN}[信息]${C_RESET} firewalld: 活跃"
  fi
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
    fw_found=true
    echo -e "${C_YELLOW}[警告]${C_RESET} UFW: 活跃（默认会阻止入站连接，可能影响转发）"
  fi
  if ! $fw_found && command -v iptables &>/dev/null && iptables -S &>/dev/null; then
    fw_found=true
    local fwd_policy
    fwd_policy=$(iptables -S FORWARD 2>/dev/null | grep -- '^-P FORWARD' | awk '{print $3}') || fwd_policy=""
    if [[ "$fwd_policy" == "DROP" || "$fwd_policy" == "REJECT" ]]; then
      echo -e "${C_YELLOW}[警告]${C_RESET} iptables FORWARD 默认策略: ${fwd_policy}（可能阻止转发流量）"
    else
      echo -e "${C_GREEN}[信息]${C_RESET} iptables FORWARD 默认策略: ${fwd_policy:-ACCEPT}"
    fi
  fi
  if ! $fw_found; then
    echo -e "${C_GREEN}[信息]${C_RESET} 未检测到活跃的防火墙 (firewalld / UFW / iptables)"
  fi
  echo ""
  echo "--- nftables forward 链 ---"
  local fwd_chains
  fwd_chains=$(nft list chains 2>/dev/null | grep -B1 "hook forward" || true)
  if [[ -n "$fwd_chains" ]]; then
    if echo "$fwd_chains" | grep -qi "drop"; then
      echo -e "${C_YELLOW}[警告]${C_RESET} 检测到 nftables 存在 forward 链默认策略为 drop"
      echo "  这会阻止所有转发流量，需手动添加放行规则。"
      echo "  查看详情: nft list ruleset | grep -A5 'hook forward'"
    else
      echo -e "${C_GREEN}[信息]${C_RESET} nftables forward 链: 未发现 drop 策略"
    fi
  else
    echo -e "${C_GREEN}[信息]${C_RESET} 未检测到 nftables forward 链（正常，不影响转发）"
  fi
  echo ""
  echo "--- 配置持久化 ---"
  if [[ -f "$NFT_MAIN_CONF" ]]; then
    if grep -qF 'include "/etc/nftables.d/*.conf"' "$NFT_MAIN_CONF" 2>/dev/null; then
      echo -e "${C_GREEN}[信息]${C_RESET} 主配置 ${NFT_MAIN_CONF}: 已包含 include 指令"
    else
      echo -e "${C_YELLOW}[警告]${C_RESET} 主配置 ${NFT_MAIN_CONF}: 缺少 include 指令（重启后规则可能丢失）"
      echo "  → 修复: 选择菜单【安装 nftables】会自动添加"
    fi
  else
    echo -e "${C_YELLOW}[警告]${C_RESET} 主配置 ${NFT_MAIN_CONF}: 不存在（重启后规则可能丢失）"
    echo "  → 修复: 选择菜单【安装 nftables】会自动创建"
  fi
  if [[ -f "$NFT_CONF_FILE" ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} 转发配置文件: ${NFT_CONF_FILE} 存在"
  else
    echo -e "${C_GREEN}[信息]${C_RESET} 转发配置文件: 尚未创建（添加首条规则时自动生成）"
  fi
  echo ""
  _nft_load_rules
  # UFW 规则同步检查
  _nft_check_ufw_sync
  if [[ ${#NFT_RULES[@]} -gt 0 ]]; then
    echo ""
    read -rp "是否测试目标连通性？[y/N]: " test_conn
    if [[ "$test_conn" =~ ^[Yy]$ ]]; then
      local rule lport dip dport comment src_ip
      for rule in "${NFT_RULES[@]}"; do
        IFS='|' read -r lport dip dport comment src_ip <<< "$rule"
        printf "  测试 %s:%s (TCP) ... " "$dip" "$dport"
        if timeout 3 bash -c ">/dev/tcp/${dip}/${dport}" 2>/dev/null; then
          printf "${C_GREEN}通${C_RESET}\n"
        else
          printf "${C_RED}不通或超时${C_RESET}\n"
        fi
      done
    fi
  fi
  echo ""
}

# --- 导出规则 ---
_export_rules() {
  local default_file="/root/vps-rules-$(hostname)-$(date '+%Y%m%d%H%M%S').conf"
  local export_file
  read -rp "导出文件路径 [默认: ${default_file}]: " export_file
  export_file="${export_file:-$default_file}"

  # 确保目标目录存在
  local export_dir
  export_dir="$(dirname "$export_file")"
  if [[ ! -d "$export_dir" ]]; then
    echo -e "${C_RED}[错误]${C_RESET} 目录不存在: ${export_dir}"
    return 1
  fi

  {
    echo "# VPS Tools 规则导出"
    echo "# 导出时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# 主机名: $(hostname)"
    echo ""

    # 导出 nftables 转发规则
    echo "[nftables]"
    echo "# 格式: 本机端口|目标IP|目标端口|备注|来源IP限制"
    if command -v nft &>/dev/null && [[ -f "$NFT_CONF_FILE" ]]; then
      _nft_load_rules
      for rule in "${NFT_RULES[@]}"; do
        echo "$rule"
      done
    fi
    echo ""

    # 导出 UFW 规则
    echo "[ufw]"
    echo "# 格式: ufw 命令（可直接执行恢复）"
    if command -v ufw &>/dev/null; then
      # ufw show added 输出可直接回放的命令
      ufw show added 2>/dev/null | grep "^ufw " | grep -v "^ufw logging" || true
    fi
  } > "$export_file"

  echo ""
  echo -e "${C_GREEN}[信息]${C_RESET} 规则已导出到: ${export_file}"
  echo ""

  # 统计并显示
  local nft_count ufw_count
  nft_count=$(grep -c "^[0-9]" "$export_file" 2>/dev/null || echo 0)
  ufw_count=$(grep -c "^ufw " "$export_file" 2>/dev/null || echo 0)
  echo "  nftables 转发规则: ${nft_count} 条"
  echo "  UFW 规则: ${ufw_count} 条"
  echo ""
  echo "文件内容预览:"
  echo "─────────────────────────────────────"
  cat "$export_file"
  echo "─────────────────────────────────────"
}

# --- 导入规则 ---
_import_rules() {
  local import_file
  read -rp "导入文件路径: " import_file

  if [[ ! -f "$import_file" ]]; then
    echo -e "${C_RED}[错误]${C_RESET} 文件不存在: ${import_file}"
    return 1
  fi

  # 解析文件内容
  local section="" line
  local -a nft_import_rules=()
  local -a ufw_import_cmds=()

  while IFS= read -r line; do
    # 跳过注释和空行
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue

    if [[ "$line" == "[nftables]" ]]; then
      section="nftables"; continue
    elif [[ "$line" == "[ufw]" ]]; then
      section="ufw"; continue
    fi

    case "$section" in
      nftables) nft_import_rules+=("$line") ;;
      ufw)      ufw_import_cmds+=("$line") ;;
    esac
  done < "$import_file"

  local nft_count=${#nft_import_rules[@]}
  local ufw_count=${#ufw_import_cmds[@]}

  if [[ $nft_count -eq 0 && $ufw_count -eq 0 ]]; then
    echo -e "${C_YELLOW}[警告]${C_RESET} 文件中没有可导入的规则。"
    return
  fi

  # 显示即将导入的内容
  echo ""
  echo "即将导入以下规则:"
  echo ""

  if [[ $nft_count -gt 0 ]]; then
    echo -e "  ${C_CYAN}nftables 转发规则 (${nft_count} 条):${C_RESET}"
    local rule lport dip dport comment src_ip
    for rule in "${nft_import_rules[@]}"; do
      IFS='|' read -r lport dip dport comment src_ip <<< "$rule"
      printf "    %-8s → %-22s" "$lport" "${dip}:${dport}"
      [[ -n "$src_ip" ]] && printf "  [来源: %s]" "$src_ip"
      [[ -n "$comment" ]] && printf "  (%s)" "$comment"
      echo ""
    done
    echo ""
  fi

  if [[ $ufw_count -gt 0 ]]; then
    echo -e "  ${C_CYAN}UFW 规则 (${ufw_count} 条):${C_RESET}"
    for cmd in "${ufw_import_cmds[@]}"; do
      echo "    ${cmd}"
    done
    echo ""
  fi

  read -rp "确认导入？[Y/n]: " confirm
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo -e "${C_GREEN}[信息]${C_RESET} 已取消。"
    return
  fi

  # ---- 导入 nftables 转发规则 ----
  if [[ $nft_count -gt 0 ]]; then
    echo ""
    echo -e "${C_CYAN}--- 导入 nftables 转发规则 ---${C_RESET}"
    if ! command -v nft &>/dev/null; then
      echo -e "${C_RED}[错误]${C_RESET} nftables 未安装，请先选择菜单【安装 nftables】。"
    else
      _nft_init_conf
      _nft_setup_kernel
      _nft_load_rules

      local added=0
      for rule in "${nft_import_rules[@]}"; do
        IFS='|' read -r lport dip dport comment src_ip <<< "$rule"

        # 检查端口是否重复
        local dup=0
        for existing in "${NFT_RULES[@]}"; do
          local elport
          IFS='|' read -r elport _ _ _ _ <<< "$existing"
          if [[ "$elport" == "$lport" ]]; then
            echo -e "${C_YELLOW}[跳过]${C_RESET} 端口 ${lport} 已存在转发规则"
            dup=1
            break
          fi
        done

        if [[ $dup -eq 0 ]]; then
          NFT_RULES+=("${rule}")
          echo -e "${C_GREEN}[添加]${C_RESET} ${lport} → ${dip}:${dport}${src_ip:+ [来源: ${src_ip}]}"
          ((added++))
        fi
      done

      if [[ $added -gt 0 ]]; then
        if _nft_save_and_reload; then
          # 为所有导入的规则开放防火墙端口（已存在的会被防火墙自动跳过）
          for rule in "${nft_import_rules[@]}"; do
            IFS='|' read -r lport dip dport comment src_ip <<< "$rule"
            _nft_firewall_port open "$lport" "$dip" "$dport" "$src_ip"
          done
          echo -e "${C_GREEN}[信息]${C_RESET} nftables 转发规则导入完成 (新增 ${added} 条)"
        fi
      else
        echo -e "${C_GREEN}[信息]${C_RESET} 没有新增的 nftables 规则（全部已存在）"
      fi
    fi
  fi

  # ---- 导入 UFW 规则 ----
  if [[ $ufw_count -gt 0 ]]; then
    echo ""
    echo -e "${C_CYAN}--- 导入 UFW 规则 ---${C_RESET}"
    if ! command -v ufw &>/dev/null; then
      echo -e "${C_RED}[错误]${C_RESET} UFW 未安装，请先安装。"
    else
      local ufw_added=0 ufw_skipped=0
      for cmd in "${ufw_import_cmds[@]}"; do
        # 安全检查：只执行以 "ufw " 开头的命令
        if [[ ! "$cmd" =~ ^ufw\ (allow|deny|reject|limit|route) ]]; then
          echo -e "${C_YELLOW}[跳过]${C_RESET} 非法命令: ${cmd}"
          ((ufw_skipped++))
          continue
        fi
        # 执行并检查是否为已存在规则
        local output
        output=$(eval "$cmd" 2>&1) || true
        if [[ "$output" == *"Skipping"* || "$output" == *"existing"* ]]; then
          echo -e "${C_YELLOW}[跳过]${C_RESET} 已存在: ${cmd}"
          ((ufw_skipped++))
        else
          echo -e "${C_GREEN}[添加]${C_RESET} ${cmd}"
          ((ufw_added++))
        fi
      done
      echo -e "${C_GREEN}[信息]${C_RESET} UFW 规则导入完成 (新增 ${ufw_added} 条, 跳过 ${ufw_skipped} 条)"
    fi
  fi

  echo ""
  echo -e "${C_GREEN}[信息]${C_RESET} 全部规则导入完成。"
}

# --- 导出/导入菜单 ---
_nft_do_export_import() {
  while true; do
    echo -e "\n${C_BOLD_WHITE}━━━━━━━━━━ 导出/导入规则配置 ━━━━━━━━━━${C_RESET}\n"
    echo " 1) 导出当前规则 (nftables + UFW)"
    echo " 2) 从文件导入规则"
    echo " 0) 返回上级菜单"
    echo ""
    local ei_choice
    read -rp "请选择操作 [0-2]: " ei_choice
    case "$ei_choice" in
      1) _export_rules ;;
      2) _import_rules ;;
      0) return 0 ;;
      *) echo -e "${C_RED}[错误]${C_RESET} 无效选择。" ;;
    esac
  done
}

do_nft_forward() {
  while true; do
    echo -e "\n${C_BOLD_WHITE}━━━━━━━━━━ 端口转发 (nftables) ━━━━━━━━━━${C_RESET}\n"
    echo " 1) 安装 nftables"
    echo " 2) 查看现有端口转发"
    echo " 3) 新增端口转发"
    echo " 4) 删除端口转发"
    echo " 5) 修改规则备注"
    echo " 6) 一键清空所有转发"
    echo " 7) 诊断/自检"
    echo " 8) 导出/导入规则配置"
    echo " 0) 返回主菜单"
    echo ""
    local nft_choice
    read -rp "请选择操作 [0-8]: " nft_choice
    case "$nft_choice" in
      1) _nft_do_install ;;
      2) _nft_do_list ;;
      3) _nft_do_add ;;
      4) _nft_do_delete ;;
      5) _nft_do_edit_comment ;;
      6) _nft_do_clear_all ;;
      7) _nft_do_diagnose ;;
      8) _nft_do_export_import ;;
      0) return 0 ;;
      *) echo -e "${C_RED}[错误]${C_RESET} 无效选择，请输入 0-8。" ;;
    esac
  done
}

# ============================================================
#  10) 修改主机名
# ============================================================
do_change_hostname() {
  local current_hostname
  current_hostname=$(hostname)
  echo -e "${C_CYAN}=== 修改主机名 ===${C_RESET}"
  echo ""
  echo -e "当前主机名: ${C_BOLD_WHITE}${current_hostname}${C_RESET}"
  echo ""

  local new_hostname
  read -rp "请输入新的主机名 (留空取消): " new_hostname

  # 留空取消
  if [[ -z "$new_hostname" ]]; then
    echo "已取消"
    return 0
  fi

  # 校验主机名格式: 仅允许字母、数字、连字符，不能以连字符开头或结尾
  if ! [[ "$new_hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    echo -e "${C_CYAN}主机名格式无效${C_RESET}"
    echo "规则: 仅允许字母、数字、连字符，不能以连字符开头或结尾，最长63字符"
    return 1
  fi

  echo ""
  read -rp "确认将主机名修改为 '${new_hostname}'? [y/N]: " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "已取消"
    return 0
  fi

  # 使用 hostnamectl 设置主机名
  if command -v hostnamectl &>/dev/null; then
    hostnamectl set-hostname "$new_hostname"
  else
    echo "$new_hostname" > /etc/hostname
    hostname "$new_hostname"
  fi

  # 更新 /etc/hosts 中旧主机名的映射
  if grep -q "$current_hostname" /etc/hosts; then
    sed -i "s/$current_hostname/$new_hostname/g" /etc/hosts
  fi

  echo ""
  echo -e "${C_CYAN}主机名已修改为:${C_RESET} ${C_BOLD_WHITE}$(hostname)${C_RESET}"
}

# ============================================================
#  主菜单
# ============================================================
show_menu() {
  echo ""
  echo -e "${C_CYAN}=========================================${C_RESET}"
  echo -e "${C_BOLD_WHITE}         VPS Tools v1.0${C_RESET}"
  echo -e "${C_CYAN}=========================================${C_RESET}"
  echo " 1) SSH 安全加固"
  echo " 2) 修改主机名"
  echo " 3) 系统更新"
  echo " 4) 安装Nezha探针 (Nezha Agent)"
  echo " 5) Snell 安装"
  echo " 6) 防火墙管理"
  echo " 7) 端口转发 (nftables)"
  echo " 8) 服务器质量检测 (NodeQuality)"
  echo " 9) Cloudflare 测速"
  echo " 10) 清理备份文件"
  echo " 0) 退出"
  echo -e "${C_CYAN}=========================================${C_RESET}"
}

main() {
  while true; do
    show_menu
    read -rp "请输入选项 [0-10]: " choice
    echo ""
    case "$choice" in
      1) require_root && do_ssh_harden || true ;;
      2) require_root && do_change_hostname || true ;;
      3) require_root && do_system_update || true ;;
      4) require_root && do_nezha_install || true ;;
      5) require_root && do_snell_install || true ;;
      6) require_root && do_firewall || true ;;
      7) require_root && do_nft_forward || true ;;
      8) do_node_quality || true ;;
      9) do_speedtest || true ;;
      10) require_root && do_cleanup_backups || true ;;
      0) echo "再见！"; exit 0 ;;
      *) echo "无效选项，请重新输入" ;;
    esac
  done
}

main
