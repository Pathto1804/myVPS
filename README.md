# myVPS：VPS 初始化脚本集

新拿到一台 Debian VPS 后要做的安全初始化（Ubuntu 20.04+ 兼容，未逐版本验证，见「系统要求」）。每个脚本自包含（单文件从 GitHub 拉下来就能跑）、幂等（重复执行自动跳过已完成项）、中文交互，危险操作前停下来让你确认。

本页是唯一操作手册：流程、命令、检查点都在这里，按步骤顺序执行。不想用脚本、想逐条命令手动完成的，看[手动教程](docs/tutorial.md)——步骤编号与本页一一对应。

> **免责声明**：本项目为**个人自用**的 VPS 基础配置脚本集，**不具有通用性**——脚本参数与业务取舍均基于本人需求，通过 AI 生成，未经广泛验证。本人不对任何内容作担保，执行前请**自行审阅全部脚本**（尤其涉及防火墙与 SSH 配置的部分），据此操作的风险由使用者自负。

## 三条铁律

> 1. **UFW 先于 sshd**：改 SSH 端口前，新端口必须已在 ufw 放行且 `ufw status` 可见。
> 2. **密钥先于禁密码**：`PasswordAuthentication no` 之前，必须已用密钥成功登录过新用户。
> 3. **旧会话不关**：改 sshd 配置后，保持当前会话不断开，新开终端验证新端口 + 密钥登录成功，才允许关闭旧会话。

脚本会通过前置自检和闸门挡住大多数顺序错误（比如 ufw 没放行就跑 06 会直接拒绝执行），但整体顺序还是你自己掌握。

## 开始之前（步骤 0：云平台基础检查）

