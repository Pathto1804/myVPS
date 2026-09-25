#!/usr/bin/env bash
# VPS 初始化 · 06 SSH 加固
# 自包含 + 幂等 + 交互闸门。用法：sudo bash 06-ssh.sh
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/06-ssh.sh
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

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

CONF="/root/.vps-init.conf"
BK_ROOT="/root/vps-init-backups"

v_ssh_port() {
  local p="$1"
  [[ "${p}" =~ ^[0-9]+$ ]]           || { printf '端口须为数字\n' >&2; return 1; }
  (( p >= 1024 && p <= 65535 ))      || { printf '端口需在 1024-65535\n' >&2; return 1; }
  [[ "${p}" != "22" && "${p}" != "2222" ]] || { printf '避开常用端口 22/2222\n' >&2; return 1; }
  return 0
}
conf_has()   { grep -q "^${1}=" "${CONF}" 2>/dev/null; }
conf_read()  { sed -n "s/^${1}='\\(.*\\)'\$/\\1/p" "${CONF}" 2>/dev/null | head -n 1; }

v_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { printf '用户名不合法（小写字母开头，允许 a-z 0-9 _ -）\n' >&2; return 1; }
  return 0
}

# ==================== 脚本主体 ====================

require_root; require_tty; require_distro

SSH_PORT=""
if conf_has "SSH_PORT"; then SSH_PORT="$(conf_read "SSH_PORT")"; fi
if ! v_ssh_port "${SSH_PORT}" >/dev/null 2>&1; then
  SUGGEST="$(shuf -i 10000-65535 -n 1 2>/dev/null || echo 54321)"
  log "随机建议端口：${SUGGEST}（回车采纳）"
  SSH_PORT="$(ask_input_def "新 SSH 端口" v_ssh_port "${SUGGEST}")"
fi
ADMIN_USER=""
if conf_has "ADMIN_USER"; then ADMIN_USER="$(conf_read "ADMIN_USER")"; fi
if ! v_user "${ADMIN_USER}" >/dev/null 2>&1; then
  ADMIN_USER="$(ask_input "管理员用户名" v_user)"
fi
# 旧端口：05 写入；conf 缺失时回退为 sshd 当前实际值（不假设 22）
OLD_PORT=""
if conf_has "OLD_SSH_PORT"; then OLD_PORT="$(conf_read "OLD_SSH_PORT")"; fi
if ! [[ "${OLD_PORT}" =~ ^[0-9]+$ ]]; then
  # awk 不早退（早退会让 sshd 收 SIGPIPE，pipefail 下赋值失败）；|| true 让失败落到下一行的默认值
  OLD_PORT="$(sshd -T 2>/dev/null | awk '/^port /{p=$2} END{print p}' | tr -d '\r')" || true
fi
[[ "${OLD_PORT}" =~ ^[0-9]+$ ]] || OLD_PORT="22"

# ---------- 前置自检 ----------
SSHD_CFG="/etc/ssh/sshd_config"
SSHD_D="/etc/ssh/sshd_config.d"
[[ -f "${SSHD_CFG}" ]] || die "未找到 ${SSHD_CFG}"
grep -q '^Include' "${SSHD_CFG}" || die "需先在 sshd_config 启用 Include drop-in（本流程依赖 drop-in 覆盖）"

if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -q '^Status: active'; then
    if ! ufw status | grep -qw "${SSH_PORT}/tcp"; then
      die "ufw 已启用但未放行 ${SSH_PORT}/tcp。请先运行 05-ufw.sh（铁律：UFW 先于 sshd）"
    fi
  else
    die "ufw 未启用。请先运行 05-ufw.sh（铁律：UFW 先于 sshd）"
  fi
fi

