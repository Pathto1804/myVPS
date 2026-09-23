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

conf_update() {
  # conf_update <KEY> <值>：已存在则替换该行，否则追加
  # 值经 sed 转义（\ & | 分隔符），防止注入破坏 sed 表达式
  local k="$1" v="$2"
  local esc
  esc="${v//\\/\\\\}"
  esc="${esc//|/\\|}"
  esc="${esc//&/\\&}"
  if conf_has "${k}"; then
    sed -i "s|^${k}=.*|${k}='${esc}'|" "${CONF}"
  else
    conf_write "${k}" "${v}"
  fi
}

# 公共校验器：合法返回 0，非法打印原因返回 1
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

# 列出系统普通用户（UID>=1000 且有可用 shell），仅作换人时的参考提示
list_human_users() {
  local u uid shell
  while IFS=: read -r u _ uid _ _ _ shell; do
    [[ "${uid}" -ge 1000 ]] || continue
    [[ "${shell}" == */nologin || "${shell}" == */false ]] && continue
    [[ "${u}" != "${ADMIN_USER}" ]] && printf '%s ' "${u}"
  done < <(getent passwd)
}

# 选择目标用户：conf 有值时允许确认或换人（支持管理任意已有用户）
ADMIN_USER=""
if conf_has "ADMIN_USER"; then ADMIN_USER="$(conf_read "ADMIN_USER")"; fi
if v_user "${ADMIN_USER}" >/dev/null 2>&1; then
  if ask_yesno "管理用户 ${ADMIN_USER}（上次操作的用户）？" y; then
    :
  else
    printf '系统现有普通用户：%b\n' "$(list_human_users 2>/dev/null || true)"
    ADMIN_USER="$(ask_input "要管理的用户名（新建或已有均可）" v_user)"
    conf_update "ADMIN_USER" "${ADMIN_USER}"
    log "ADMIN_USER 已更新为 ${ADMIN_USER}"
    warn "注意：sudo 免密与公钥在 conf 中是全局键，切换用户后请核对下面显示的当前值再决定是否修改"
  fi
else
  ADMIN_USER="$(ask_input "要管理的用户名（新建或已有均可）" v_user)"
  conf_update "ADMIN_USER" "${ADMIN_USER}"
fi

# 不存在则创建；已存在则直接管理（补 sudo 组、公钥、sudo 策略）
if id "${ADMIN_USER}" &>/dev/null; then
  log "用户 ${ADMIN_USER} 已存在，进入管理模式（可修改其 sudo 策略与公钥）"
else
  log "创建用户 ${ADMIN_USER}"
  adduser --gecos "" "${ADMIN_USER}"
fi
usermod -aG sudo "${ADMIN_USER}"
log "已加入 sudo 组"

# ----- 登录密码：自己输入 / 生成随机 / 跳过；随机密码显示一次，不进 conf 不落盘 -----
# passwd -S 状态：P=有可用密码 / NP=无密码 / L=锁定（adduser --gecos "" 创建的用户为 NP/L，
# 不设密码则 sudo 密码模式无法验证）。无密码默认问；已有密码默认跳过
PW_STATUS="$(passwd -S "${ADMIN_USER}" 2>/dev/null | awk '{print $2}')"
if [[ "${PW_STATUS}" == "P" ]]; then
  HAS_PW=1
else
  HAS_PW=0
  if [[ -z "${PW_STATUS}" ]]; then
    warn "无法读取密码状态（passwd -S 失败），按无密码处理"
  fi
fi

gen_random_pw() {
  # 22 位随机密码（大小写+数字，无易混淆字符）；openssl 不可用时退回 /dev/urandom
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-22
  else
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 22
  fi
}

apply_random_pw() {
  local pw
  pw="$(gen_random_pw)"
  printf '%s生成的密码（仅显示这一次，请立即保存到密码管理器）：%s%s%s\n' "${C_Y}" "${C_B}" "${pw}" "${C_0}"
  printf '%s:%s\n' "${ADMIN_USER}" "${pw}" | chpasswd
  printf '%s密码已设置\n' "${C_G}"
  unset pw
}

if [[ "${HAS_PW}" == "1" ]]; then
  if ask_yesno "要修改 ${ADMIN_USER} 的登录密码吗？" n; then
    printf '  1) 自己输入  2) 生成随机密码\n'
    OP_PW=""
    while :; do
      read -rp "选择 [1-2] " OP_PW || die "输入中断"
      [[ "${OP_PW}" == "1" || "${OP_PW}" == "2" ]] && break
      printf '请输入 1 或 2。\n'
    done
    if [[ "${OP_PW}" == "2" ]]; then
      apply_random_pw
    else
      passwd "${ADMIN_USER}"
    fi
  fi
else
  printf '  1) 自己输入  2) 生成随机密码  3) 稍后手动设置\n'
  OP_PW=""
  while :; do
    read -rp "${ADMIN_USER} 当前无登录密码（sudo 密码模式会卡死），选择设置方式 [1-3] " OP_PW || die "输入中断"
    [[ "${OP_PW}" == "1" || "${OP_PW}" == "2" || "${OP_PW}" == "3" ]] && break
    printf '请输入 1、2 或 3。\n'
  done
  if [[ "${OP_PW}" == "2" ]]; then
    apply_random_pw
  elif [[ "${OP_PW}" == "1" ]]; then
    passwd "${ADMIN_USER}"
  else
    warn "未设置密码：sudo 使用密码模式时该用户将无法验证，请尽快手动 passwd ${ADMIN_USER}"
  fi
