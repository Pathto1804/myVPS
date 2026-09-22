# myVPS 实现设计文档

- 状态：**待审阅**（2026-09-22）
- 审阅通过后按本文档逐脚本实现，实现中不偏离契约；发现契约问题先回来改文档。
- 术语以 [CONTEXT.md](../CONTEXT.md) 为准；架构决策见 [adr/0001-no-orchestrator.md](adr/0001-no-orchestrator.md)。

## 1. 总体形态

- 7 个新脚本 + 现有 `swap.sh` + 后期加入的 `bbr.sh`，仓库根目录平铺，文件名沿用 checklist 步骤号。
- 每个脚本自包含、幂等、中文交互（swap.sh 风格），单独 raw 拉取即可执行。
- 人是编排器：README 提供命令，checklist.md 提供顺序与勾选。
- 无状态文件：一切"进行到哪了"的判断都来自系统真实状态。

## 2. 公共内联块

每个脚本头部包含**内容完全一致**的内联块（约 50 行，实现时先写好一份，复制进各脚本，最后自查一致性）：

1. `set -euo pipefail`
2. root 检查：`EUID != 0` → `die`（提示 `sudo bash <脚本>` 重跑）
3. TTY 检查：`[[ -t 0 ]]` 否则 `die "需要交互终端运行，不支持无人值守"`
4. 发行版守卫：读 `/etc/os-release` 的 `ID`，非 `debian` / `ubuntu` → `die`
5. 颜色：`[[ -t 1 ]]` 时定义（swap.sh 同款），否则全为空
6. `log` / `warn` / `die` 输出函数；`die` 带退出码 1
7. ERR trap：打印脚本名 + 行号 + 失败的命令
8. `backup_file <路径>`：目标存在则 `cp` 到 `/root/vps-init-backups/<YYYYmmdd-HHMMSS>/<原名>`，打印备份路径并返回它
9. `ask_yesno <提示> [y|n]`：默认值大写显示，非法输入重问
10. `ask_input <提示> <校验函数>`：循环询问直到校验通过
11. 配置读写：
    - `CONF=/root/.vps-init.conf`；文件不存在则创建并 `chmod 600`
    - `conf_get <KEY> <提示> <校验函数>`：conf 中已有且合法 → 直接取值；否则交互询问 → 校验 → 以 `KEY='值'` 追加写盘
12. 公共校验器：
    - `v_ssh_port`：1024–65535 整数，且非 22 / 2222
    - `v_user`：`^[a-z_][a-z0-9_-]{0,31}$`
    - `v_ports_list`：逗号分隔端口号列表（可为空）
    - `v_pubkey`：每行匹配 `^(ssh|ecdsa)-` 开头的非空行

## 3. 配置文件 `/root/.vps-init.conf`

| 键 | 校验 | 默认（读不到时的询问/取值） | 读写者 |
|---|---|---|---|
| `SSH_PORT` | v_ssh_port | 询问（提示在 10000–65535 随机给建议值） | 05 写；06/07 读 |
| `ADMIN_USER` | v_user | 询问 | 04 写；06 读 |
| `SSH_PUBKEY` | v_pubkey（支持多行，逐行校验） | 询问（粘贴，空行结束） | 04 写 |
| `ALLOWED_PORTS` | v_ports_list | 询问，默认 `80,443`，可为空 | 05 读写 |
| `TOOLS_EXTRA` | 自由文本（空格分隔包名） | 默认 `jq tmux lsof rsync zip` | 02 读写 |
| `SUDO_NOPASSWD` | yes/no | 询问，默认 `no` | 04 读写 |
| `F2B_BANTIME` | 正整数秒 | 默认 `86400` | 07 读写 |
| `F2B_FINDTIME` | 正整数秒 | 默认 `600` | 07 读写 |
| `F2B_MAXRETRY` | 正整数 | 默认 `3` | 07 读写 |

约定：值一律单引号包裹；`SSH_PUBKEY` 写入时多键以 `SSH_PUBKEY_N`（N=1,2,…）多键存储，读取时合并。

## 4. 脚本契约

每个脚本结尾统一打印一行：`[checklist 第 N 步完成，可勾选]`。

### 01-update.sh — 系统更新