# ---------- 检查 drop-in 覆盖项（cloud-init 常见） ----------
HARD="/etc/ssh/sshd_config.d/01-hardening.conf"
if [[ -d "${SSHD_D}" ]]; then
  for f in "${SSHD_D}"/*.conf; do
    [[ -f "${f}" ]] || continue
    [[ "${f}" == "${HARD}" ]] && continue   # 本脚本自己的输出，不算覆盖项（幂等重跑）
    if grep -q '^PasswordAuthentication' "${f}" 2>/dev/null; then
      if [[ "${f}" < "${HARD}" ]]; then
        printf '%s警告：%s 排序在 01- 之前且含 PasswordAuthentication，会压过本脚本的配置。\n' "${C_Y}" "${f}" >&2
      else
        printf '%s提示：%s 含 PasswordAuthentication，但排序在 01- 之后，被 01- 压住、不会生效。\n' "${C_Y}" "${f}" >&2
      fi
    fi
  done
fi

# ---------- 写入 01-hardening.conf ----------
backup_file "${HARD}" >/dev/null || true
printf 'Port %s\nPermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAllowUsers %s\nMaxAuthTries 3\n' \
  "${SSH_PORT}" "${ADMIN_USER}" > "${HARD}"


# ---------- sshd -t 语法校验（失败即退出，防止坏配置压死 ssh）----------
if ! sshd -t; then
  warn "sshd -t 校验失败。请检查 ${HARD}；可用备份还原：/root/vps-init-backups/"
  exit 1
fi

# ---------- sshd -T 验证实际生效值 ----------
ACTUAL_PORT="$(sshd -T 2>/dev/null | awk '/^port /{p=$2} END{print p}' | tr -d '\r')" || true
if [[ "${ACTUAL_PORT}" != "${SSH_PORT}" ]]; then
  warn "sshd -T 实际端口 ${ACTUAL_PORT:-未知} != 期望 ${SSH_PORT}"
  warn "多半是 ${SSHD_D}/ 下的覆盖文件抢了优先权（先出现者优先）；请检查后重跑"
  exit 1
fi
log "sshd -T 确认：端口 ${ACTUAL_PORT}、debug 通过"

# ---------- 闸门一：密钥登录验证（铁律 2）----------
if ! ask_yesno "已在 04 后用新终端验证过 ${ADMIN_USER} 的密钥登录吗？" n; then
  die "先验证密钥登录再加固。本脚本尚未 reload ssh，当前 ssh 配置未变，可安全退出"
fi

# ---------- 应用配置 ----------
# Ubuntu 22.10+ 等默认用 ssh.socket 套接字激活：监听端口由 socket 单元决定，
# sshd_config 的 Port 不生效（sshd -T 只读配置文件，会"骗人"）。统一转回标准
# ssh.service 模式，让端口、AllowUsers 等策略真正生效。
if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
  log "检测到 ssh.socket 套接字激活，切换回标准 ssh.service 模式（否则新端口不生效）"
  systemctl disable --now ssh.socket
  systemctl enable ssh.service
fi
systemctl restart ssh || die "ssh 启动失败（sshd -t 已过，多为权限/服务名问题）；备份在 /root/vps-init-backups/"
log "sshd 已生效：新端口 ${SSH_PORT}"

# 自检：端口监听
if command -v ss >/dev/null 2>&1; then
  ss -tln | awk '{print $4}' | grep -qE "[:.]${SSH_PORT}$" || warn "未见端口 ${SSH_PORT} 监听，请手动检查"
fi

log ""
log "保持【本会话】不断开！请操作："
log "  1) 新开终端：ssh -p ${SSH_PORT} ${ADMIN_USER}@<host>  —— 必须密钥登录成功且 root 被拒"
log "  2) 同步云平台安全组：关 ${OLD_PORT}、开 ${SSH_PORT}（只能你手动做）"
log ""

# ---------- 闸门二：新终端验证（铁律 3）----------
if ask_yesno "新终端已用新端口成功登录？" n; then
  if command -v ufw >/dev/null 2>&1 && [[ "${OLD_PORT}" != "${SSH_PORT}" ]] && ufw status | grep -qw "${OLD_PORT}/tcp"; then
    ufw delete allow "${OLD_PORT}/tcp"
    log "已移除 ${OLD_PORT} 临时放行规则（ufw）"
  fi
  log ""
  log "SSH 加固完成。提醒：云安全组若仍放行 ${OLD_PORT}，请手动关闭。"
  log "云厂商预置用户（如 ubuntu/admin）仍存在但已被 AllowUsers 屏蔽；确认不用可手动删除。"
else
  warn "未确认新端口可用。当前 ${OLD_PORT} 放行规则保持不动以保旧会话可回退。"
  warn "恢复指引：若已锁死，用云控制台/VNC 登录后还原 /root/vps-init-backups/ 下备份，再 systemctl reload ssh"
  exit 1
fi

log "第 6 步完成"
