# VPS 基础初始化 Checklist

适用：Debian / Ubuntu（流程对两个发行版均健壮；Ubuntu 预装的包照装，`apt install` 幂等）

> **三条铁律，违反任何一条可能锁死 VPS：**
> 1. **UFW 先于 sshd**：改 SSH 端口前，新端口必须已在 ufw 放行且 `ufw status` 可见。
> 2. **密钥先于禁密码**：`PasswordAuthentication no` 之前，必须已用密钥成功登录过新用户。
> 3. **旧会话不关**：改 sshd 配置后，保持当前会话不断开，新开终端验证新端口 + 密钥登录成功，才允许关闭旧会话。

## 自动化映射

| 步骤 | 执行方式 |
|---|---|
| 0 | 手动（云平台控制台） |
| 1 | 脚本 `01-update.sh` |
| 2 | 脚本 `02-tools.sh` |
| 3 | README 纯命令 |
| 4 | 脚本 `04-user.sh` |
| 5 | 脚本 `05-ufw.sh` |
| 6 | 脚本 `06-ssh.sh` |
| 7 | 脚本 `07-fail2ban.sh` |
| 8 | 脚本 `swap.sh`（已有） |
| 9 | 脚本 `bbr.sh`（待加入仓库） |
| 10 | README 纯命令 |
| 11 | README 提示（自行安装） |
| 12 | 脚本 `verify.sh` |
| 13 | verify 报告 + 手动 Snapshot |

命令见 [README.md](README.md)。

---

[ ] 0. 云平台基础检查
    [ ] `cat /etc/os-release` 确认发行版与版本号
    [ ] CPU / RAM / Disk（`nproc` `free -h` `df -h`）
    [ ] 云平台安全组：记录当前放行规则（后续改 SSH 端口后必须同步改）
    [ ] 创建初始 Snapshot / Backup（锁死时的救命稻草）

[ ] 1. 系统更新
    [ ] `apt update && apt full-upgrade`
    [ ] 检查 `/var/run/reboot-required`，需要则 reboot 后重连再继续

[ ] 2. 基础工具安装（必装）
    [ ] `sudo ca-certificates curl wget gnupg ufw fail2ban unattended-upgrades vim nano unzip htop`
    [ ] vim / nano 二选一，另一台机器上习惯哪个就装哪个
    [ ] 值得装（可选，现场再装很烦）：`jq tmux lsof rsync zip`
    [ ] `git`（要用再装；诊断类工具如 tcpdump/mtr/ncdu 一律用到再装，不预装）

[ ] 3. 系统基础配置
    [ ] hostname
    [ ] timezone（`timedatectl set-timezone Asia/Shanghai`）
    [ ] 时间同步（`timedatectl` 确认 NTP active）

[ ] 4. 创建管理员用户（本步结束前不动 sshd）
    [ ] `adduser <user>`，加入 sudo 组：`usermod -aG sudo <user>`（Debian 无 sudo 组时先 `apt install sudo`）
    [ ] 本地生成 SSH 密钥（如已有则跳过）：`ssh-keygen -t ed25519`
    [ ] 公钥写入新用户 `~/.ssh/authorized_keys`（权限 700 / 600，属主正确）
    [ ] **硬闸门**：新开终端，用新用户 + 密钥登录成功，`sudo -v` 通过
        ——不通过，禁止进入第 6 步

[ ] 5. UFW（必须先于 SSH Hardening）
    [ ] 确定新 SSH 端口（10000–65535 随机取，避开 22 和 2222 等扫描器重点关照的端口）
    [ ] `ufw default deny incoming` / `ufw default allow outgoing`
    [ ] 临时放行 22：`ufw allow 22/tcp`（06 完成前 sshd 仍在 22；06-ssh.sh 闸门确认后自动移除）
    [ ] `ufw allow <新SSH端口>/tcp`
    [ ] `ufw enable`
    [ ] `ufw status` 确认新端口在放行列表中
    [ ] 按需放行业务端口（80/443 等，此时一并处理）

