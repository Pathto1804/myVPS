#!/usr/bin/env bash
# VPS 初始化 · 07 fail2ban
# 自包含 + 幂等 + 交互闸门。用法：sudo bash 07-fail2ban.sh
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/07-fail2ban.sh
set -euo pipefail

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
conf_read()  { sed -n "s/^${1}='\\(.*\\)'\$/\\1/p" "${CONF}" 2>/dev/null | head -n 1; }
conf_write() {
  # conf 首次创建即 600（幂等：已 600 无变化）
  local k="$1" v="$2"
  v="${v//\'/\'\\\'\'}"
  touch "${CONF}" 2>/dev/null || :
  chmod 600 "${CONF}"
  printf "%s='%s'\n" "${k}" "${v}" >> "${CONF}"
}

v_ssh_port() {
  local p="$1"
  [[ "${p}" =~ ^[0-9]+$ ]]           || { printf '端口须为数字\n' >&2; return 1; }
  (( p >= 1024 && p <= 65535 ))      || { printf '端口需在 1024-65535\n' >&2; return 1; }
  [[ "${p}" != "22" && "${p}" != "2222" ]] || { printf '避开常用端口 22/2222\n' >&2; return 1; }
  return 0
}
v_posint() { [[ "$1" =~ ^[0-9]+$ ]] || { printf '须为正整数\n' >&2; return 1; }; }

# ==================== 脚本主体 ====================

require_root; require_tty; require_distro

# SSH 端口：conf 优先，空则询问（含实际 sshd -T 校验）
SSH_PORT=""
if conf_has "SSH_PORT"; then SSH_PORT="$(conf_read "SSH_PORT")"; fi
if ! v_ssh_port "${SSH_PORT}" >/dev/null 2>&1; then
  SSH_PORT="$(ask_input "新 SSH 端口" v_ssh_port)"
fi
ACTUAL="$(sshd -T 2>/dev/null | awk '/^port /{p=$2} END{print p}' | tr -d '\r')" || true
if [[ -n "${ACTUAL}" && "${ACTUAL}" != "${SSH_PORT}" ]]; then
  die "sshd 实际端口 ${ACTUAL} != 配置 ${SSH_PORT}。请先完成 05/06（jail 端口必须与实际端口一致）"
fi

# fail2ban 参数：conf 优先，读不到才询问（带默认值）
conf_get_def() {
  local key="$1" prompt="$2" val
  if conf_has "${key}"; then
    val="$(conf_read "${key}")"
    if v_posint "${val}" >/dev/null 2>&1; then
      printf '%s%s 已配置（conf）
' "${C_G}" "${key}" >&2
      printf '%s' "${val}"; return 0
    fi
    warn "conf 中 ${key} 不合法，重新询问"
    sed -i "/^${key}=/d" "${CONF}" 2>/dev/null || :   # 清掉非法旧行，防 head -1 永远读到坏值
  fi
  val="$(ask_input_def "${prompt}" v_posint "$3")"
  conf_write "${key}" "${val}"
  printf '%s%s 已保存
' "${C_G}" "${key}" >&2
  printf '%s' "${val}"
}
F2B_BANTIME="$(conf_get_def "F2B_BANTIME" "封禁时长（秒）" 86400)"
F2B_FINDTIME="$(conf_get_def "F2B_FINDTIME" "统计窗口（秒）" 600)"
F2B_MAXRETRY="$(conf_get_def "F2B_MAXRETRY" "最大重试次数" 3)"

# 保存到 conf（幂等：已存在则更新）
for kv in "F2B_BANTIME=${F2B_BANTIME}" "F2B_FINDTIME=${F2B_FINDTIME}" "F2B_MAXRETRY=${F2B_MAXRETRY}"; do
  key="${kv%%=*}"; val="${kv#*=}"
  if conf_has "${key}"; then
    sed -i "s/^${key}=.*/${key}='${val}'/" "${CONF}"
  else
    conf_write "${key}" "${val}"
  fi
done

log "安装 fail2ban……"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y fail2ban

JAIL="/etc/fail2ban/jail.local"
backup_file "${JAIL}" >/dev/null || true
printf '[sshd]\nenabled = true\nport = %s\nbackend = systemd\nbantime = %s\nfindtime = %s\nmaxretry = %s\n' \
  "${SSH_PORT}" "${F2B_BANTIME}" "${F2B_FINDTIME}" "${F2B_MAXRETRY}" > "${JAIL}"

systemctl enable fail2ban
systemctl restart fail2ban

# 验证：restart 返回 ≠ jail 就绪（fail2ban 读配置、起 systemd backend、建 socket 需 1~2s）
# 立刻查询会误判"jail 未启动"，轮询等待
jail_ok=0
for _ in $(seq 1 20); do
  if fail2ban-client status sshd >/dev/null 2>&1; then jail_ok=1; break; fi
  sleep 0.5
done
if [[ "${jail_ok}" -ne 1 ]]; then
  warn "fail2ban sshd jail 10 秒内未就绪，请检查：systemctl status fail2ban; journalctl -u fail2ban -n 50"
  exit 1
fi
log "fail2ban sshd jail 已启用（端口 ${SSH_PORT} / ${F2B_MAXRETRY} 次 / ${F2B_BANTIME}s）"
fail2ban-client status sshd
log "第 7 步完成"
