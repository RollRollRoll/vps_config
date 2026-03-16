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

  write_result "MEAS_ID" "$MEAS_ID"
  write_result "TIMESTAMP" "\"$TIMESTAMP\""
  write_result "TARGET" "$BASE"
  write_result "IPV4_FORCED" "yes"

  # 1) Idle latency
  local lat_idle="${tmpdir}/lat_idle.txt"
  latency_collect "${BASE}/__down?bytes=0&measId=${MEAS_ID}" "$LAT_SAMPLES" "$LAT_INTERVAL" "$lat_idle"
  latency_summary "$lat_idle" "IDLE_LAT" "idle latency"

  # 2) Download (+ optional loaded latency during download)
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

  # 3) Upload (+ optional loaded latency during upload)
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

  render_terminal
  render_html
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
  echo " 2) 系统更新"
  echo " 3) 安装Nezha探针 (Nezha Agent)"
  echo " 4) 服务器质量检测 (NodeQuality)"
  echo " 5) Snell 安装"
  echo " 6) 清理备份文件"
  echo " 7) Cloudflare 测速"
  echo " 0) 退出"
  echo -e "${C_CYAN}=========================================${C_RESET}"
}

main() {
  while true; do
    show_menu
    read -rp "请输入选项 [0-7]: " choice
    echo ""
    case "$choice" in
      1) require_root && do_ssh_harden || true ;;
      2) require_root && do_system_update || true ;;
      3) require_root && do_nezha_install || true ;;
      4) do_node_quality || true ;;
      5) require_root && do_snell_install || true ;;
      6) require_root && do_cleanup_backups || true ;;
      7) do_speedtest || true ;;
      0) echo "再见！"; exit 0 ;;
      *) echo "无效选项，请重新输入" ;;
    esac
  done
}

main
