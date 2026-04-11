#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source ./vps_tools.sh

assert_ok() {
  local fn="$1"; shift
  if "$fn" "$@"; then
    printf 'PASS: %s %s\n' "$fn" "$*"
  else
    printf 'FAIL: %s %s\n' "$fn" "$*" >&2; exit 1
  fi
}

assert_fail() {
  local fn="$1"; shift
  if "$fn" "$@"; then
    printf 'FAIL: %s %s should fail\n' "$fn" "$*" >&2; exit 1
  else
    printf 'PASS: %s %s failed as expected\n' "$fn" "$*"
  fi
}

assert_contains() {
  local pattern="$1"
  local input="$2"
  local label="$3"
  if grep -q "$pattern" <<< "$input"; then
    printf 'PASS: %s contains "%s"\n' "$label" "$pattern"
  else
    printf 'FAIL: %s does not contain "%s"\n' "$label" "$pattern" >&2
    printf 'actual output:\n%s\n' "$input" >&2
    exit 1
  fi
}

assert_not_contains() {
  local pattern="$1"
  local input="$2"
  local label="$3"
  if grep -q "$pattern" <<< "$input"; then
    printf 'FAIL: %s should NOT contain "%s"\n' "$label" "$pattern" >&2
    exit 1
  else
    printf 'PASS: %s does not contain "%s"\n' "$label" "$pattern"
  fi
}

# 所有测试使用同一个临时目录，EXIT 时统一清理
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── _ssh_cfg_host_exists 测试 ────────────────────────────────
tmpconf="${TMPDIR_TEST}/config1"
touch "$tmpconf"

# 空文件：任何 host 都找不到
assert_fail _ssh_cfg_host_exists "$tmpconf" "my-vps"

# 写入一个 Host 块
cat > "$tmpconf" <<'EOF'
Host my-vps
    HostName 1.2.3.4
    User root
    Port 2222
    IdentitiesOnly yes
    IdentityFile ~/.ssh/my-vps
EOF

assert_ok   _ssh_cfg_host_exists "$tmpconf" "my-vps"
assert_fail _ssh_cfg_host_exists "$tmpconf" "other-vps"
# 不能误匹配前缀子串
assert_fail _ssh_cfg_host_exists "$tmpconf" "my"

printf 'ssh_cfg_host_exists checks passed\n'

# ── _ssh_cfg_write_block 测试 ────────────────────────────────
tmpconf2="${TMPDIR_TEST}/config2"
touch "$tmpconf2"

# 不启用代理
_ssh_cfg_write_block "$tmpconf2" "dev" "10.0.0.1" "ubuntu" "22" "~/.ssh/dev" "0"
out="$(cat "$tmpconf2")"
assert_contains "^Host dev$"              "$out" "write_block Host"
assert_contains "HostName 10.0.0.1"       "$out" "write_block HostName"
assert_contains "User ubuntu"             "$out" "write_block User"
assert_contains "Port 22"                 "$out" "write_block Port"
assert_contains "IdentitiesOnly yes"      "$out" "write_block IdentitiesOnly"
assert_contains "IdentityFile ~/.ssh/dev" "$out" "write_block IdentityFile"
assert_not_contains "ProxyCommand"        "$out" "write_block no ProxyCommand when use_proxy=0"

# 启用代理
_ssh_cfg_write_block "$tmpconf2" "proxy-vps" "5.6.7.8" "root" "22" "~/.ssh/proxy" "1"
out2="$(cat "$tmpconf2")"
assert_contains "ProxyCommand nc -X 5 -x 127.0.0.1:6153 %h %p" "$out2" "write_block ProxyCommand"

printf 'ssh_cfg_write_block checks passed\n'