fi

HOME_DIR="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
[[ -n "${HOME_DIR}" ]] || die "无法解析 ${ADMIN_USER} 主目录"
log "主目录：${HOME_DIR}"

# ----- sudo 策略：可查看/修改/翻转（对新建和已有用户行为一致）-----
SUDOERS_FILE="/etc/sudoers.d/${ADMIN_USER}"
CONF_NOPW=""
if conf_has "SUDO_NOPASSWD"; then CONF_NOPW="$(conf_read "SUDO_NOPASSWD")"; fi
[[ "${CONF_NOPW}" == "yes" || "${CONF_NOPW}" == "no" ]] || CONF_NOPW=""
if [[ -f "${SUDOERS_FILE}" ]]; then
  SYS_STATE="yes（sudoers 文件存在）"
else
  SYS_STATE="no（无 sudoers 文件）"
fi
log "sudo 免密当前状态：conf=${CONF_NOPW:-未配置} / 系统：${SYS_STATE}"
if ask_yesno "要修改 ${ADMIN_USER} 的 sudo 免密设置吗？" n; then
  SUDO_NOPASSWD="$(ask_input "sudo 免密？(no=需密码 / yes=免密)" v_yesno)"
  conf_update "SUDO_NOPASSWD" "${SUDO_NOPASSWD}"
  if [[ "${SUDO_NOPASSWD}" == "yes" ]]; then
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
    if [[ -f "${SUDOERS_FILE}" ]]; then
      backup_file "${SUDOERS_FILE}" >/dev/null
      rm -f "${SUDOERS_FILE}"
      if ! visudo -c >/dev/null 2>&1; then
        die "删除后 sudoers 校验失败，请立即检查 /etc/sudoers.d/"
      fi
      log "已移除 NOPASSWD 规则（sudo 恢复密码验证）"
    else
      log "sudo 使用密码（无 sudoers 文件，无需改动）"
    fi
  fi
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

# 公钥管理：显示现状，默认跳过；可追加 / 删除（新建和已有用户行为一致）
log "公钥现状：conf 已配置 ${#PUBKEYS[@]} 个"
if ask_yesno "要修改 ${ADMIN_USER} 的公钥吗？（追加或删除）" n; then
  printf '  1) 追加公钥  2) 删除公钥  3) 返回\n'
  OP=""
  while :; do
    read -rp "选择操作 [1-3] " OP || die "输入中断"
    [[ "${OP}" == "1" || "${OP}" == "2" || "${OP}" == "3" ]] && break
    printf '请输入 1、2 或 3。\n'
  done
  if [[ "${OP}" == "1" ]]; then
    printf '粘贴公钥（每行一个，输入空行结束）：\n'
    RAW=""
    while IFS= read -r line; do
      [[ -z "${line}" ]] && break
      RAW+="${line}"$'\n'
    done
  elif [[ "${OP}" == "2" ]]; then
    if [[ "${#PUBKEYS[@]}" -eq 0 ]]; then
      log "conf 中没有可删除的公钥"
    else
      printf '当前已配置的公钥：\n'
      i=1
      for k in "${PUBKEYS[@]}"; do
        printf '  %d) %s...%s\n' "${i}" "${k:0:24}" "${k: -12}"
        i=$((i + 1))
      done
      PICK=""
      while :; do
        read -rp "删除第几把？[1-${#PUBKEYS[@]}]（回车取消） " PICK || die "输入中断"
        [[ -z "${PICK}" ]] && break
        [[ "${PICK}" =~ ^[0-9]+$ ]] && (( PICK >= 1 && PICK <= ${#PUBKEYS[@]} )) && break
        printf '输入超出范围，重填。\n'
      done
      if [[ -n "${PICK:-}" ]]; then
        DEL_KEY="${PUBKEYS[$((PICK - 1))]}"
        printf '将删除：%s\n' "${DEL_KEY}"
        if ask_yesno "确认删除这把公钥？" n; then
          declare -a TMP=()
          for k in "${PUBKEYS[@]}"; do
            [[ "${k}" == "${DEL_KEY}" ]] || TMP+=("${k}")
          done
          PUBKEYS=("${TMP[@]}")
          log "已从配置中移除该公钥（authorized_keys 稍后统一重写）"
        fi
      fi
    fi
  fi
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

# 写 authorized_keys：按 conf 现值全量重写（追加与删除统一生效）
SSH_DIR="${HOME_DIR}/.ssh"
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
AK="${SSH_DIR}/authorized_keys"
OWNER_GID="$(id -g "${ADMIN_USER}")"
AK_TMP="${AK}.tmp.$$"
install -m 600 -o "${ADMIN_USER}" -g "${OWNER_GID}" /dev/null "${AK_TMP}"
if [[ -f "${AK}" ]]; then
  backup_file "${AK}" >/dev/null
fi
for k in "${PUBKEYS[@]}"; do
  grep -qFx -- "${k}" "${AK}" 2>/dev/null && printf '%s\n' "${k}" >> "${AK_TMP}"
done
mv "${AK_TMP}" "${AK}"
chown "${ADMIN_USER}:${OWNER_GID}" "${SSH_DIR}" "${AK}"
chmod 700 "${SSH_DIR}"; chmod 600 "${AK}"
log "authorized_keys 已更新：${#PUBKEYS[@]} 个公钥"
log "第 4 步完成"
log "闸门：新开终端验证 ssh ${ADMIN_USER}@<host> 密钥登录 + sudo -v；通过前禁止执行 05/06"