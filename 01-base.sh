#!/usr/bin/env bash
# VPS 初始化 · 01–02 系统准备（系统更新 + 基础工具）
# 自包含 + 幂等 + 交互闸门。用法：sudo bash 01-base.sh
# 覆盖 README 步骤 1–2：apt update/full-upgrade → 装基础工具 → 最后才问重启
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/01-base.sh

set -euo pipefail
# 命令替换默认不继承 errexit：不开这个，$(ask_input ...) 里的 die 只终止子 shell，
# 空值会被照常写进 conf。开启后交互读取遇 EOF/Ctrl-D 即中止脚本。（bash >= 4.4）
shopt -s inherit_errexit

# ============ 公共内联块（各脚本一致，修改需同步全部） ============
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CONF="/root/.vps-init.conf"
BK_ROOT="/root/vps-init-backups"

if [[ -t 1 ]]; then
  C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi

log()  { printf '%s[%s]%s %s\n' "${C_B}" "${SCRIPT_NAME}" "${C_0}" "$*"; }
warn() { printf '%s[%s]%s %s\n' "${C_Y}" "${SCRIPT_NAME}" "${C_0}" "$*" >&2; }
die()  { printf '%s[%s]%s %s\n' "${C_R}" "${SCRIPT_NAME}" "${C_0}" "$*" >&2; exit 1; }

err_trap() { die "行 ${1}: ${2}"; }
trap 'err_trap "${LINENO}" "${BASH_COMMAND}"' ERR

require_root()   { [[ "${EUID}" -eq 0 ]] || die "需要 root 运行，请用：sudo bash ${SCRIPT_NAME}"; }
require_tty()    { [[ -t 0 ]] || die "需要交互终端运行，不支持无人值守（防锁死设计）"; }
require_distro() {
  local id
  id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
  [[ "${id}" == "debian" || "${id}" == "ubuntu" ]] || die "仅支持 Debian/Ubuntu，当前发行版：${id:-未知}"
}

ask_yesno() {
  local prompt="$1" def="${2:-n}" ans hint
  case "${def}" in
    y|Y) def=y; hint="[Y/n]" ;;
    *)   def=n; hint="[y/N]" ;;
  esac
  while :; do
    read -rp "${prompt} ${hint} " ans || return 1
    ans="${ans:-${def}}"
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     printf '%s无效输入，请输入 y 或 n。\n' "${C_Y}" >&2 ;;
    esac
  done
}

ask_input() {
  local prompt="$1" v="$2" val
  while :; do
    read -rp "${prompt} " val || die "输入中断"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
}

ask_input_def() {
  # ask_input_def <提示> <校验函数名> <默认值>——空输入取默认值
  local prompt="$1" v="$2" def="$3" val
  while :; do
    read -rp "${prompt} [回车=建议: ${def}] " val || die "输入中断"
    val="${val:-${def}}"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
}

backup_file() {
  local path="$1" stamp dir
  [[ -e "${path}" ]] || { printf ''; return 0; }
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="${BK_ROOT}/${stamp}"
  mkdir -p "${dir}"
  cp -a "${path}" "${dir}/"
  printf '%s已备份 %s -> %s/\n' "${C_G}" "${path}" "${dir}" >&2
  printf '%s' "${dir}"
}

conf_has()   { grep -q "^${1}=" "${CONF}" 2>/dev/null; }
conf_read()  { sed -n "s/^${1}='\\(.*\\)'\$/\\1/p" "${CONF}" 2>/dev/null | head -n 1 || true; }   # || true：conf 缺失或 head 早退（SIGPIPE）时输出空串，不中断
conf_write() {
  # conf 首次创建即 600（幂等：已 600 无变化）
  local k="$1" v="$2"
  v="${v//\'/\'\\\'\'}"
  touch "${CONF}" 2>/dev/null || :
  chmod 600 "${CONF}"
  printf "%s='%s'\n" "${k}" "${v}" >> "${CONF}"
}

conf_get() {
  local k="$1" prompt="$2" v="$3" val
  if conf_has "${k}"; then
    val="$(conf_read "${k}")"
    if "${v}" "${val}" >/dev/null 2>&1; then
      printf '%s%s 已配置（conf）\n' "${C_G}" "${k}" >&2
      printf '%s' "${val}"
      return 0
    fi
    warn "conf 中 ${k} 不合法，重新询问"
    sed -i "/^${k}=/d" "${CONF}" 2>/dev/null || :   # 清掉所有同名旧行（含非法值），防 head -1 永远读到坏值
  fi
  val="$(ask_input "${prompt}" "${v}")"
  conf_write "${k}" "${val}"
  printf '%s%s 已保存到 %s\n' "${C_G}" "${k}" "${CONF}" >&2
  printf '%s' "${val}"
}

