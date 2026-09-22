# myVPS — VPS 初始化脚本集

面向 Debian / Ubuntu 新 VPS 的基础安全初始化脚本集。每个脚本**自包含**（单文件可独立拉取运行）、**幂等**（可重复执行）、带**交互闸门**（危险操作前强制人工确认）。

人工按 [checklist.md](checklist.md) 的顺序执行，README 提供每一步的命令。

## 三条铁律

> 1. **UFW 先于 sshd**：改 SSH 端口前，新端口必须已在 ufw 放行且 `ufw status` 可见。
> 2. **密钥先于禁密码**：`PasswordAuthentication no` 之前，必须已用密钥成功登录过新用户。
> 3. **旧会话不关**：改 sshd 配置后，保持当前会话不断开，新开终端验证新端口 + 密钥登录成功，才允许关闭旧会话。

脚本通过"前置自检 + 闸门"自行防错，但执行顺序由你保证。

## 前置（本地 / 云平台）

- 本地生成 SSH 密钥（已有则跳过）：`ssh-keygen -t ed25519`
- 云平台创建初始 Snapshot（锁死时的救命稻草）
- VPS 上需要 curl：Ubuntu/Debian 云镜像通常自带，没有则先 `apt install -y curl`

## 命令速查

把用户名换成你的 GitHub 账号（一处替换，全部复用）：

```bash
RAW="https://raw.githubusercontent.com/<你的GitHub用户名>/myVPS/main"
```

> 想固定版本：把 `main` 换成发布 tag，如 `.../myVPS/v1`。

| 步骤 | 执行方式 |
|---|---|
| 0. 云平台检查 | 手动（见 checklist.md 第 0 步） |
| 1. 系统更新 | `sudo bash <(curl -sL "$RAW/01-update.sh")` |
| 2. 基础工具 | `sudo bash <(curl -sL "$RAW/02-tools.sh")` |
| 3. hostname / 时区 / 时间同步 | 手动，命令见下 |
| 4. 创建管理员用户 + 公钥 | `sudo bash <(curl -sL "$RAW/04-user.sh")` |
| — | **闸门**：新终端验证密钥登录 + `sudo -v`，通过才继续 |
| 5. UFW | `sudo bash <(curl -sL "$RAW/05-ufw.sh")` |
| 6. SSH 加固 | `sudo bash <(curl -sL "$RAW/06-ssh.sh")` |
| — | **闸门**：新终端用新端口验证密钥登录；同步改云安全组（关 22、开新端口） |
| 7. fail2ban | `sudo bash <(curl -sL "$RAW/07-fail2ban.sh")` |
| 8. Swap | `sudo bash swap.sh`（或 `sudo bash <(curl -sL "$RAW/swap.sh")`） |
| 9. BBR | `sudo bash <(curl -sL "$RAW/bbr.sh")`（脚本待加入仓库） |
| 10. 自动安全更新 | 手动，命令见下 |
| 11. Docker | 仅提示，见下 |
| 12–13. 终检 + 归档 | `sudo bash <(curl -sL "$RAW/verify.sh")`，报告写入 `/root/vps-init-report.md` |

首次运行时，脚本会交互询问 SSH 端口、用户名、公钥等参数，保存到 `/root/.vps-init.conf`（600 权限，仅存在于 VPS 本地，不进仓库），后续脚本自动继承，一次输入全局复用。

### 步骤 3：系统基础配置（手动）

```bash
hostnamectl set-hostname <主机名>      # 可选，保持厂商默认可跳过
timedatectl set-timezone Asia/Shanghai
timedatectl                            # 确认 NTP service active
```

### 步骤 10：自动安全更新（手动）

```bash
apt install -y unattended-upgrades
cat /etc/apt/apt.conf.d/20auto-upgrades   # 确认 Update/Upgrade 均为 "1"
```

### 步骤 11：Docker（提示，不自动安装）

推荐从官方仓库安装：<https://docs.docker.com/engine/install/>（Debian/Ubuntu 各有指引，执行前核对官方最新写法）。

知情提醒：把用户加入 `docker` 组等价于授予 root 权限，与"禁 root 登录"的目标有冲突——个人 VPS 可接受，但要知道这个权衡。装完用 `docker run --rm hello-world` 验证。

## 故障恢复

- 所有脚本修改系统配置前，先备份到 `/root/vps-init-backups/<时间戳>/`
- SSH 疑似锁死：用云平台控制台 / VNC 登录，从备份目录还原 `sshd_config.d` 相关文件后 `systemctl reload ssh`
- 最终防线是第 0 步的 Snapshot

## 脚本约定（开发者视角）

- 每个脚本自包含、幂等、中文交互；实现契约见 [docs/design.md](docs/design.md)
- 术语表见 [CONTEXT.md](CONTEXT.md)，关键决策见 [docs/adr/](docs/adr/)
