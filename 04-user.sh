#!/usr/bin/env bash
# VPS 初始化 · 04 创建管理员用户 + 公钥
# 自包含 + 幂等 + 交互闸门。用法：sudo bash 04-user.sh
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/04-user.sh

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
  local k="$1" v="$2"
  v="${v//\'/\'\\\'\'}"
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
  fi
  val="$(ask_input "${prompt}" "${v}")"
  conf_write "${k}" "${val}"
  printf '%s%s 已保存到 %s\n' "${C_G}" "${k}" "${CONF}" >&2
  printf '%s' "${val}"
}

v_any()   { return 0; }
v_yesno() { [[ "$1" == "yes" || "$1" == "no" ]] || { printf '须为 yes 或 no\n' >&2; return 1; }; }
v_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { printf '用户名不合法（小写字母开头，允许 a-z 0-9 _ -）\n' >&2; return 1; }
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

# ==================== 脚本主体 ====================

require_root
require_tty
require_distro

ADMIN_USER="$(conf_get "ADMIN_USER" "管理员用户名" v_user)"

# 用户可能已被供应商预置，也可能需要新建；两条路径后都确保在 sudo 组 + 有主目录
if id "${ADMIN_USER}" &>/dev/null; then
  log "用户 ${ADMIN_USER} 已存在，跳过创建"
else
  log "创建用户 ${ADMIN_USER}"
  adduser --gecos "" "${ADMIN_USER}"
fi
usermod -aG sudo "${ADMIN_USER}"
log "已加入 sudo 组"

HOME_DIR="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
[[ -n "${HOME_DIR}" ]] || die "无法解析 ${ADMIN_USER} 主目录"
log "主目录：${HOME_DIR}"

# ----- sudo 策略 -----
SUDO_NOPASSWD="$(conf_get "SUDO_NOPASSWD" "sudo 免密？(no=需密码 / yes=免密)" v_yesno)"
if [[ "${SUDO_NOPASSWD}" == "yes" ]]; then
  SUDOERS_FILE="/etc/sudoers.d/${ADMIN_USER}"
  backup_file "${SUDOERS_FILE}" >/dev/null
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${ADMIN_USER}" > "${SUDOERS_FILE}"
  chmod 0440 "${SUDOERS_FILE}"
  chown root:root "${SUDOERS_FILE}"
  if ! visudo -c >/dev/null 2>&1; then
    rm -f "${SUDOERS_FILE}"
    die "sudoers 校验失败，已删除 ${SUDOERS_FILE}；请勿破坏 sudo"
  fi
  log "已写入 NOPASSWD 规则：${SUDOERS_FILE}"
else
  log "sudo 使用密码（默认）"
fi

# ----- SSH 公钥 -----
declare -a PUBKEYS=()
load_pubkeys_from_conf() {
  local i=1 k
  while :; do
    k="SSH_PUBKEY_${i}"
    if conf_has "${k}"; then
      PUBKEYS+=("$(conf_read "${k}")")
      i=$((i + 1))
    else
      break
    fi
  done
}
load_pubkeys_from_conf

if [[ "${#PUBKEYS[@]}" -eq 0 ]]; then
  log "conf 未配置公钥，开始交互粘贴"
  if ask_yesno "现在粘贴 ${ADMIN_USER} 的 SSH 公钥吗？" y; then
    RAW=""
    printf '粘贴公钥（每行一个，输入空行结束）：\n'
    while IFS= read -r line; do
      [[ -z "${line}" ]] && break
      RAW+="${line}"$'\n'
    done
  else
    log "跳过公钥配置（之后可重跑本脚本）"
  fi
else
  log "conf 已有 ${#PUBKEYS[@]} 个公钥，无需手动粘贴"
fi

# 解析用户粘贴的多行公钥，过滤非空且合法者
declare -a NEW_KEYS=()
if [[ -n "${RAW:-}" ]]; then
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    if ! v_pubkey "${line}" >/dev/null 2>&1; then
      warn "跳过非法公钥行：${line:0:40}..."
      continue
    fi
    NEW_KEYS+=("${line}")
  done <<< "${RAW}"
fi

for k in "${NEW_KEYS[@]}"; do
  PUBKEYS+=("${k}")
done
# 新键写入 conf（SSH_PUBKEY_N）；先清掉旧 N 键再统一回写，防重跑累积重复
while :; do
  if grep -q "^SSH_PUBKEY_[0-9]*=" "${CONF}" 2>/dev/null; then
    sed -i "/^SSH_PUBKEY_[0-9]*=/d" "${CONF}"
  else
    break
  fi
done
idx=1
for k in "${PUBKEYS[@]}"; do
  conf_write "SSH_PUBKEY_${idx}" "${k}"
  idx=$((idx + 1))
done

# 写 authorized_keys（追加而非覆盖：保留既有键，仅补缺失）
SSH_DIR="${HOME_DIR}/.ssh"
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
AK="${SSH_DIR}/authorized_keys"
OWNER_GID="$(id -g "${ADMIN_USER}")"
# 以目标属主/权限创建（不存在时），消除 root:root 644 中间态
[[ -e "${AK}" ]] || install -m 600 -o "${ADMIN_USER}" -g "${OWNER_GID}" /dev/null "${AK}"
for k in "${PUBKEYS[@]}"; do
  grep -qFx -- "${k}" "${AK}" 2>/dev/null || printf '%s\n' "${k}" >> "${AK}"
done
chown "${ADMIN_USER}:${OWNER_GID}" "${SSH_DIR}" "${AK}"
chmod 700 "${SSH_DIR}"; chmod 600 "${AK}"
log "authorized_keys 已更新：${#PUBKEYS[@]} 个公钥"
log "第 4 步完成"
log "闸门：新开终端验证 ssh ${ADMIN_USER}@<host> 密钥登录 + sudo -v；通过前禁止执行 05/06"