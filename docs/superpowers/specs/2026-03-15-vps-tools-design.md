# VPS Tools 设计文档

## 概述

将现有 `cf_test.sh`（Cloudflare 测速脚本）扩展为多功能 VPS 工具箱 `vps_tools.sh`，采用单文件 + 交互式菜单的架构。

## 菜单结构

```
=========================================
         VPS Tools v1.0
=========================================
 1) SSH 安全加固
 2) 系统更新
 3) 安装哈探针 (Nezha Agent)
 4) 服务器质量检测 (NodeQuality)
 5) Snell 安装
 6) Cloudflare 测速
 0) 退出
=========================================
请输入选项 [0-6]:
```

## 整体框架

- **单文件架构**：所有功能在 `vps_tools.sh` 一个文件中，便于 scp/curl 部署
- **入口检测**：除测速外，其他功能需要 root 权限，脚本入口检测并提示
- **菜单循环**：每个功能执行完后回到菜单，可继续选择
- **公共部分**：颜色设置、工具函数保留在顶部

## 功能模块

### 1. SSH 安全加固

**流程：**
1. 提示用户输入新 SSH 端口（提供默认值建议）
2. 提示用户粘贴 SSH 公钥
3. 验证公钥格式（以 `ssh-rsa` / `ssh-ed25519` / `ssh-ecdsa` 等开头）
4. 写入 `~/.ssh/authorized_keys`（创建目录 + 设权限 700/600）
5. 备份 `/etc/ssh/sshd_config`（带时间戳后缀）
6. 修改 `sshd_config`：
   - `Port` → 新端口
   - `PubkeyAuthentication yes`
   - `PasswordAuthentication no`
   - `PermitRootLogin prohibit-password`
7. Ubuntu 特殊处理：
   - 修改 `/lib/systemd/system/ssh.socket` 中的 `ListenStream` 端口
   - 执行 `systemctl daemon-reload`
8. 配置 ufw：
   - `ufw allow <新端口>/tcp`
   - `ufw --force enable`（如果未启用）
9. 重启 sshd 服务
10. 输出醒目提示：请用新端口新开终端测试连接，确认无误后再关闭当前会话

**安全措施：**
- 修改前备份配置文件
- 公钥格式校验
- 不主动断开当前连接，提醒用户先验证

### 2. 系统更新

- 自动检测包管理器（`apt` / `yum` / `dnf`）
- 执行对应更新命令（如 `apt update && apt upgrade -y`）
- 完成后输出更新结果

### 3. 安装哈探针 (Nezha Agent)

- 提示用户粘贴完整安装命令
- 校验命令中是否包含 `NZ_SERVER`、`NZ_CLIENT_SECRET` 关键字段
- 用户确认后执行

### 4. 服务器质量检测 (NodeQuality)

- 执行 `bash <(curl -sL https://run.NodeQuality.com)`
- 无需额外参数

### 5. Snell 安装

- 执行 `bash <(curl -L -s menu.jinqians.com)`
- 无需额外参数（脚本自身有交互菜单）

### 6. Cloudflare 测速

- 现有 `cf_test.sh` 全部逻辑封装进 `do_speedtest()` 函数
- 包含：延迟测试、下载测速、上传测速、终端输出、HTML 报告生成
- 功能和输出不变