- **前置**：公共块。
- **动作**：`DEBIAN_FRONTEND=noninteractive apt update && apt full-upgrade -y`。
- **幂等**：无可升级包时打印提示，正常退出。
- **reboot 判断**：升级后检查 `/var/run/reboot-required`；存在则 `ask_yesno "内核已更新，现在重启吗？重启后重连继续后续步骤"` → y：提示后 `systemctl reboot`；n：`warn` 提醒"基线建立在旧内核上"，正常退出。

### 02-tools.sh — 基础工具

- **动作**：`conf_get TOOLS_EXTRA` → `apt install -y` 必装清单 + extra。
- **必装清单**（与 checklist 第 2 步一致）：`sudo ca-certificates curl wget gnupg ufw fail2ban unattended-upgrades vim nano unzip htop git`（vim/nano 二选一：conf 里 `TOOLS_EDITOR`？——**否**，两个都装，成本为零，见 checklist 措辞"二选一，另一台机器上习惯哪个就装哪个"改为脚本内提示）。git 按此前决定：要用再装 → **不含 git**，需要者写进 `TOOLS_EXTRA`。
- **幂等**：apt install 天然幂等。
- **完成输出**：打印已装/跳过摘要。

### 04-user.sh — 管理员用户 + 公钥

- **前置**：公共块。
- **交互**：`conf_get ADMIN_USER`、`conf_get SSH_PUBKEY`（粘贴公钥，空行结束）、`conf_get SUDO_NOPASSWD`。
- **动作**：
  1. 用户不存在 → `adduser <user>`（沿用其交互设密码）；已存在 → 跳过创建，`log` 提示
  2. 确保 sudo 组成员：`usermod -aG sudo <user>`（Debian 无 sudo 组时由 02 已装 sudo 兜底）
  3. `SUDO_NOPASSWD=yes` → 写 `/etc/sudoers.d/<user>`（`<user> ALL=(ALL) NOPASSWD: ALL`，0440 权限，**写盘前后各跑一次 `visudo -c`**，校验失败立即删除该文件并 `die`）
  4. 写 `<user>` 的 `~/.ssh/authorized_keys`：目录 700、文件 600、属主正确，追加不覆盖（幂等：逐键比对已存在则跳过）
- **完成输出**：**闸门提示**（非询问）："新开终端验证 `ssh <user>@<host>` 密钥登录 + `sudo -v`，通过前禁止执行 05/06"。

### 05-ufw.sh — 防火墙

- **交互**：`conf_get SSH_PORT`、`conf_get ALLOWED_PORTS`。
- **动作**：
  1. `ufw default deny incoming` / `ufw default allow outgoing`
  2. **临时放行 22**：`ufw allow 22/tcp`（06 之前 sshd 仍在 22，此规则保证改端口期间旧端口仍可登录；06 闸门确认后移除）
  3. `ufw allow <SSH_PORT>/tcp`
  4. `ALLOWED_PORTS` 非空 → 逐个 `allow <port>/tcp`
  5. `ufw --force enable`（脚本已交互确认过，跳过 ufw 内置确认）
- **幂等**：已 enable 且端口已在 `ufw status` → 打印现状，跳过重复添加。
- **完成输出**：`ufw status verbose`，确认新端口 + 22 都在放行列表，提示 22 是临时规则。

### 06-ssh.sh — SSH 加固

- **前置自检（不满足即 die，提示先跑 05）**：
  1. `ufw status` 为 active
  2. `<SSH_PORT>` 已放行
  3. `grep -q '^Include' /etc/ssh/sshd_config`（drop-in 机制存在）
- **动作**：
  1. 打印 `/etc/ssh/sshd_config.d/` 现有文件清单，若发现 `50-cloud-init.conf` 类覆盖项则显式警告（"先出现者优先，01- 前缀将取得优先权"）
  2. `backup_file`（若已有 01-hardening.conf）→ 写 `/etc/ssh/sshd_config.d/01-hardening.conf`：
     ```
     Port <SSH_PORT>
     PermitRootLogin no
     PasswordAuthentication no
     PubkeyAuthentication yes
     AllowUsers <ADMIN_USER>
     MaxAuthTries 3
     ```
  3. `sshd -t` 语法校验，失败 → die（打印备份还原指引）
  4. `sshd -T` 验证**实际生效值**（port / passwordauthentication / permitrootlogin），与预期不符 → die（多半是 drop-in 优先权问题，打印排查指引）
  5. **闸门一**：`ask_yesno "已在 04 之后用新终端验证过 <ADMIN_USER> 的密钥登录吗？"` → n：die（"先验证，这是铁律"）
  6. `systemctl reload ssh`
  7. 自查：`ss -tlnp` 确认新端口在监听
