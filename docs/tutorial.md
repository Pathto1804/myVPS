# VPS 初始化手动教程

不用任何脚本，一条一条敲命令，把 VPS 初始化完整做一遍。适合想搞清楚每条命令在干什么的人；跑过一遍之后再看 README 的脚本，每个步骤为什么那么设计就都明白了。

> 两点说明：
> 1. 这页内容和仓库里的脚本保持同一套做法，脚本改了这里也跟着改。三条铁律看 [README](../README.md)，手动做同样要遵守，尤其"改配置时别关当前窗口"。
> 2. 命令默认以 root 运行（云厂商一般直接给 root，或者先 `sudo -i`）。

## 0. 云平台基础检查

```bash
cat /etc/os-release                          # 确认发行版与版本
nproc; free -h; df -h                        # CPU / 内存 / 磁盘
sshd -T 2>/dev/null | grep ^port             # 当前 SSH 端口（厂商可能不是 22！）
```

然后到**云平台控制台**：

- 记录安全组当前放行规则——注意放行的是不是上面查到的那个端口
- **创建初始 Snapshot**——后面所有步骤的最终退路，唯一不可替代的一步

本地机器上准备好 SSH 密钥（已有则跳过）：

```bash
ssh-keygen -t ed25519
cat ~/.ssh/id_ed25519.pub                    # 稍后步骤 4 要用
```

## 1. 系统更新

```bash
apt update
apt full-upgrade -y
cat /var/run/reboot-required 2>/dev/null     # 文件不存在则无需重启
```

`apt update` 是"看看有哪些更新"，`full-upgrade` 是"真的装"。只会小版本升级，**不会**把 24.04 变成 26.04，放心跑。如果 `reboot-required` 文件存在，说明更新了内核，需要重启一次：

```bash
reboot
```

重启完重新连上就行。想确认的话：`uname -r` 显示的版本应该变了。

## 2. 基础工具

```bash
apt install -y sudo ca-certificates curl wget gnupg ufw fail2ban \
  unattended-upgrades vim nano unzip htop jq tmux lsof rsync zip
```

一条装齐（必装 + 高频工具）。诊断类（tcpdump/mtr/ncdu 等）用到再装，不预装。

## 3. 系统基础配置

```bash
hostnamectl set-hostname <主机名>            # 可选，保持厂商默认可跳过
timedatectl set-timezone Asia/Shanghai
timedatectl                                  # 确认 "NTP service: active"
```

服务器时间不准会出各种怪问题（登录记录时间错乱、HTTPS 证书报错），所以确认时间同步是开着的。

## 4. 创建管理员用户 + 公钥

```bash
adduser <用户名>                             # 交互设置密码
usermod -aG sudo <用户名>                    # 加入 sudo 组
su - <用户名>                                # 切过去验证 sudo 可用
sudo -v                                      # 输密码通过即 OK
exit
```

把你本地刚生成的公钥写进这台机器。700/600 这两个权限是 SSH 的硬要求，权限不对 SSH 会直接拒绝密钥登录：

```bash
mkdir -p /home/<用户名>/.ssh
chmod 700 /home/<用户名>/.ssh
nano /home/<用户名>/.ssh/authorized_keys     # 粘贴你的公钥，一行一个
chmod 600 /home/<用户名>/.ssh/authorized_keys
chown -R <用户名>:<用户名> /home/<用户名>/.ssh
```

> **⚠️ 停下来验证**：本地新开一个终端，`ssh <用户名>@<host>` 能登上、`sudo -v` 不报错——都通过了再继续。**登不上就停下排查，别往下做**（后面会把密码登录关掉，到时候只能靠这个密钥进机器）。

## 5. UFW 防火墙