- `cat /etc/os-release` 确认发行版与版本；`nproc` / `free -h` / `df -h` 看配置
- 系统要求：**Debian 12 / 13（一等支持；真机验收基线是 Debian 12 bookworm）**；Debian 11 与 Ubuntu 20.04+ 理论可用但**未逐版本验证**。两者都依赖 `sshd_config.d`，且 01-base 的 `bind9-dnsutils` 自 Debian 11 / Ubuntu 20.04 起才有，更老的系统会在第 1–2 步装不上
- **记下当前 SSH 端口**：`sshd -T | grep ^port`——有些云厂商把 ssh 预置在随机端口上，后续步骤会自动识别，但你得知道它、并确认云安全组放行的是这个端口（第 5–6 步改端口后同步改）
- 云平台安全组：记录当前放行规则（第 5–6 步改 SSH 端口后必须同步改）
- **创建初始 Snapshot**——整个流程唯一不可替代的一步，锁死时的救命稻草
- 本地生成 SSH 密钥（已有则跳过）：`ssh-keygen -t ed25519`
- 云镜像一般自带 curl，没有就 `apt install -y curl`
- **国内服务器先换源**：默认官方源国内访问慢；用 [linuxmirrors](https://linuxmirrors.cn) 的一键脚本换国内镜像源，换源在步骤 1 之前做，海外服务器不需要这步：

  ```bash
  bash <(curl -fsSL https://linuxmirrors.cn/main.sh)
  ```

  按提示选镜像站和协议即可，脚本改动源文件前会自动备份；不想交互可直接 `--source mirrors.aliyun.com --protocol https` 指定。详细交互与参数见[手动教程](docs/tutorial.md#0-云平台基础检查)。
- **测一下机器实际性能**（可选，能跑出 VPS 真实带宽与磁盘读写，方便和商家标称对比）：[bench.sh](https://bench.sh)

  ```bash
  bash <(curl -Lso- bench.sh)
  ```

  输出系统信息 + 网络测速 + 磁盘读写，跑完看商家虚标没有。在步骤 0 做（趁系统干净），之后步骤不影响。

## 执行流程

> 想固定版本：把命令里的 `main` 换成发布 tag。断点续跑：初始化到一半 SSH 断了，重连后从对应步骤接着跑，已完成的脚本重跑会自动跳过。
>
> **执行方式**：先 `sudo -i` 提权到 root，下面所有命令在 root 会话里直接运行（脚本自带 root/TTY 检查）。
>
> - 不要以普通用户身份 `sudo bash <(curl …)`——sudo 会关闭额外文件描述符，报 `/dev/fd/63: No such file or directory`
> - root 会话里也用 `bash <(curl …)`，别再套 `sudo`
> - curl 统一带 `-S`，下载失败会明确报错而不是无声中断

> **国内服务器拉不动 GitHub**（卡住、Connection reset、几十 KB/s）：下面每条命令都附了一行**加速版**，就是在原始 URL 前加一层第三方加速前缀（默认用 `ghproxy.net`）。可用前缀不止一个，挂了/返回旧版就换下一个（2026-09-26 逐个实测，返回的都是脚本原文）：
>
> ```text
> https://ghproxy.net/
> https://ghfast.top/
> https://gh-proxy.com/
> https://gh.llkk.cc/
> https://gh.ddlc.top/
> ```
>
> 也可整段换成 jsDelivr CDN：把 `https://raw.githubusercontent.com/Pathto1804/myVPS/main/` 换成 `https://cdn.jsdelivr.net/gh/Pathto1804/myVPS@main/`（按分支取有缓存约 12h，要准就用 tag）。
>
> 两点提醒：
>
> - **加速站是第三方**：脚本内容经它中转，在意就本机 `curl` 下载 → `scp` 上传 → `sudo bash 文件名`
> - **缓存滞后哪家都有**：刚推送的改动可能几分钟后才在代理上生效，重要脚本拉下来先 `bash -n` 或读一遍再用
>
> 按开头免责声明的要求，无论哪条路，执行前先读一遍。

**1–2. 系统准备（系统更新 + 基础工具）**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/01-base.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/01-base.sh)
```

做什么：

- `apt update` + `apt full-upgrade`，把系统补到最新
- 装必要项 + 常用实用工具：`sudo ca-certificates curl wget gnupg ufw fail2ban unattended-upgrades vim nano unzip htop needrestart ncdu mtr-tiny bind9-dnsutils`
- 另问一句"还要装什么"，默认 `jq tmux lsof rsync zip`，不需要留空
- 写入并启用安全补丁自动安装（`20auto-upgrades` 两行 `"1"`；第 10 步只是复核）
- **needrestart**：补上自动更新后重启受影响服务这一环（缺它则 libc/openssl 补丁装了不生效）。装完之后在有终端的 apt 里（含第 10 步的 docker 一键脚本）会多问一句要重启哪些服务，答 `i` 立即重启、`l` 只看清单；脚本内部为非交互所以只列清单
- **ncdu / mtr-tiny / bind9-dnsutils**：磁盘、链路、DNS 三件套
- tcpdump/strace/sysstat 等有提权面或需额外启用的诊断类仍不预装，用到再装
- **最后才问重启**：需要重启（通常是内核更新）时选 y 自动重启，重连后从第 3 步继续

**3. 系统基础配置**（手动）

```bash
hostnamectl set-hostname <主机名>      # 可选，保持厂商默认可跳过
timedatectl set-timezone Asia/Shanghai
timedatectl                            # 确认 NTP service active
```

做什么：

- 设置主机名（可跳过）、时区
- 确认系统时间同步在跑——时间不准会让 fail2ban 的封禁窗口、证书校验出问题

**4. 创建管理员用户 + 公钥**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/04-user.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/04-user.sh)
```

做什么：**菜单式**——选好目标用户（新建或管理已有，conf 记住上次操作的用户）后进入主菜单，一次只做一件事，`0` 退出。

菜单项：

- **1 设置/修改登录密码**：可选**随机生成**（显示一次请立即保存，不存 conf），或转发 `passwd` 原生交互自己输入
- **2 sudo 免密切换**：确认一次后自动处理 sudoers 文件的写入与删除，`visudo -c` 校验兜底
- **3 管理公钥**（追加/删除）：每笔改动立即重写 `~/.ssh/authorized_keys`，权限 700/600、属主正确，同步存入 conf 供复用

用户无密码时状态行标 `⚠`，退出前再提醒一次（否则 sudo 密码模式无法验证）。

> **闸门一**：新开终端验证 `ssh <用户名>@<host>` 密钥登录成功 + `sudo -v` 通过。**不通过，禁止执行第 5–6 步之后。**

**5–6. 防火墙 + SSH 加固**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/05-ufw-ssh.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/05-ufw-ssh.sh)
```

做什么：**菜单式**——首次运行先做防火墙初始化，紧接着走 SSH 加固流程（双闸门），之后进入维护菜单，一次只做一件事，`0` 退出。ufw 未启用时不会硬闯 sshd 加固（铁律：UFW 先于 sshd），只会提示你先用菜单 `1`。

防火墙初始化（菜单 `1`，首次运行自动跑）：

- ufw 默认拒绝入站、允许出站
- 放行新 SSH 端口（首次询问时**回车即用随机端口**，也可自己输入）
- **迁移期临时放行当前 SSH 端口**：自动从 sshd 读取，22 或厂商随机端口均可，第 5–6 步完成前旧端口还得用；sshd 已在新端口上则不建这条规则
- 按需放行业务端口
- **启用前自检**：新端口已在放行列表，未放行就拒绝启用（防锁死；ufw 未启用时 `ufw status` 不列规则，故该自检读 `ufw show added`）

SSH 加固（菜单 `2`，未加固时首次运行自动接着跑）：

- 写 `/etc/ssh/sshd_config.d/01-hardening.conf`：改端口（conf 已有则沿用；菜单 `1` 已存，无需再输）、禁 root 登录、禁密码认证（只留密钥）、`AllowUsers` 限定管理员、`MaxAuthTries 3`
- 01 前缀抢在云镜像 `50-cloud-init.conf` 之前拿优先权（sshd 配置先出现者优先）
- 前置自检核对 ufw：新端口未放行直接拒绝执行；迁移期间还要求**旧端口也保持放行**（闸门二确认前不能断退路）
- 写完依次做：`sshd -t` 语法校验 → `sshd -T` 验证实际生效值（防 drop-in 被覆盖）→ 应用配置 → 确认新端口在监听
- **仅 Ubuntu：22.10+ 默认的 `ssh.socket` 套接字激活会让 `Port` 不生效**（`sshd -T` 显示已改、实际还在听 22）：脚本检测到会自动切回标准 `ssh.service` 模式再重启（Debian 默认就是 `ssh.service`，不涉及）
- 已在目标端口上时按"无迁移"处理，不再动旧端口规则

> **闸门二**（脚本两次停下确认）：
> 1. 写配置前先问"04 之后验证过密钥登录吗"——答 n 直接退出，不改任何配置
> 2. reload 后：**保持本会话不断开**，新开终端 `ssh -p <新端口> <用户名>@<host>` 验证密钥登录 + root 被拒，**同步改云平台安全组（关旧端口、开新端口）**，回来答 y 后脚本才移除旧端口的临时放行；答 n 则保留旧端口规则并打印恢复指引

菜单项（`0` 退出）：

- `1` 防火墙初始化 / 重新应用（默认拒绝入站 + 放行 SSH 与业务端口）
- `2` SSH 加固 / 重新应用（写 `01-hardening.conf`，双闸门）
- `3` 状态总览：ufw 规则 + sshd 生效值 + 加固文件 + drop-in 覆盖检查
- `4` 放行端口：选 tcp/udp/两者，端口可逗号分隔多个，可选限制来源 IP
- `5` 按编号删规则：删到 SSH 端口那条会先警告断连风险；ufw 未启用时拿不到编号，会提示先启用或用 `ufw delete allow <规则>`
- `6` 启用 / 禁用防火墙：禁用需二次确认
- `7` 改默认策略（入站 / 出站）
- `8` 改 `ALLOWED_PORTS` 清单：**按清单增删规则**，清单里没有的端口规则自动删、新增的自动放行
- `9` 改参数（SSH 端口 / 管理员用户）：写 conf，改端口会提示先在菜单 `1` 放行新端口
- `10` 从 `/root/vps-init-backups/` 挑一份 `01-hardening.conf` 恢复：列表按时新排序，恢复前先备份当前文件，语法校验失败自动回滚；若备份里的端口变了，会先确认 ufw 已放行再问是否重启 sshd

日常维护重跑本脚本进菜单即可，不必再记 ufw/sshd 子命令。

**7. fail2ban**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/07-fail2ban.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/07-fail2ban.sh)
```

做什么：**菜单式**——首次运行自动安装并配置，之后进入维护菜单，一次只做一件事，`0` 退出。

应用配置（`1`，首次运行自动跑）：

- 写 `/etc/fail2ban/jail.local`：sshd jail 监听**新端口**（不写则默认盯 22，形同虚设）、`backend = systemd`（兼容 Debian 12 无 auth.log 与 Ubuntu 24.04+）
- 默认激进档：封 24h / 窗口 10min / 3 次触发，首次运行逐项询问（回车取默认）
- 写文件前自动备份到 `/root/vps-init-backups/`
- **jail 端口必须与 sshd 实际端口一致**：不一致、或读不到 sshd 实际端口（`sshd -T` 失败）时**拒绝写入**并打印原因——不会拿一个编造的默认端口凑数，宁可 fail closed 也不让 fail2ban 去盯一个 sshd 没监听的端口（那是静默失效）
- 重启后轮询等 jail 就绪（fail2ban 读配置、起 backend 需 1~2 秒，立刻查会误报 `Jail 'sshd' does not exist`），10 秒未就绪即报错退出
- 退出前核对 jail 在跑且 jail 端口 == sshd 实际端口：都满足才打印"第 7 步完成"；否则打印"第 7 步未完成"并以非零退出（12-verify.sh 在同样状态下也会报红）

菜单项：

- `2` 只读详情：`jail.local` 内容 + `fail2ban-client status sshd` 的封禁列表 + 服务日志末 20 行
- `3` 改封禁时长 / 统计窗口 / 重试次数：写 conf，末尾问一句是否立即应用到 `jail.local`
- `4` 手动封禁 / 解封 IP：`fail2ban-client set sshd banip|unbanip`，仅接受 IPv4

表头四行是实时状态：服务是否 active、jail 是否运行中及当前封禁数、`jail.local` 里的生效参数（与 conf 不一致时标注"按 1 应用"）、jail 端口与 sshd 实际端口是否一致（读不到时明确显示"未知"而非断言不一致）。

**8. Swap**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/08-swap.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/08-swap.sh)
```

做什么：

- 交互式管理 swap 文件：查看现状 / 创建（写 fstab 持久化）/ 调整 swappiness / 删除
- 自带 fstab 备份回滚
- 完成后 `free -h` 与 `swapon --show` 确认

**9. BBR + TCP 调优**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/09-bbr.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/09-bbr.sh)
```

