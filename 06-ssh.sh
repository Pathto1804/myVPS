#!/usr/bin/env bash
# VPS 初始化 · 06 SSH 加固（首次执行加固流程，之后进入维护菜单）
# 自包含 + 幂等 + 交互闸门。用法：sudo bash 06-ssh.sh
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/06-ssh.sh
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

if [[ -t 1 ]]; then
  C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_D=$'\e[90m'; C_0=$'\e[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_D=''; C_0=''
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
conf_write() {
  # conf 首次创建即 600（幂等：已 600 无变化）
  local k="$1" v="$2"
  v="${v//\'/\'\\\'\'}"
  touch "${CONF}" 2>/dev/null || :
  chmod 600 "${CONF}"
  printf "%s='%s'\n" "${k}" "${v}" >> "${CONF}"
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

v_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { printf '用户名不合法（小写字母开头，允许 a-z 0-9 _ -）\n' >&2; return 1; }
  return 0
}

# ==================== sshd / ufw 辅助 ====================

SSHD_CFG="/etc/ssh/sshd_config"
SSHD_D="/etc/ssh/sshd_config.d"
HARD="${SSHD_D}/01-hardening.conf"

conf_val() {   # 读 conf 值；缺失输出空串
  local v=""
  if conf_has "$1"; then v="$(conf_read "$1")"; fi
  printf '%s' "${v}"
}

rand_port() { shuf -i 10000-65535 -n 1 2>/dev/null || printf '%s' 54321; }

