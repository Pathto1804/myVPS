#!/usr/bin/env bash
# VPS 初始化 · 05 UFW 防火墙
# 自包含 + 幂等 + 交互闸门。用法：sudo bash 05-ufw.sh
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/05-ufw.sh

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

# ==================== 脚本主体 ====================

require_root
require_tty
require_distro

# 旧端口：从 sshd 实际生效值读取（兼容厂商预置随机端口；不假设 22）
OLD_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' | tr -d '
')"
if ! [[ "${OLD_PORT}" =~ ^[0-9]+$ ]]; then
  die "无法读取 sshd 当前端口（sshd -T 失败），中止"
fi
log "sshd 当前端口：${OLD_PORT}"
if conf_has "OLD_SSH_PORT" && [[ "$(conf_read "OLD_SSH_PORT")" != "${OLD_PORT}" ]]; then
  warn "conf 记录的旧端口与 sshd 实际不一致，以 sshd 实际为准"
  sed -i "s/^OLD_SSH_PORT=.*/OLD_SSH_PORT='${OLD_PORT}'/" "${CONF}"
elif ! conf_has "OLD_SSH_PORT"; then
  conf_write "OLD_SSH_PORT" "${OLD_PORT}"
fi

# 端口：conf 无值时给随机建议值（回车采纳；手动输入则用输入值）
if conf_has "SSH_PORT" && v_ssh_port "$(conf_read "SSH_PORT")" >/dev/null 2>&1; then
  SSH_PORT="$(conf_get "SSH_PORT" "新 SSH 端口（1024-65535，避开 22/2222）" v_ssh_port)"
else
  SUGGEST="$(shuf -i 10000-65535 -n 1 2>/dev/null || echo 54321)"
  log "随机建议端口：${SUGGEST}（回车采纳，或自行输入）"
  SSH_PORT="$(ask_input_def "新 SSH 端口" v_ssh_port "${SUGGEST}")"
  conf_write "SSH_PORT" "${SSH_PORT}"
fi
ALLOWED_PORTS="$(conf_get "ALLOWED_PORTS" "额外放行端口（逗号分隔，如 80,443；空留空）" v_ports_list)"

log "配置 UFW：默认拒绝入站，仅放行 SSH 与业务端口"
ufw default deny incoming
ufw default allow outgoing

# 临时放行旧端口（改端口前旧端口仍需可用；06-ssh.sh 闸门确认后移除）
ufw allow "${OLD_PORT}/tcp"
ufw allow "${SSH_PORT}/tcp"
if [[ -n "${ALLOWED_PORTS}" ]]; then
  for p in ${ALLOWED_PORTS//,/ }; do
    ufw allow "${p}/tcp"
  done
fi

ufw --force enable
log "UFW 状态："
ufw status verbose
log "提醒：${OLD_PORT} 为临时规则，06-ssh.sh 闸门确认后移除"
log "第 5 步完成"