做什么：

- 写 `/etc/sysctl.d/99-bbr.conf`：开启 BBR 拥塞控制 + fq 队列，附带一组 TCP 缓冲/连接参数调优
- `sysctl -p` 应用后验证 `tcp_congestion_control = bbr`
- 个别键若被新内核移除（如 `tcp_fack`）仅警告不中断

> 注意：仓库里的 `09-bbr.sh` 参数是根据我自己的 VPS（线路、内存、用途）特调的，**不一定适合你的机器**。想要匹配自己 VPS 的脚本，可去 <https://omnitt.com> 获取；从外部站点拉脚本执行前，请**自己检查脚本内容的安全性**再运行。

**10. 自动安全更新**（只复核，不用手动装）

```bash
cat /etc/apt/apt.conf.d/20auto-upgrades   # 两行都应为 "1"
```

做什么：

- 启用安全补丁自动安装（VPS 不常登录，这是廉价保险）
- **01-base.sh 已自动写入并启用**（装包不等于启用——apt 装完该文件默认是两行 `"0"`，等于关闭）
- 这里只是复核：若显示 `"0"`，说明 `01-base.sh` 没跑到或被你覆盖过，重跑即可

**11. Docker**（仅提示，不自动安装）

本轮初始化不安装 Docker。需要时后续自行安装——用 [linuxmirrors](https://linuxmirrors.cn) 维护的一键脚本（装 Docker Engine + 配镜像加速，国内服务器尤其合适）：

```bash
bash <(curl -fsSL https://linuxmirrors.cn/docker.sh)
```

> ⚠️ 脚本会问"是否关闭防火墙"——**选否**（或直接加 `--close-firewall false`），否则我们刚配好的 ufw 会被关掉。

- 不想交互：`--source mirrors.aliyun.com --source-registry docker.1ms.run --install-latest true --close-firewall false` 全自动跳过选择；或按官方仓库安装指引（docs.docker.com，注意核对最新写法）
- `docker` 组权限等价于 root，与禁 root 登录的目标有冲突，知情即可
- 装完用 `docker run --rm hello-world` 验证
- 完整交互与参数见[手动教程](docs/tutorial.md#11-docker提示)

**12–13. 终检 + 归档**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pathto1804/myVPS/main/12-verify.sh)
# 国内拉不动 → 加速版：
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/Pathto1804/myVPS/main/12-verify.sh)
```

做什么：

- 逐项做绿/红终检
  - 红灯项：sshd 实际生效值（端口/禁密码/禁 root）、ufw 规则（含旧端口已关）、fail2ban jail（jail 未运行、或 `jail.local` 的 `port` ≠ sshd 实际端口，都判红；与 07 的 fail-closed 口径一致）、自动更新与 needrestart（升级后重启受影响服务，缺它则库补丁不生效）
  - 黄灯提示：swap / BBR / NTP / 磁盘 / 重启标记
- 报告 + 配置摘要（端口/用户/放行端口/fail2ban 参数）写入 `/root/vps-init-report.md`，可作归档记录
- 有红灯退出码 1，修复后重跑
- 全绿后：核对报告 → 云平台创建最终 Snapshot

## 参数只输一次

SSH 端口、用户名、公钥这些参数：脚本问完会存进 `/root/.vps-init.conf`（600 权限，只在 VPS 本地，不进仓库），后面的脚本自动读取。这个文件删了也没关系，重跑脚本会重新询问。

- 提示处按 `Ctrl-D`（输入流结束）＝**输入中断**：脚本立即以退出码 1 退出，**不会**把空值写进 conf——空值会污染后续脚本读取，所以这里刻意 fail fast，而不是拿空串继续

conf 全部键（维护参考）：

| 键 | 写入脚本 | 含义 / 默认 |
|---|---|---|
| `SSH_PORT` | 05 | 新 SSH 端口（1024–65535，避开 22/2222） |
| `OLD_SSH_PORT` | 05/06 | 迁移前的旧端口（自动从 sshd 读取，兼容厂商随机端口；不假设 22；06 在写新配置前确认一次） |
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
- 拉取 / 执行方式的坑：
  - `sudo bash <(curl …)`：sudo 关闭继承的文件描述符，报 `/dev/fd/63: No such file or directory`
  - `curl … | bash`：脚本因 `BASH_SOURCE` 未定义 + stdin 非终端而拒绝执行
  - 两种解法：**按本页标准做法先 `sudo -i` 提权**；必须留在 sudo 环境时用 `sudo bash -c 'bash <(curl -fsSL <URL>)'`（FD 在 sudo 之后的 bash 内部创建，不会丢）
  - 下载失败若无声无息，确认命令用的是 `-sSL`（`-S` 才会打印错误）
- 网络原因拉不到脚本：先在本地下载好，`scp` 上去再 `sudo bash 脚本名` 执行，效果一样

## 初始化之后（日常维护）

防火墙（ufw 已随系统启动自动生效，重启无需干预）：重跑 `05-ufw-ssh.sh` 进菜单即可——`4` 放行、`5` 删规则、`6` 启用/禁用、`7` 默认策略、`8` 业务端口清单，`3` 看状态总览。习惯命令行也行：

```bash
ufw status numbered          # 查看规则（带编号）
ufw allow 8080/tcp           # 放行新业务端口
ufw delete allow 8080/tcp    # 删除；或按编号：ufw delete <编号>
ufw status                   # 改完确认
```

- 放行/关闭端口的同看：**云平台安全组**要同步改，两边不一致就是"服务通不通"排查的常见坑
- SSH 端口、sudo 策略、公钥等想改：重跑对应脚本（04/05），会沿用 conf 里的现有参数，只改你选择修改的项
- fail2ban 改参数 / 看封禁 / 解封误封的 IP：重跑 `07-fail2ban.sh` 进菜单（`3` 改参数、`2` 看详情与封禁列表、`4` 封禁或解封）
- 系统补丁由 `01-base.sh` 装的 `unattended-upgrades` 自动打（security 源）；需要手动全量升级时重跑 `01-base.sh`
- 定期创建 Snapshot（大改动前后各一份）；12-verify.sh 随时可重跑当体检

## 脚本约定（开发者视角）

- 每个脚本自包含（公共函数内联，不依赖仓库里其他文件）、幂等、中文交互，单独拉取即可运行
- 修改系统配置前先备份到 `/root/vps-init-backups/<时间戳>/`，失败不回滚（唯一例外：`05-ufw-ssh.sh` 菜单 10 从备份恢复时会先校验 `sshd -t`，失败就退回恢复前的版本）
- 公共函数在脚本间保持一致；改动后运行 `bash tools/sync_check.sh` 自查（输出「一致性 OK」才算通过）。公共块里的关键行（如 `shopt -s inherit_errexit`）也纳入该工具检查——它不属于任何函数体，漏加不会被函数比对拦住
- 术语表见 [CONTEXT.md](CONTEXT.md)；为什么没有总控脚本见 [docs/adr/0001-no-orchestrator.md](docs/adr/0001-no-orchestrator.md)，哪些步骤被合并、步骤号前缀怎么算见 [docs/adr/0002-script-consolidation.md](docs/adr/0002-script-consolidation.md)