sshd_port() {   # sshd 实际生效端口；读不到输出空串
  # awk 不早退（`exit` 会让 sshd 收 SIGPIPE，pipefail 下赋值失败）；|| true 让失败输出空串
  local p
  p="$(sshd -T 2>/dev/null | awk '/^port /{p=$2} END{print p}' | tr -d '\r')" || true
  [[ "${p}" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
  printf '%s' "${p}"
}

ssh_eff() {   # sshd -T 全量输出；失败输出空串
  local out
  out="$(sshd -T 2>/dev/null)" || true
  printf '%s' "${out}"
}

eff_val() {   # eff_val <ssh_eff 输出> <键名>：取该键生效值，缺失显示「未知」
  local out="$1" key="$2" v
  v="$(printf '%s\n' "${out}" | awk -v k="${key}" 'tolower($1)==k{v=$2} END{print v}')" || true
  printf '%s' "${v:-未知}"
}

ufw_status_raw() {   # ufw status 原始输出；规则行第一个字段就是 "端口/协议"
  # 不写成 `ufw status | grep -q`：grep 匹配即退出会让 ufw 收 SIGPIPE（141），
  # 在 set -o pipefail 下把「已放行」误判成「未放行」，进而误报铁律告警或误删规则
  local out
  out="$(ufw status 2>/dev/null)" || true
  printf '%s' "${out}"
}
ufw_has() {   # ufw_has <端口/协议>：基于最新快照。调用前若已有 UFW_SNAP 可复用，否则自取
  # 用「首字段全等」而非 grep -w：端口范围规则 1000:2000/tcp 会被 -w 误判为含 1000/tcp
  [[ -n "$1" ]] || return 1
  local st="${UFW_SNAP}"
  [[ -n "${st}" ]] || st="$(ufw_status_raw)"
  awk -v s="$1" '$1==s{f=1} END{exit !f}' <<<"${st}"
}
UFW_SNAP=""   # 每轮菜单/动作前刷新（do_apply 内刷新），避免同一次渲染重复调 ufw

do_scan_dropins() {
  # cloud-init 常见：drop-in 覆盖项。sshd 配置先出现者优先，01- 之前的文件会压过本脚本
  local f
  [[ -d "${SSHD_D}" ]] || return 0
  for f in "${SSHD_D}"/*.conf; do
    [[ -f "${f}" ]] || continue
    [[ "${f}" == "${HARD}" ]] && continue   # 本脚本自己的输出，不算覆盖项（幂等重跑）
    if grep -q '^PasswordAuthentication' "${f}" 2>/dev/null; then
      if [[ "${f}" < "${HARD}" ]]; then
        warn "警告：${f} 排序在 01- 之前且含 PasswordAuthentication，会压过本脚本的配置。"
      else
        warn "提示：${f} 含 PasswordAuthentication，但排序在 01- 之后，被 01- 压住、不会生效。"
      fi
    fi
  done
}

is_hardened() {   # 当前系统已按本脚本策略生效（端口 + 禁密码 + 禁 root）返回 0
  local eff
  [[ -f "${HARD}" ]] || return 1
  eff="$(ssh_eff)"
  [[ -n "${eff}" ]] || return 1
  grep -q '^passwordauthentication no$' <<<"${eff}" || return 1
  grep -q '^permitrootlogin no$' <<<"${eff}" || return 1
  [[ "$(sshd_port)" == "${SSH_PORT}" ]] || return 1
  return 0
}

ufw_precheck() {   # ufw_precheck <当前端口>：铁律一，新端口须已放行；迁移期间旧端口也须保留
  local cur="$1" st
  command -v ufw >/dev/null 2>&1 || return 0
  UFW_SNAP="$(ufw_status_raw)"
  st="${UFW_SNAP}"
  if ! grep -q '^Status: active' <<<"${st}"; then
    die "ufw 未启用。请先运行 05-ufw.sh（铁律：UFW 先于 sshd）"
  fi
  if ! ufw_has "${SSH_PORT}/tcp"; then
    die "ufw 已启用但未放行 ${SSH_PORT}/tcp。请先运行 05-ufw.sh（铁律：UFW 先于 sshd）"
  fi
  if [[ -n "${cur}" && "${cur}" != "${SSH_PORT}" ]] && ! ufw_has "${cur}/tcp"; then
    die "迁移期间旧端口 ${cur}/tcp 必须保持放行（闸门二确认前不能断退路）。请先运行 05-ufw.sh"
  fi
  return 0
}

# ==================== 动作：应用加固配置 ====================

do_apply() {
  local cur actual listening ports
  [[ -f "${SSHD_CFG}" ]] || die "未找到 ${SSHD_CFG}"
  grep -q '^Include' "${SSHD_CFG}" || die "需先在 sshd_config 启用 Include drop-in（本流程依赖 drop-in 覆盖）"

  # 旧端口：迁移前 sshd 的实际值（写 drop-in 之前读，之后就读不到了）
  cur="$(sshd_port)"
  if [[ -z "${cur}" ]]; then cur="$(conf_val OLD_SSH_PORT)"; fi
  [[ -n "${cur}" ]] || cur="22"
  MIGRATION=0
  if [[ "${cur}" != "${SSH_PORT}" ]]; then MIGRATION=1; fi
  if [[ "${MIGRATION}" -eq 1 ]]; then
    conf_update "OLD_SSH_PORT" "${cur}"
    log "端口迁移：sshd 当前 ${cur} → 目标 ${SSH_PORT}"
  else
    log "sshd 已在端口 ${SSH_PORT}：只重写加固配置，无端口迁移"
  fi

  # AllowUsers 一旦写错就是全体锁死：用户必须真实存在（先于任何系统检查，不给坏值留缝）
  if ! id "${ADMIN_USER}" >/dev/null 2>&1; then
    die "系统用户 ${ADMIN_USER} 不存在。AllowUsers 写它会让所有账号（含你当前会话）下次登录被拒。先跑 04-user.sh 建用户，或用菜单 3 改 ADMIN_USER"
  fi

  ufw_precheck "${cur}"
  do_scan_dropins

  backup_file "${HARD}" >/dev/null || true
  printf 'Port %s\nPermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAllowUsers %s\nMaxAuthTries 3\n' \
    "${SSH_PORT}" "${ADMIN_USER}" > "${HARD}"

  # sshd -t 语法校验（失败即退出，防止坏配置压死 ssh）
  if ! sshd -t; then
    warn "sshd -t 校验失败。请检查 ${HARD}；可用备份还原：${BK_ROOT}/"
    exit 1
  fi

  # sshd -T 验证实际生效值
  actual="$(sshd_port)"
  if [[ "${actual}" != "${SSH_PORT}" ]]; then
    warn "sshd -T 实际端口 ${actual:-未知} != 期望 ${SSH_PORT}"
    warn "多半是 ${SSHD_D}/ 下的覆盖文件抢了优先权（先出现者优先）；请检查后重跑"
    exit 1
  fi
  log "sshd -T 确认：端口 ${actual}、debug 通过"

  # 闸门一：密钥登录验证（铁律 2）
  if ! ask_yesno "已在 04 后用新终端验证过 ${ADMIN_USER} 的密钥登录吗？" n; then
    die "先验证密钥登录再加固。本脚本尚未 reload ssh，当前 ssh 配置未变，可安全退出"
  fi

  # Ubuntu 22.10+ 等默认用 ssh.socket 套接字激活：监听端口由 socket 单元决定，
  # sshd_config 的 Port 不生效（sshd -T 只读配置文件，会"骗人"）。统一转回标准
  # ssh.service 模式，让端口、AllowUsers 等策略真正生效。
  if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
    log "检测到 ssh.socket 套接字激活，切换回标准 ssh.service 模式（否则新端口不生效）"
    systemctl disable --now ssh.socket
    systemctl enable ssh.service
  fi
  systemctl restart ssh || die "ssh 启动失败（sshd -t 已过，多为权限/服务名问题）；备份在 ${BK_ROOT}/"
  log "sshd 已生效：新端口 ${SSH_PORT}"

  # 自检：端口监听（systemctl restart 返回 ≠ 端口已绑定，轮询等待 bind 完成）
  if command -v ss >/dev/null 2>&1; then
    listening=0
    for _ in $(seq 1 10); do
      # 先取全量输出再匹配：grep -q 早退会让 ss 收 SIGPIPE，pipefail 下把成功误判为失败
      ports="$(ss -tln 2>/dev/null | awk '{print $4}')" || true
      if grep -qE "[:.]${SSH_PORT}$" <<<"${ports}"; then listening=1; break; fi
      sleep 0.3
    done
    [[ "${listening}" -eq 1 ]] || warn "3 秒内未见端口 ${SSH_PORT} 监听，请手动检查：ss -tlnp | grep ${SSH_PORT}"
  fi

  log ""
  log "保持【本会话】不断开！请操作："
  log "  1) 新开终端：ssh -p ${SSH_PORT} ${ADMIN_USER}@<host>  —— 必须密钥登录成功且 root 被拒"
  if [[ "${MIGRATION}" -eq 1 ]]; then
    log "  2) 同步云平台安全组：关 ${cur}、开 ${SSH_PORT}（只能你手动做）"
  else
    log "  2) 确认云平台安全组已放行 ${SSH_PORT}（本机 ufw 已放行）"
  fi
  log ""

  # 闸门二：新终端验证（铁律 3）
  if ! ask_yesno "新终端已用新端口成功登录？" n; then
    warn "未确认新端口可用。当前 ${cur} 放行规则保持不动以保旧会话可回退。"
    warn "恢复指引：若已锁死，用云控制台/VNC 登录后还原 ${BK_ROOT}/ 下备份，再 systemctl reload ssh"
    exit 1
  fi
  if [[ "${MIGRATION}" -eq 1 ]]; then
    UFW_SNAP="$(ufw_status_raw)"
    if ufw_has "${cur}/tcp"; then
      # || true：删不存在的规则时 ufw 返回 1，不该因此把整个流程判失败
      ufw delete allow "${cur}/tcp" || warn "删除 ${cur}/tcp 规则失败，请手动执行：ufw delete allow ${cur}/tcp"
      log "已移除 ${cur} 临时放行规则（ufw）"
    fi
  fi
  log ""
  log "SSH 加固完成。提醒：云安全组若仍放行 ${cur}，请手动关闭。"
  log "云厂商预置用户（如 ubuntu/admin）仍存在但已被 AllowUsers 屏蔽；确认不用可手动删除。"
}

# ==================== 动作：维护 ====================

do_show() {
  local eff
  UFW_SNAP="$(ufw_status_raw)"
  eff="$(ssh_eff)"
  printf '%s\n' "${C_D}── sshd 实际生效值（sshd -T）──${C_0}"
  if [[ -z "${eff}" ]]; then
    warn "sshd -T 失败，手动排查：sshd -T（常见：/run/sshd 缺失）"
  else
    printf '%s\n' "${eff}" | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords|maxauthtries|allowusers|kbdinteractiveauthentication|challengeresponseauthentication) ' || true
  fi
  printf '\n%s\n' "${C_D}── 加固文件 ──${C_0}"
  if [[ -f "${HARD}" ]]; then
    cat "${HARD}"
  else
    warn "未找到 ${HARD}（尚未执行加固）"
  fi
  printf '\n%s\n' "${C_D}── ufw ──${C_0}"
  if command -v ufw >/dev/null 2>&1; then
    printf '%s\n' "${UFW_SNAP}"
    if ufw_has "${SSH_PORT}/tcp"; then printf '%s%s 已放行 ✓%s\n' "${C_G}" "${SSH_PORT}/tcp" "${C_0}"
    else printf '%s%s 未放行 ⚠%s\n' "${C_Y}" "${SSH_PORT}/tcp" "${C_0}"; fi
  else
    warn "未安装 ufw（铁律：UFW 先于 sshd）"
  fi
  printf '\n%s\n' "${C_D}── drop-in 覆盖检查 ──${C_0}"
  do_scan_dropins
}

do_edit_params() {
  local v
  log "当前 conf：SSH_PORT=${SSH_PORT:-未配置} / ADMIN_USER=${ADMIN_USER:-未配置}"
  if ask_yesno "修改 SSH 端口（改端口需配合 ufw，见下方提示）？" n; then
    v="$(ask_input "新 SSH 端口（1024-65535，避开 22/2222）" v_ssh_port)"
    conf_update "SSH_PORT" "${v}"
    SSH_PORT="${v}"
    log "SSH_PORT 已写入 ${CONF}：${v}"
    warn "端口迁移顺序：先跑 05-ufw.sh（放行新端口 + 临时保留当前端口），再回菜单 1 应用"
  fi
  if ask_yesno "修改管理员用户（AllowUsers）？" n; then
    v="$(ask_input "管理员用户名" v_user)"
    if id "${v}" >/dev/null 2>&1; then
      log "系统用户 ${v} 存在"
    else
      warn "系统用户 ${v} 不存在：写入 AllowUsers 后除该用户外的所有账号都会被拒（含当前登录用户）"
      if ! ask_yesno "仍要写入 ${v}？" n; then return 0; fi
    fi
    conf_update "ADMIN_USER" "${v}"
    ADMIN_USER="${v}"
    log "ADMIN_USER 已写入 ${CONF}：${v}"
    warn "改前确认该用户已有可用公钥（04-user.sh 管理），否则闸门二会登录失败"
  fi
}

do_restore() {
  # 从 /root/vps-init-backups/ 恢复 01-hardening.conf（恢复前先备份当前文件，可再回滚）
  local -a backs=()
  local d i pick prev newport cur
  if [[ -d "${BK_ROOT}" ]]; then
    while IFS= read -r d; do
      [[ -f "${d}01-hardening.conf" ]] && backs+=("${d}")
    done < <(ls -1d "${BK_ROOT}"/*/ 2>/dev/null | sort -r)
  fi
  if [[ "${#backs[@]}" -eq 0 ]]; then
    log "没有 01-hardening.conf 的备份（备份目录：${BK_ROOT}）"
    return 0
  fi
  printf '可用备份（新 → 旧）：\n'
  i=1
  for d in "${backs[@]}"; do
    printf '  %d) %s\n' "${i}" "${d%/}"
    i=$((i + 1))
  done
  pick=""
  while :; do
    read -rp "恢复第几份？[1-${#backs[@]}]（回车取消） " pick || die "输入中断"
    [[ -z "${pick}" ]] && return 0
    if [[ "${pick}" =~ ^[0-9]+$ ]] && (( pick >= 1 )) && (( pick <= ${#backs[@]} )); then break; fi
    printf '编号超出范围，重填。\n'
  done
  d="${backs[$((pick - 1))]}"
  printf '将用 %s01-hardening.conf 覆盖 %s，内容：\n' "${d}" "${HARD}"
  cat "${d}01-hardening.conf"
  if ! ask_yesno "确认恢复？" n; then return 0; fi
  prev="$(backup_file "${HARD}")"
  cp -a "${d}01-hardening.conf" "${HARD}"
  if ! sshd -t; then
    warn "恢复后的文件语法校验失败，已还原恢复前的版本"
    if [[ -n "${prev}" ]]; then cp -a "${prev}/01-hardening.conf" "${HARD}"; fi
    return 0
  fi
  log "已恢复 ${HARD}"

  # 铁律：端口变了要先确保 ufw 放行，再重启 sshd
  # awk 不早退（早退会让上游收 SIGPIPE，pipefail 下赋值失败）
  newport="$(awk '/^[Pp]ort[[:space:]]/ {p=$2} END{print p}' "${HARD}" | tr -d '\r')" || true
  cur="$(sshd_port)"
  if [[ -n "${newport}" && "${newport}" != "${cur}" ]]; then
    log "备份文件指定端口 ${newport}（当前 sshd 生效端口 ${cur}）"
    UFW_SNAP="$(ufw_status_raw)"
    if command -v ufw >/dev/null 2>&1 && ! ufw_has "${newport}/tcp"; then
      warn "ufw 未放行 ${newport}/tcp，现在重启 sshd 会锁死"
      if ask_yesno "先放行 ${newport}/tcp 再继续？" y; then
        ufw allow "${newport}/tcp"
        UFW_SNAP="$(ufw_status_raw)"
        log "已放行 ${newport}/tcp"
      else
        warn "已中止，未重启 sshd；该文件将在下次 sshd 重启时生效（届时务必先放行端口）"
        return 0
      fi
    fi
  fi
  if ask_yesno "现在重启 ssh 让恢复的配置生效？" n; then
    systemctl restart ssh || die "ssh 重启失败；备份在 ${BK_ROOT}/"
    warn "本会话不要断开：立刻新开终端验证登录，通过前别关旧窗口"
  else
    log "未重启，恢复的配置将在下次 sshd 重启时生效"
  fi
}

# ==================== 脚本主体 ====================

require_root; require_tty; require_distro

command -v sshd >/dev/null 2>&1 || die "未找到 sshd，请确认已安装 openssh-server"

SSH_PORT="$(conf_val SSH_PORT)"
if ! v_ssh_port "${SSH_PORT}" >/dev/null 2>&1; then
  SUGGEST="$(rand_port)"
  log "随机建议端口：${SUGGEST}（回车采纳）"
  SSH_PORT="$(ask_input_def "新 SSH 端口" v_ssh_port "${SUGGEST}")"
  conf_update "SSH_PORT" "${SSH_PORT}"
fi
ADMIN_USER="$(conf_val ADMIN_USER)"
if ! v_user "${ADMIN_USER}" >/dev/null 2>&1; then
  ADMIN_USER="$(ask_input "管理员用户名" v_user)"
  conf_update "ADMIN_USER" "${ADMIN_USER}"
fi

# 首次/未加固：直接走加固流程；已加固：进维护菜单
if is_hardened; then
  : # 已加固，进菜单
else
  do_apply
  log "加固流程结束，进入维护菜单（按 0 退出）"
fi

while :; do
  UFW_SNAP="$(ufw_status_raw)"
  EFF="$(ssh_eff)"
  E_PORT="$(eff_val "${EFF}" port)"
  E_ROOT="$(eff_val "${EFF}" permitrootlogin)"
  E_PWD="$(eff_val "${EFF}" passwordauthentication)"
  E_USERS="$(eff_val "${EFF}" allowusers)"
  E_TRIES="$(eff_val "${EFF}" maxauthtries)"
  HARD_USERS=""
  [[ -f "${HARD}" ]] && HARD_USERS="$(sed -n 's/^AllowUsers[[:space:]]\+//p' "${HARD}" | tr -d '\r')"
  if [[ -n "${HARD_USERS}" && "${HARD_USERS}" != "${ADMIN_USER}" ]]; then
    E_USERS="${E_USERS} ${C_Y}（conf 已改为 ${ADMIN_USER}，按 1 应用）${C_0}"
  fi
  if [[ -f "${HARD}" ]]; then HARD_DESC="已写入 ✓"; else HARD_DESC="${C_Y}未写入 ⚠${C_0}"; fi
  if ! command -v ufw >/dev/null 2>&1; then
    UFW_DESC="${C_Y}未安装 ufw ⚠${C_0}"
  elif ufw_has "${SSH_PORT}/tcp"; then
    UFW_DESC="${C_G}${SSH_PORT}/tcp 已放行 ✓${C_0}"
  else
    UFW_DESC="${C_Y}${SSH_PORT}/tcp 未放行 ⚠${C_0}"
  fi
  printf '%s\n' "${C_D}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_0}"
  printf '%s SSH 加固 · %s%s\n' "${C_B}" "${C_G}" "${ADMIN_USER}"
  printf '%s\n' "${C_D}───────────────────────────────────${C_0}"
  printf '  端口(生效)      %s\n' "${E_PORT}"
  printf '  root 登录       %s\n' "${E_ROOT}"
  printf '  密码登录        %s\n' "${E_PWD}"
  printf '  AllowUsers      %b\n' "${E_USERS}"
  printf '  MaxAuthTries    %s\n' "${E_TRIES}"
  printf '  加固文件        %b\n' "${HARD_DESC}"
  printf '  ufw             %b\n' "${UFW_DESC}"
  printf '%s\n' "${C_D}───────────────────────────────────${C_0}"
  printf '  %s1%s) 应用 / 重新应用加固配置（写 01-hardening.conf，双闸门）\n' "${C_G}" "${C_0}"
  printf '  %s2%s) 查看当前生效状态（sshd -T / 加固文件 / ufw / drop-in 覆盖）\n' "${C_G}" "${C_0}"
  printf '  %s3%s) 修改参数（SSH 端口 / 管理员用户，写入 conf）\n' "${C_G}" "${C_0}"
  printf '  %s4%s) 从备份恢复 01-hardening.conf\n' "${C_G}" "${C_0}"
  printf '  %s0%s) 退出\n' "${C_R}" "${C_0}"
  printf '%s\n' "${C_D}───────────────────────────────────${C_0}"
  OP=""
  while :; do
    read -rp "选择操作 [0-4] " OP || die "输入中断"
    if [[ "${OP}" =~ ^[0-4]$ ]]; then break; fi
    printf '请输入 0-4。\n'
  done
  case "${OP}" in
    0) break ;;
    1) do_apply ;;
    2) do_show ;;
    3) do_edit_params ;;
    4) do_restore ;;
  esac
done

log "第 6 步完成"
