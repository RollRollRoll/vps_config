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

# ── _ssh_cfg_remove_host 测试 ────────────────────────────────
tmpconf3="${TMPDIR_TEST}/config3"

cat > "$tmpconf3" <<'EOF'
Host vps-a
    HostName 1.1.1.1
    User root
    Port 22
    IdentitiesOnly yes
    IdentityFile ~/.ssh/vps-a

Host vps-b
    HostName 2.2.2.2
    User root
    Port 2222
    IdentitiesOnly yes
    IdentityFile ~/.ssh/vps-b
EOF

_ssh_cfg_remove_host "$tmpconf3" "vps-a"

# vps-a 已删除
assert_fail _ssh_cfg_host_exists "$tmpconf3" "vps-a"
# vps-b 仍存在
assert_ok   _ssh_cfg_host_exists "$tmpconf3" "vps-b"
# 备份文件存在
ls "${tmpconf3}.bak."* >/dev/null 2>&1 || { printf 'FAIL: backup not found\n' >&2; exit 1; }
printf 'PASS: backup file created\n'

# 删除不存在的 host 不报错
_ssh_cfg_remove_host "$tmpconf3" "nonexistent"
printf 'PASS: remove nonexistent host is no-op\n'

printf 'ssh_cfg_remove_host checks passed\n'

# ── _ssh_cfg_list 测试 ───────────────────────────────────────
tmpconf4="${TMPDIR_TEST}/config4"
touch "$tmpconf4"

# 空文件显示暂无配置
list_out="$(_ssh_cfg_list "$tmpconf4")"
assert_contains "暂无配置" "$list_out" "list empty config"

# 写入两个 Host 块（一个启用代理，一个不启用）
_ssh_cfg_write_block "$tmpconf4" "vps1" "1.1.1.1" "root"   "2222" "~/.ssh/vps1" "1"
_ssh_cfg_write_block "$tmpconf4" "vps2" "2.2.2.2" "ubuntu" "22"   "~/.ssh/vps2" "0"

list_out="$(_ssh_cfg_list "$tmpconf4")"
assert_contains "vps1"        "$list_out" "list shows vps1"
assert_contains "1.1.1.1"     "$list_out" "list shows HostName of vps1"
assert_contains "✓"           "$list_out" "list shows proxy mark"
assert_contains "vps2"        "$list_out" "list shows vps2"
assert_contains "✗"           "$list_out" "list shows no-proxy mark"
assert_contains "共 2 条配置" "$list_out" "list shows count"

# 不含 IdentitiesOnly yes 的普通 Host 块不应出现在列表中
cat >> "$tmpconf4" <<'EOF'

Host unmanaged
    HostName 9.9.9.9
    User root
    Port 22
EOF
list_out="$(_ssh_cfg_list "$tmpconf4")"
assert_not_contains "unmanaged" "$list_out" "list ignores blocks without IdentitiesOnly yes"
assert_contains "共 2 条配置"   "$list_out" "list count unchanged after unmanaged block"

printf 'ssh_cfg_list checks passed\n'

# ── _ssh_cfg_gen_key 测试 ────────────────────────────────────
keydir="${TMPDIR_TEST}/keys"
mkdir -p "$keydir"

_ssh_cfg_gen_key "${keydir}/test_ed25519" "ed25519" ""
[[ -f "${keydir}/test_ed25519" ]]     || { printf 'FAIL: ed25519 private key not created\n' >&2; exit 1; }
[[ -f "${keydir}/test_ed25519.pub" ]] || { printf 'FAIL: ed25519 public key not created\n'  >&2; exit 1; }
perm="$(stat -c '%a' "${keydir}/test_ed25519")"
[[ "$perm" == "600" ]] || { printf 'FAIL: private key perms should be 600, got %s\n' "$perm" >&2; exit 1; }
printf 'PASS: _ssh_cfg_gen_key ed25519 creates key pair with 600 permissions\n'

_ssh_cfg_gen_key "${keydir}/test_rsa" "rsa" ""
[[ -f "${keydir}/test_rsa" ]] || { printf 'FAIL: rsa private key not created\n' >&2; exit 1; }
printf 'PASS: _ssh_cfg_gen_key rsa creates key files\n'

_ssh_cfg_gen_key "${keydir}/test_ecdsa" "ecdsa" ""
[[ -f "${keydir}/test_ecdsa" ]] || { printf 'FAIL: ecdsa private key not created\n' >&2; exit 1; }
printf 'PASS: _ssh_cfg_gen_key ecdsa creates key files\n'

assert_fail _ssh_cfg_gen_key "${keydir}/bad" "invalid_type" ""

printf 'ssh_cfg_gen_key checks passed\n'

# ── _ssh_cfg_import_key 测试 ─────────────────────────────────
priv='-----BEGIN OPENSSH PRIVATE KEY-----
dummyprivkeydata
-----END OPENSSH PRIVATE KEY-----'
pub='ssh-ed25519 AAAAB3NzaC1yc2EAAAADAQABAAAA dummy@test'

_ssh_cfg_import_key "${keydir}/imported" "$priv" "$pub"

[[ -f "${keydir}/imported" ]]     || { printf 'FAIL: imported private key file not created\n' >&2; exit 1; }
[[ -f "${keydir}/imported.pub" ]] || { printf 'FAIL: imported public key file not created\n'  >&2; exit 1; }

priv_perm="$(stat -c '%a' "${keydir}/imported")"
pub_perm="$(stat -c '%a'  "${keydir}/imported.pub")"
[[ "$priv_perm" == "600" ]] || { printf 'FAIL: private key perms %s (expected 600)\n' "$priv_perm" >&2; exit 1; }
[[ "$pub_perm"  == "644" ]] || { printf 'FAIL: public key perms %s (expected 644)\n'  "$pub_perm"  >&2; exit 1; }

grep -q "dummyprivkeydata"  "${keydir}/imported"     || { printf 'FAIL: private key content mismatch\n' >&2; exit 1; }
grep -q "AAAAB3NzaC1yc2E"  "${keydir}/imported.pub" || { printf 'FAIL: public key content mismatch\n'  >&2; exit 1; }
printf 'PASS: _ssh_cfg_import_key saves files with correct permissions and content\n'

printf 'ssh_cfg_import_key checks passed\n'

# ── 静态集成检查 ─────────────────────────────────────────────
grep -q 'do_ssh_config()'      ./vps_tools.sh || { printf 'FAIL: do_ssh_config() not found\n' >&2; exit 1; }
grep -q '_ssh_cfg_do_add()'    ./vps_tools.sh || { printf 'FAIL: _ssh_cfg_do_add() not found\n' >&2; exit 1; }
grep -q '_ssh_cfg_do_delete()' ./vps_tools.sh || { printf 'FAIL: _ssh_cfg_do_delete() not found\n' >&2; exit 1; }
grep -q '12) SSH 客户端配置管理' ./vps_tools.sh || { printf 'FAIL: menu item 12 not found\n' >&2; exit 1; }
grep -q '12) do_ssh_config || true ;;' ./vps_tools.sh || { printf 'FAIL: case 12 not found\n' >&2; exit 1; }
grep -q '请输入选项 \[0-12\]' ./vps_tools.sh || { printf 'FAIL: prompt range not updated\n' >&2; exit 1; }
printf 'menu integration static checks passed\n'

grep -q '12. SSH 客户端配置管理' ./README.md || { printf 'FAIL: README item 12 not found\n' >&2; exit 1; }
printf 'README check passed\n'
