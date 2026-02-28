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
  local label="$2"

  local sorted="${raw}.sorted"
  # raw 文件本身只有数字行；这里仍做一次过滤以防意外
  grep -E '^[0-9]' "$raw" | sort -n > "$sorted" || true

  local n
  n="$(wc -l < "$sorted" | tr -d ' ')"

  if [[ "${n:-0}" -lt 1 ]]; then
    echo "${label}: no samples"
    return 1
  fi

  local min max avg p50 p90 jitter
  min="$(head -n1 "$sorted")"
  max="$(tail -n1 "$sorted")"
  avg="$(awk '{s+=$1} END{printf "%.3f", s/NR}' "$sorted")"

  # nearest-rank percentile: idx = ceil(p * n)
  local p50i p90i
  p50i=$(( (n*50 + 99) / 100 ))
  p90i=$(( (n*90 + 99) / 100 ))
  p50="$(sed -n "${p50i}p" "$sorted")"
  p90="$(sed -n "${p90i}p" "$sorted")"

  # jitter = mean(|x_i - x_{i-1}|)
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

  printf "%s: n=%s min=%sms avg=%sms p50=%sms p90=%sms max=%sms jitter=%sms\n" \
    "$label" "$n" "$min" "$avg" "$p50" "$p90" "$max" "$jitter"
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

  awk -v bytes="$total_bytes" -v ns="$elapsed_ns" 'BEGIN{
    sec=ns/1e9
    printf "download: bytes_per_req=%.0f reqs=%d total=%.0f time=%.3f s avg=%.2f Mbps\n",
           bytes/'"$n"', '"$n"', bytes, sec, bytes*8/1000000/sec
  }'
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

  awk -v bytes="$total_bytes" -v ns="$elapsed_ns" 'BEGIN{
    sec=ns/1e9
    printf "upload:   bytes_per_req=%.0f reqs=%d total=%.0f time=%.3f s avg=%.2f Mbps\n",
           bytes/'"$UP_N"', '"$UP_N"', bytes, sec, bytes*8/1000000/sec
  }'
}

echo "MEAS_ID=${MEAS_ID}"
echo "Target=${BASE} (forced IPv4: yes)"
echo

# 1) Idle latency
lat_idle="${tmpdir}/lat_idle.txt"
latency_collect "${BASE}/__down?bytes=0&measId=${MEAS_ID}" "$LAT_SAMPLES" "$LAT_INTERVAL" "$lat_idle"
latency_summary "$lat_idle" "latency idle"
echo

# 2) Download (+ optional loaded latency during download)
if [[ "$MEASURE_LOADED_LATENCY" == "1" ]]; then
  lat_d="${tmpdir}/lat_dload.txt"
  latency_collect "${BASE}/__down?bytes=0&during=download&measId=${MEAS_ID}" "$LAT_SAMPLES" "$LAT_INTERVAL" "$lat_d" &
  pid_d=$!
fi

download_test "$DL_BYTES" "$DL_N"

if [[ "$MEASURE_LOADED_LATENCY" == "1" ]]; then
  wait "$pid_d" || true
  latency_summary "$lat_d" "latency during download"
fi
echo

# 3) Upload (+ optional loaded latency during upload)
if [[ "$MEASURE_LOADED_LATENCY" == "1" ]]; then
  lat_u="${tmpdir}/lat_uload.txt"
  latency_collect "${BASE}/__down?bytes=0&during=upload&measId=${MEAS_ID}" "$LAT_SAMPLES" "$LAT_INTERVAL" "$lat_u" &
  pid_u=$!
fi

upload_test

if [[ "$MEASURE_LOADED_LATENCY" == "1" ]]; then
  wait "$pid_u" || true
  latency_summary "$lat_u" "latency during upload"
fi