- **完成输出**：
  - "**保持本会话不断开**。新开终端：`ssh -p <SSH_PORT> <ADMIN_USER>@<host>` 验证密钥登录 + root 被拒"
  - 提示同步改云安全组（关 22、开新端口）
  - **闸门二**：`ask_yesno "新终端已用新端口成功登录？"` → y：`ufw delete allow 22/tcp` + `log`；n：打印恢复指引（备份路径 + 还原命令 + reload），**不动 22 规则**，退出码 1
- 云厂商预置用户（ubuntu/admin 等）：**不删除**，仅被 AllowUsers 屏蔽；完成输出中提示其存在，删除与否留给人工。

### 07-fail2ban.sh

- **前置自检**：`sshd -T` 的实际端口与 `conf SSH_PORT` 一致，否则 die（"先跑 05/06，jail 端口必须与实际端口一致"）。
- **交互**：`conf_get F2B_BANTIME/F2B_FINDTIME/F2B_MAXRETRY`。
- **动作**：`apt install -y fail2ban` → `backup_file /etc/fail2ban/jail.local`（若存在）→ 写：
  ```
  [sshd]
  enabled = true
  port = <SSH_PORT>
  backend = systemd
  bantime = <F2B_BANTIME>
  findtime = <F2B_FINDTIME>
  maxretry = <F2B_MAXRETRY>
  ```
- **验证**：`systemctl enable --now fail2ban` → `fail2ban-client status sshd`，确认 jail 启动；`fail2ban-client get sshd actions` 无报错。
- **幂等**：jail.local 内容一致 → 跳过写入，仍做验证。

### verify.sh — 终检 + 归档

- **前置**：公共块；conf 不存在时打印警告并按"仅检查系统状态"降级运行（不询问参数）。
- **检查项**（红 = 安全基线未达成；黄 = 建议关注）：

| # | 检查 | 判定 | 级别 |
|---|---|---|---|
| 1 | sshd 实际端口（`sshd -T`） | = conf `SSH_PORT` | 红 |
| 2 | `passwordauthentication` | no | 红 |
| 3 | `permitrootlogin` | no | 红 |
| 4 | ufw | active | 红 |
| 5 | 新端口已放行、22 未放行 | `ufw status` | 红 |
| 6 | fail2ban sshd jail | active 且端口一致 | 红 |
| 7 | unattended-upgrades | 20auto-upgrades 两行均为 "1" | 红 |
| 8 | swap | `swapon --show` 非空 | 黄 |
| 9 | BBR | `sysctl net.ipv4.tcp_congestion_control` = bbr | 黄 |
| 10 | NTP | `timedatectl` NTP active | 黄 |
| 11 | 磁盘 | 使用率 < 90% | 黄 |
| 12 | reboot-required | 文件不存在 | 黄 |

- **产出**：终端绿/红/黄报告；写 `/root/vps-init-report.md`（含 conf 汇总：端口 / 用户 / 放行端口 / fail2ban 参数，对应 checklist 第 13 步归档）。
- **退出码**：有红 → 1，否则 0。

## 5. 错误处理与回滚约定

- 一切系统配置写入前 `backup_file`；**无自动回滚**——失败时打印备份路径与人工还原命令。
- `die` = 立即退出 1；ERR trap 保证意外失败也有现场信息。
- 最坏情况（SSH 锁死）的恢复路径：云控制台/VNC + 备份目录 + 第 0 步 Snapshot，README"故障恢复"一节已写。

## 6. 实现顺序与验证

1. 公共内联块定稿 → 01 → 02 → 04 → 05 → 06 → 07 → verify
2. 每完成一个脚本：`shellcheck`（零告警）+ `bash -n`；7 个全完后比对内联块一致性
3. 真实验收（在 Snapshot 保护的 VPS 上）：README 命令速查全流程走一遍 → `verify.sh` 全绿 → 人工确认新终端新端口密钥登录、root 被拒
4. `swap.sh` 不动；`bbr.sh` 由用户提供后贴入，README 命令即生效，无需其他改动