先想好新的 SSH 端口（随便挑一个大数，比如 23456，别用 22 和 2222），然后：

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow <当前端口>/tcp                     # 临时规则！从第 0 步查到的实际端口
ufw allow <新端口>/tcp
ufw allow 80/tcp                             # 业务端口按需
ufw allow 443/tcp
ufw enable
ufw status verbose                           # 检查点：当前端口和新端口都必须在列表
```

**这步最容易把自己锁在门外**：`ufw enable` 之前，盯着 `ufw allow` 的输出确认**当前端口**和**新端口**都放行了——当前端口没放行，enable 的那一秒你的连接就断了。

## 6. SSH 加固

```bash
ls /etc/ssh/sshd_config.d/                   # 看有没有 50-cloud-init.conf 之类的覆盖文件
cp /etc/ssh/sshd_config.d/01-hardening.conf /root/01-hardening.conf.bak 2>/dev/null
nano /etc/ssh/sshd_config.d/01-hardening.conf
```

写入下面内容。文件名用 `01-` 开头有讲究：SSH 读配置时排在前面的说了算，云厂商自带的 `50-cloud-init.conf` 里可能有相反设置，`01-` 能压过它：

```
Port <新端口>
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers <用户名>
MaxAuthTries 3
```

验证配置真的生效了（配置文件写对 ≠ 生效，所以要看系统实际读到的值）：

```bash
sshd -t                                      # 无输出即语法正确
sshd -T | grep -Ei 'port|passwordauthentication|permitrootlogin'
# 必须看到：port <新端口> / passwordauthentication no / permitrootlogin no
```

> **闸门二（人工执行）**：reload 前确认密钥登录可用（闸门一已过）；然后：

```bash
systemctl reload ssh
```

**这个窗口千万别关**（它是你的退路）。新开一个终端，用新端口连一次：`ssh -p <新端口> <用户名>@<host>`，能登上、root 登不进，就对了。然后到**云平台控制台**把安全组改成关旧端口、开新端口。都确认没问题了，才可以关掉旧窗口。最后删掉旧端口的临时放行：

```bash
ufw delete allow <当前端口>/tcp              # 旧端口确认无用后删
```

万一锁在门外：云控制台/VNC 进去，把备份文件恢复回去，再 `systemctl reload ssh` 就回来了。所以第 0 步的 Snapshot 一定要拍。

## 7. fail2ban

```bash
nano /etc/fail2ban/jail.local
```

写入下面内容。`port` 必须写**新端口**——不写的话它只盯着 22，等于白装。`backend = systemd` 照抄就行（新版系统必须这么写才工作）：

```
[sshd]
enabled = true
port = <新端口>
backend = systemd
bantime = 86400
findtime = 600
maxretry = 3
```

```bash
systemctl enable --now fail2ban
fail2ban-client status sshd                  # 检查点：jail 列表里有 sshd
```

## 8. Swap

```bash
free -h                                      # 先看现状
fallocate -l 2G /swapfile                    # 小内存机 1–2G，大内存可跳过此步
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab    # 持久化
sysctl vm.swappiness=10
echo 'vm.swappiness = 10' > /etc/sysctl.d/99-swappiness.conf
```

检查点：`swapon --show` 有输出就对了。重启之后再跑一次，还有输出说明开机自动挂载也配好了。

## 9. BBR + TCP 调优

两行配置就够用：

```bash
cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl -p /etc/sysctl.d/99-bbr.conf
sysctl net.ipv4.tcp_congestion_control       # 检查点：输出 bbr
```

想进一步调网络参数的话，仓库里 `09-bbr.sh` 有一份完整参数集，但那份是为特定场景调的，不懂每项含义别照抄。

## 10. 自动安全更新

```bash
apt install -y unattended-upgrades
cat /etc/apt/apt.conf.d/20auto-upgrades      # 两行都应为 "1"
```

Ubuntu 一般已经开着了；Debian 装的时候会问你，选"是"。之后安全补丁系统自己装，你不用管。

## 11. Docker（提示）

这次初始化不装 Docker。以后要装就去 [docs.docker.com](https://docs.docker.com/engine/install/) 照官方文档来。提醒一句：把自己加进 `docker` 组基本等于 root 权限，知道这点再决定加不加。装完跑 `docker run --rm hello-world` 能出欢迎信息就 OK。

## 12. 终检

把下面命令挨个跑一遍，输出符合注释就是通过（脚本 `12-verify.sh` 自动做的就是这些）：

```bash
sshd -T | grep -Ei 'port|passwordauthentication|permitrootlogin'
ufw status                                   # 新端口在、旧端口不在
fail2ban-client status sshd
cat /etc/apt/apt.conf.d/20auto-upgrades
swapon --show
sysctl net.ipv4.tcp_congestion_control       # bbr
timedatectl | grep -E 'NTP|synchronized'
df -h /
```

**云安全组要去云平台网页上看**：旧端口关了没、新端口开了没——这是机器上的命令查不到的，只能自己上控制台看。

## 13. 归档

- 找个地方记下：SSH 端口、用户名、放行了哪些端口（脚本版会自动生成 `/root/vps-init-report.md`，手动版自己记，别丢了端口号）
- 云平台创建最终 Snapshot
