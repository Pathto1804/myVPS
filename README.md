# myVPS：VPS 初始化脚本集

新拿到一台 Debian / Ubuntu VPS 后要做的安全初始化。每个脚本自包含（单文件从 GitHub 拉下来就能跑）、幂等（重复执行自动跳过已完成项）、中文交互，危险操作前停下来让你确认。

本页是唯一操作手册：流程、命令、检查点都在这里，按步骤顺序执行。不想用脚本、想逐条命令手动完成的，看[手动教程](docs/tutorial.md)——步骤编号与本页一一对应。

> **免责声明**：本项目为**个人自用**的 VPS 基础配置脚本集，**不具有通用性**——脚本参数与业务取舍均基于本人需求，通过 AI 生成，未经广泛验证。本人不对任何内容作担保，执行前请**自行审阅全部脚本**（尤其涉及防火墙与 SSH 配置的部分），据此操作的风险由使用者自负。

## 三条铁律

> 1. **UFW 先于 sshd**：改 SSH 端口前，新端口必须已在 ufw 放行且 `ufw status` 可见。
> 2. **密钥先于禁密码**：`PasswordAuthentication no` 之前，必须已用密钥成功登录过新用户。
> 3. **旧会话不关**：改 sshd 配置后，保持当前会话不断开，新开终端验证新端口 + 密钥登录成功，才允许关闭旧会话。

脚本会通过前置自检和闸门挡住大多数顺序错误（比如 ufw 没放行就跑 06 会直接拒绝执行），但整体顺序还是你自己掌握。

## 开始之前（步骤 0：云平台基础检查）