[ ] 6. SSH Hardening
    [ ] 检查干扰项：`ls /etc/ssh/sshd_config.d/`——云镜像常有 `50-cloud-init.conf`
        写着 `PasswordAuthentication yes`；sshd 配置**先出现者优先**，drop-in 覆盖主配置
    [ ] 写 `/etc/ssh/sshd_config.d/01-hardening.conf`（01 前缀抢在 50 之前，拿到优先权）：
        ```
        Port <新端口>
        PermitRootLogin no
        PasswordAuthentication no
        PubkeyAuthentication yes
        AllowUsers <user>
        MaxAuthTries 3
        ```
    [ ] `sshd -t` 语法校验
    [ ] `sshd -T | grep -Ei 'port|passwordauthentication|permitrootlogin'`
        ——验证**实际生效值**，不是看配置文件（防 cloud-init 覆盖）
    [ ] `systemctl reload ssh`
    [ ] **保持旧会话**，新开终端验证：新端口 + 密钥登录 + root 被拒
    [ ] 全部通过后才断开旧会话
    [ ] 同步修改云平台安全组：关闭 22，放行新端口

[ ] 7. Fail2ban
    [ ] `apt install fail2ban`
    [ ] 写 `/etc/fail2ban/jail.local`：
        ```
        [sshd]
        enabled = true
        port = <新SSH端口>
        backend = systemd
        ```
        ——port 不写则默认监听 22，形同虚设；`backend = systemd` 保证
        Debian 12（无 auth.log）与 Ubuntu 24.04+（rsyslog 不保证存在）都工作
    [ ] `systemctl enable --now fail2ban`
    [ ] `fail2ban-client status sshd` 确认 jail 已启动且端口正确

[ ] 8. Swap（由本目录 `swap.sh` 交互式完成）
    [ ] `sudo bash swap.sh`
    [ ] 脚本自动处理：查看/创建 swap 文件、fstab 条目、swappiness
    [ ] 完成后 `free -h` 与 `swapon --show` 确认
    [ ] 重启后再次确认 swap 挂载（fstab 生效）

[ ] 9. BBR
    [ ] `sudo bash bbr.sh`（脚本待加入仓库）
    [ ] `sysctl net.ipv4.tcp_congestion_control` 验证输出为 `bbr`
    [ ] 不执行来路不明的第三方"一键优化脚本"

[ ] 10. 自动安全更新
    [ ] 确认 `unattended-upgrades` 已启用（Ubuntu 默认开，Debian 需装）
    [ ] `cat /etc/apt/apt.conf.d/20auto-upgrades` 确认 Update/Upgrade 均为 "1"
    [ ] 确认自动 reboot 策略（默认不重启，可接受）

[ ] 11. Docker（仅提示，不自动安装）
    [ ] 阅读 README 第 11 步提示：官方仓库安装指引 + docker 组等价 root 的知情提醒
    [ ] 如需安装，自行按官方文档执行
    [ ] 装完后 `docker run --rm hello-world` 验证

[ ] 12. 终检 Checkpoint（运行 `verify.sh`；全部通过才算完成）
    [ ] 新端口 + 密钥登录正常，root 登录被拒，密码认证被拒
    [ ] `ufw status` 规则正确，22 端口从外部不可达
    [ ] 云平台安全组与 ufw 规则一致
    [ ] `fail2ban-client status sshd` 正常
    [ ] `free -h` swap 正常
    [ ] `sysctl net.ipv4.tcp_congestion_control` 为 bbr
    [ ] `timedatectl` 时间正常
    [ ] `df -h` 磁盘正常

[ ] 13. 记录归档
    [ ] 确认 `/root/vps-init-report.md` 已生成（含端口 / 用户 / 放行端口 / 关键参数）
    [ ] 创建最终 Snapshot
