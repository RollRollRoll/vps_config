#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source ./vps_tools.sh

assert_ok() {
  local fn="$1"
  shift
  if "$fn" "$@"; then
    printf 'PASS: %s %s\n' "$fn" "$*"
  else
    printf 'FAIL: %s %s\n' "$fn" "$*" >&2
    exit 1
  fi
}

assert_fail() {
  local fn="$1"
  shift
  if "$fn" "$@"; then
    printf 'FAIL: %s %s should fail\n' "$fn" "$*" >&2
    exit 1
  else
    printf 'PASS: %s %s failed as expected\n' "$fn" "$*"
  fi
}

assert_ok _desktop_is_supported_os "ubuntu"
assert_ok _desktop_is_supported_os "debian"
assert_fail _desktop_is_supported_os "centos"

assert_ok _desktop_validate_username "rdpuser"
assert_ok _desktop_validate_username "user_01"
assert_fail _desktop_validate_username "root"
assert_fail _desktop_validate_username "bad name"
assert_fail _desktop_validate_username "-dash"

printf 'desktop helper checks passed\n'

grep -q 'do_desktop_remote_setup()' ./vps_tools.sh
grep -q 'xfce4-goodies' ./vps_tools.sh
grep -q 'xorgxrdp' ./vps_tools.sh
grep -q 'startxfce4' ./vps_tools.sh
grep -q 'systemctl enable xrdp' ./vps_tools.sh
grep -q 'systemctl restart xrdp' ./vps_tools.sh

printf 'desktop flow static checks passed\n'

grep -q '11) 安装桌面环境与远程桌面' ./vps_tools.sh
grep -q '请输入选项 \[0-12\]' ./vps_tools.sh
grep -q '11) require_root && do_desktop_remote_setup || true ;;' ./vps_tools.sh
grep -q '11. 桌面环境与远程桌面安装' ./README.md
grep -q '仅支持 `Ubuntu / Debian`' ./README.md

printf 'menu and readme checks passed\n'