- `cat /etc/os-release` 确认发行版与版本；`nproc` / `free -h` / `df -h` 看配置
- 系统要求：Debian 11+ / Ubuntu 20.04+（06 依赖 `sshd_config.d`；02 的 `bind9-dnsutils` 也自 Debian 11 / Ubuntu 20.04 起才有，更老的系统会在第 2 步装不上）
- **记下当前 SSH 端口**：`sshd -T | grep ^port`——有些云厂商把 ssh 预置在随机端口上，后续步骤会自动识别，但你得知道它、并确认云安全组放行的是这个端口（第 6 步改端口后同步改）
- 云平台安全组：记录当前放行规则（第 6 步改 SSH 端口后必须同步改）
- **创建初始 Snapshot**——整个流程唯一不可替代的一步，锁死时的救命稻草
- 本地生成 SSH 密钥（已有则跳过）：`ssh-keygen -t ed25519`
- 云镜像一般自带 curl，没有就 `apt install -y curl`
- **国内服务器先换源**：默认官方源国内访问慢；用 [linuxmirrors](https://linuxmirrors.cn) 的一键脚本换国内镜像源，换源在步骤 1 之前做，海外服务器不需要这步：

  ```bash
  bash <(curl -sSL https://linuxmirrors.cn/main.sh)
  ```

  按提示选镜像站和协议即可，脚本改动源文件前会自动备份；不想交互可直接 `--source mirrors.aliyun.com --protocol https` 指定。详细交互与参数见[手动教程](docs/tutorial.md#0-云平台基础检查)。
- **测一下机器实际性能**（可选，能跑出 VPS 真实带宽与磁盘读写，方便和商家标称对比）：[bench.sh](https://bench.sh)

  ```bash
  bash <(curl -Lso- bench.sh)
  ```

  输出系统信息 + 网络测速 + 磁盘读写，跑完看商家虚标没有。在步骤 0 做（趁系统干净），之后步骤不影响。

## 执行流程

> 想固定版本：把命令里的 `main` 换成发布 tag。断点续跑：初始化到一半 SSH 断了，重连后从对应步骤接着跑，已完成的脚本重跑会自动跳过。

**1. 系统更新**

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/Pathto1804/myVPS/main/01-update.sh)
```

做什么：`apt update` + `apt full-upgrade`，把系统补到最新。升级后若需要重启（通常是内核更新），脚本会询问，选 y 自动重启，重连后从第 2 步继续。

**2. 基础工具**

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/Pathto1804/myVPS/main/02-tools.sh)
```

做什么：装必要项 + 常用实用工具（`sudo ca-certificates curl wget gnupg ufw fail2ban unattended-upgrades vim nano unzip htop needrestart ncdu mtr-tiny bind9-dnsutils`），另问一句"还要装什么"，默认 `jq tmux lsof rsync zip`，不需要留空。其中 `needrestart` 补上自动更新后重启受影响服务这一环（缺它则 libc/openssl 补丁装了不生效）——装完之后在有终端的 apt 里（含第 10 步的 docker 一键脚本）会多问一句要重启哪些服务，答 `i` 立即重启、`l` 只看清单，脚本内部为非交互所以只列清单；`ncdu`/`mtr-tiny`/`bind9-dnsutils` 是磁盘、链路、DNS 三件套。tcpdump/strace/sysstat 等有提权面或需额外启用的诊断类仍不预装，用到再装。

**3. 系统基础配置**（手动）

```bash
hostnamectl set-hostname <主机名>      # 可选，保持厂商默认可跳过
timedatectl set-timezone Asia/Shanghai
timedatectl                            # 确认 NTP service active
```

做什么：设置主机名（可跳过）、时区，并确认系统时间同步在跑——时间不准会让 fail2ban 的封禁窗口、证书校验出问题。

**4. 创建管理员用户 + 公钥**

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/Pathto1804/myVPS/main/04-user.sh)
```

做什么：新建管理员用户并加入 sudo 组；也支持**管理已有用户**——重跑脚本可换目标用户、设置/修改登录密码（可选**随机生成**——显示一次请立即保存，不存 conf；或转发 `passwd` 原生交互自己输入）、修改 sudo 免密（含翻转：开↔关，自动处理 sudoers 文件的写入与删除）、追加或删除公钥。新建用户无密码时默认提示设置（否则 sudo 密码模式无法验证）。公钥写入 `~/.ssh/authorized_keys`（权限 700/600、属主正确），同步存入 conf 供复用。

> **闸门一**：新开终端验证 `ssh <用户名>@<host>` 密钥登录成功 + `sudo -v` 通过。**不通过，禁止执行第 5 步之后。**

**5. UFW 防火墙**

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/Pathto1804/myVPS/main/05-ufw.sh)
```

做什么：ufw 默认拒绝入站、允许出站；放行新 SSH 端口（首次询问时**回车即用随机端口**，也可自己输入）；**临时放行当前 SSH 端口**（自动从 sshd 读取，22 或厂商随机端口均可，第 6 步完成前旧端口还得用）；按需放行业务端口（脚本会问，逗号分隔，如 `80,443`，留空跳过）；最后 `ufw --force enable` 启用。跑完 `ufw status` 应看到新端口和旧端口都在列表。

**6. SSH 加固**

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/Pathto1804/myVPS/main/06-ssh.sh)
```

做什么：写入 `/etc/ssh/sshd_config.d/01-hardening.conf`——改端口（conf 已有则沿用；05 首次已存，无需再输）、禁 root 登录、禁密码认证（只留密钥）、`AllowUsers` 限定管理员、`MaxAuthTries 3`。01 前缀抢在云镜像 `50-cloud-init.conf` 之前拿优先权（sshd 配置先出现者优先）。写完 `sshd -t` 语法校验、`sshd -T` 验证实际生效值（防 drop-in 被覆盖）、`reload` 生效、确认新端口在监听。

> **闸门二**（脚本两次停下确认）：
> 1. 写配置前先问"04 之后验证过密钥登录吗"——答 n 直接退出，不改任何配置
> 2. reload 后：**保持本会话不断开**，新开终端 `ssh -p <新端口> <用户名>@<host>` 验证密钥登录 + root 被拒，**同步改云平台安全组（关旧端口、开新端口）**，回来答 y 后脚本才移除旧端口的临时放行；答 n 则保留旧端口规则并打印恢复指引

**7. fail2ban**

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/Pathto1804/myVPS/main/07-fail2ban.sh)
```

做什么：安装 fail2ban，写 `/etc/fail2ban/jail.local`——sshd jail 监听**新端口**（不写则默认盯 22，形同虚设）、`backend = systemd`（兼容 Debian 12 无 auth.log 与 Ubuntu 24.04+）。默认激进档：封 24h / 窗口 10min / 3 次触发，脚本会问是否自定义。启用后 `fail2ban-client status sshd` 确认。

**8. Swap**

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/Pathto1804/myVPS/main/08-swap.sh)
```

做什么：交互式管理 swap 文件——查看现状 / 创建（写 fstab 持久化）/ 调整 swappiness / 删除，自带 fstab 备份回滚。完成后 `free -h` 与 `swapon --show` 确认。

**9. BBR + TCP 调优**

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/Pathto1804/myVPS/main/09-bbr.sh)
```

做什么：写入 `/etc/sysctl.d/99-bbr.conf`——开启 BBR 拥塞控制 + fq 队列，附带一组 TCP 缓冲/连接参数调优；`sysctl -p` 应用后验证 `tcp_congestion_control = bbr`。个别键若被新内核移除（如 `tcp_fack`）仅警告不中断。

> 注意：仓库里的 `09-bbr.sh` 参数是根据我自己的 VPS（线路、内存、用途）特调的，**不一定适合你的机器**。想要匹配自己 VPS 的脚本，可去 <https://omnitt.com> 获取；从外部站点拉脚本执行前，请**自己检查脚本内容的安全性**再运行。