# 公共校验器：合法返回 0，非法打印原因返回 1
v_any()      { return 0; }
v_yesno()    { [[ "$1" == "yes" || "$1" == "no" ]] || { printf '须为 yes 或 no\n' >&2; return 1; }; }
v_ssh_port() {
  local p="$1"
  [[ "${p}" =~ ^[0-9]+$ ]]           || { printf '端口须为数字\n' >&2; return 1; }
  (( p >= 1024 && p <= 65535 ))      || { printf '端口需在 1024-65535\n' >&2; return 1; }
  [[ "${p}" != "22" && "${p}" != "2222" ]] || { printf '避开常用端口 22/2222\n' >&2; return 1; }
  return 0
}
v_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { printf '用户名不合法（小写字母开头，允许 a-z 0-9 _ -）\n' >&2; return 1; }
  return 0
}
v_ports_list() {
  local s="$1" p
  [[ -z "${s}" ]] && return 0
  for p in ${s//,/ }; do
    [[ "${p}" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || { printf '端口列表含非法项：%s\n' "${p}" >&2; return 1; }
  done
  return 0
}
v_pubkey() {
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" =~ ^(ssh|ecdsa)- ]] || { printf '公钥应以 ssh- 或 ecdsa- 开头：%s\n' "${line:0:40}" >&2; return 1; }
  done <<< "$1"
  return 0
}


# ============ 公共内联块结束 ============

require_root
require_tty
require_distro

log "开始系统更新（apt update + full-upgrade）"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get full-upgrade -y

# ---------- 基础工具 ----------
# TOOLS_EXTRA 有默认值，读不到则询问（空输入取默认）
TOOLS_EXTRA=""
if conf_has "TOOLS_EXTRA"; then
  TOOLS_EXTRA="$(conf_read "TOOLS_EXTRA")"
  log "TOOLS_EXTRA 已配置（conf）：${TOOLS_EXTRA}"
else
  TOOLS_EXTRA="$(ask_input_def "额外工具（空格分隔；默认含 jq tmux lsof rsync zip，无需可留空）" v_any "jq tmux lsof rsync zip")"
  conf_write "TOOLS_EXTRA" "${TOOLS_EXTRA}"
  log "TOOLS_EXTRA 已保存：${TOOLS_EXTRA}"
fi

BASE="sudo ca-certificates curl wget gnupg ufw fail2ban unattended-upgrades vim nano unzip htop needrestart ncdu mtr-tiny bind9-dnsutils"
# 必要项：sudo/ca-certificates/curl/wget（后续步骤与 raw 拉取的前提，wget 兼容只用 wget 的第三方脚本）、
#   gnupg（第三方源签名）、ufw/fail2ban/unattended-upgrades（05/07/12 的检查项）、vim+nano（手动步骤改配置）
# 实用项：unzip/htop、needrestart（自动更新后重启受影响服务，缺它则 libc/openssl 补丁装了不生效；
#   非交互下只列清单不提问；手动/第三方脚本里跑 apt 有终端时会插问 l/i/a，答 i 即重启）、
#   ncdu（磁盘占满定位）、mtr-tiny（逐跳丢包）、bind9-dnsutils（dig/nslookup，Debian 11/Ubuntu 20.04 起）
# 仍不预装：tcpdump/strace/sysstat 等有提权面或需额外启用的诊断类，用到再装
# git 按"要用再装"原则不列入默认（写入 TOOLS_EXTRA 即可）

log "安装基础工具……"
# 索引已在上面 update 过，这里直接装；空 TOOLS_EXTRA 时 word-splitting 为无参数，安全
apt-get install -y ${BASE} ${TOOLS_EXTRA}

# ---------- 启用自动安全更新 ----------
# 关键：装包 ≠ 启用。20auto-upgrades 只在 dpkg-reconfigure 时生成，apt 装完默认是
# 两行 "0"（等于关闭），12-verify 会判红。这里直接写（幂等，重跑覆盖为同内容）。
# 具体升级哪些源由 50unattended-upgrades 决定（Debian/Ubuntu 默认含 security）。
UA_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > "${UA_FILE}"
chmod 644 "${UA_FILE}"
# 定时器：Debian 由 apt 包自带并默认启用，这里显式拉起来兜底
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || \
  warn "apt-daily 定时器启用失败，请手动检查：systemctl status apt-daily.timer"
log "自动安全更新已启用（${UA_FILE}）"

log "本次安装包：${BASE} ${TOOLS_EXTRA}"

# ---------- 重启询问（放在最后：工具已装好，一次重启即可收尾） ----------
# /var/run/reboot-required 由 needrestart 等钩子在需要重启时创建
if [[ -f /var/run/reboot-required ]]; then
  warn "检测到需要重启（通常为内核更新）"
  if ask_yesno "现在重启吗？重启后重新登录并继续后续步骤" y; then
    log "即将重启，重启后从 README 下一步继续"
    systemctl reboot
    exit 0
  else
    warn "跳过重启：后续安全基线建立在旧内核上，建议尽快手动重启"
  fi
else
  log "无需重启"
fi

log "第 1–2 步完成"