**10. 自动安全更新**（手动）

```bash
apt install -y unattended-upgrades
cat /etc/apt/apt.conf.d/20auto-upgrades   # 确认 Update/Upgrade 均为 "1"
```

做什么：启用安全补丁自动安装（Ubuntu 默认已开，Debian 需装）。VPS 不常登录，这是廉价保险。

**11. Docker**（仅提示，不自动安装）

本轮初始化不安装 Docker。需要时后续自行安装——用 [linuxmirrors](https://linuxmirrors.cn) 维护的一键脚本（装 Docker Engine + 配镜像加速，国内服务器尤其合适）：

```bash
bash <(curl -sSL https://linuxmirrors.cn/docker.sh)
```

> ⚠️ 脚本会问"是否关闭防火墙"——**选否**（或直接加 `--close-firewall false`），否则我们刚配好的 ufw 会被关掉。

不想交互可 `--source mirrors.aliyun.com --source-registry docker.1ms.run --install-latest true --close-firewall false` 全自动跳过选择。或按官方仓库安装指引（docs.docker.com，注意核对最新写法）。`docker` 组权限等价于 root，与禁 root 登录的目标有冲突，知情即可。装完用 `docker run --rm hello-world` 验证。完整交互与参数见[手动教程](docs/tutorial.md#11-docker提示)。

**12–13. 终检 + 归档**

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/Pathto1804/myVPS/main/12-verify.sh)
```

做什么：逐项做绿/红终检——sshd 实际生效值（端口/禁密码/禁 root）、ufw 规则（含旧端口已关）、fail2ban jail、自动更新与 needrestart（升级后重启受影响服务，缺它则库补丁不生效）为红灯项；swap / BBR / NTP / 磁盘 / 重启标记为黄灯提示。报告 + 配置摘要（端口/用户/放行端口/fail2ban 参数）写入 `/root/vps-init-report.md`，可作归档记录。有红灯退出码 1，修复后重跑。全绿后：核对报告 → 云平台创建最终 Snapshot。

## 参数只输一次

SSH 端口、用户名、公钥这些参数：脚本问完会存进 `/root/.vps-init.conf`（600 权限，只在 VPS 本地，不进仓库），后面的脚本自动读取。这个文件删了也没关系，重跑脚本会重新询问。

conf 全部键（维护参考）：

| 键 | 写入脚本 | 含义 / 默认 |
|---|---|---|
| `SSH_PORT` | 05 | 新 SSH 端口（1024–65535，避开 22/2222） |
| `OLD_SSH_PORT` | 05 | 迁移前的旧端口（自动从 sshd 读取，兼容厂商随机端口；不假设 22） |
| `ADMIN_USER` | 04 | 管理员用户名 |
| `SSH_PUBKEY_N` | 04 | 公钥，N=1,2,…，逐行存 |
| `ALLOWED_PORTS` | 05 | 额外放行端口，逗号分隔，默认问询后留空 |
| `TOOLS_EXTRA` | 02 | 额外工具包，默认 `jq tmux lsof rsync zip` |
| `SUDO_NOPASSWD` | 04 | sudo 免密开关，默认 no |
| `F2B_BANTIME` | 07 | 封禁时长（秒），默认 86400 |
| `F2B_FINDTIME` | 07 | 统计窗口（秒），默认 600 |
| `F2B_MAXRETRY` | 07 | 最大重试次数，默认 3 |

## 出问题怎么办

- 所有脚本改系统配置前，先把原文件备份到 `/root/vps-init-backups/<时间戳>/`。脚本执行失败时会把备份路径打印出来
- SSH 疑似锁死：用云平台控制台 / VNC 登录，从备份目录还原 `sshd_config.d` 相关文件，再 `systemctl reload ssh`
- 以上都不行，步骤 0 的 Snapshot 是最终防线
- 网络原因拉不到脚本：先在本地下载好，`scp` 上去再 `sudo bash 脚本名` 执行，效果一样

## 脚本约定（开发者视角）

- 每个脚本自包含（公共函数内联，不依赖仓库里其他文件）、幂等、中文交互，单独拉取即可运行
- 修改系统配置前先备份到 `/root/vps-init-backups/<时间戳>/`，不做自动回滚
- 公共函数在脚本间保持一致；改动后运行 `bash tools/sync_check.sh` 自查（输出「一致性 OK」才算通过）
- 术语表见 [CONTEXT.md](CONTEXT.md)，为什么没有总控脚本见 [docs/adr/0001-no-orchestrator.md](docs/adr/0001-no-orchestrator.md)
