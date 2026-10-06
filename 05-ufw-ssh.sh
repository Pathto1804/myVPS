#!/usr/bin/env bash
# VPS 初始化 · 05–06 防火墙 + SSH 加固（菜单式管理）
# 自包含 + 幂等 + 交互闸门。用法：sudo bash 05-ufw-ssh.sh
# 首次运行：UFW 初始化（默认拒绝入站 + 放行 SSH 与业务端口）→ SSH 加固（双闸门）→ 进维护菜单
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/05-ufw-ssh.sh

set -euo pipefail
# 命令替换默认不继承 errexit：不开这个，$(ask_input ...) 里的 die 只终止子 shell，
# 空值会被照常写进 conf。开启后交互读取遇 EOF/Ctrl-D 即中止脚本。（bash >= 4.4）
shopt -s inherit_errexit

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CONF="/root/.vps-init.conf"
BK_ROOT="/root/vps-init-backups"

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

conf_val() {   # 读 conf 值；缺失输出空串
  local v=""
  if conf_has "$1"; then v="$(conf_read "$1")"; fi
  printf '%s' "${v}"
}

sshd_port() {   # sshd 实际生效端口；读不到输出空串
  # 不用 `awk '/^port /{print $2; exit}'`：awk 提前退出会让 sshd 收到 SIGPIPE（141），
  # 在 set -o pipefail 下整条管道非零 → 赋值失败 → ERR trap 裸奔退出。
  local p
  p="$(sshd -T 2>/dev/null | awk '/^port /{p=$2} END{print p}' | tr -d '\r')" || true
  [[ "${p}" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
  printf '%s' "${p}"
}

rand_port() { shuf -i 10000-65535 -n 1 2>/dev/null || printf '%s' 54321; }

# ==================== 防火墙 / sshd 辅助 ====================

fw_status_numbered() {   # `ufw status numbered` 原始输出（含 Status 与带编号的规则；注意它不含 Default 行）
  # 不写成 `ufw status | grep -q`：grep 匹配即退出会让 ufw 收 SIGPIPE（141），
  # 在 set -o pipefail 下把「有规则」误判成「无规则」
  local out
  out="$(ufw status numbered 2>/dev/null)" || true
  printf '%s' "${out}"
}
fw_status_plain() {   # `ufw status` 原始输出（规则行的第一个字段就是 "端口/协议"，用于精确匹配）
  local out
  out="$(ufw status 2>/dev/null)" || true
  printf '%s' "${out}"
}
fw_status_verbose() {   # `ufw status verbose` 原始输出（唯一带 Default/Logging 行的输出）
  local out
  out="$(ufw status verbose 2>/dev/null)" || true
  printf '%s' "${out}"
}
fw_added() {   # `ufw show added` 原始输出（规则行形如 "ufw allow 22/tcp"）
  # 唯一在 ufw 未启用时也列规则的来源：未启用时 `ufw status` 只回 "Status: inactive"、
  # 一条规则都不列（见 src/backend_iptables.py get_status：链不存在即 return），
  # 但规则实际已写入 /etc/ufw/user.rules。首次运行（未启用）的自检必须靠它。
  local out
  out="$(ufw show added 2>/dev/null)" || true
  printf '%s' "${out}"
}
FW_RAW=""    # 带编号规则快照（删除要按 ufw 自己的编号；仅 ufw 启用时有意义）
FW_PLAIN=""  # 规则快照（精确匹配用）
FW_VERB=""   # 默认策略/日志快照
FW_ADDED=""  # `ufw show added` 快照（未启用时的规则来源）
fw_refresh() {
  FW_RAW="$(fw_status_numbered)"; FW_PLAIN="$(fw_status_plain)"; FW_VERB="$(fw_status_verbose)"
  if [[ "$(fw_state)" == "active" ]]; then FW_ADDED=""; else FW_ADDED="$(fw_added)"; fi
}
fw_first_line() { printf '%s' "${1%%$'\n'*}"; }   # 取首行：代替 `| head -n 1`（head 早退会 SIGPIPE 上游）
fw_state() {   # active / inactive / 未知
  local s
  s="$(sed -n 's/^Status: \(.*\)$/\1/p' <<<"${FW_RAW}")"
  printf '%s' "$(fw_first_line "${s:-未知}")"
}
fw_default_in() {
  local s
  s="$(sed -n 's/^Default: \([a-z]*\) (incoming).*/\1/p' <<<"${FW_VERB}")"
  printf '%s' "$(fw_first_line "${s:-未知}")"
}
fw_default_out() {
  local s
  s="$(sed -n 's/^Default: [a-z]* (incoming), \([a-z]*\) (outgoing).*/\1/p' <<<"${FW_VERB}")"
  printf '%s' "$(fw_first_line "${s:-未知}")"
}
fw_rule_count() {
  local n
  n="$(grep -cE '^\[[[:space:]]*[0-9]+\]' <<<"${FW_RAW}")" || true
  printf '%s' "${n:-0}"
}
fw_has_rule() {   # fw_has_rule <端口/协议>：ufw 启用时读 status，未启用时读 show added（调用前需 fw_refresh）
  # 用「首字段全等」而非 grep -w：端口范围规则 1000:2000/tcp 会被 -w 误判为含 1000/tcp
  [[ -n "$1" ]] || return 1
  if [[ "$(fw_state)" == "active" ]]; then
    awk -v s="$1" '$1==s{f=1} END{exit !f}' <<<"${FW_PLAIN}"
  else
    # 未启用时 status 不列规则，改查 show added：同时匹配 `ufw allow 22/tcp`
    # 与 `ufw allow from <来源> to any port 22 proto tcp` 两种形态
    local port proto
    port="${1%%/*}"; proto="${1##*/}"
    grep -qE "^ufw (allow|limit) (${1}|from .* to any port ${port} proto ${proto})\$" <<<"${FW_ADDED}"
  fi
}
fw_rule_line() {   # fw_rule_line <编号>：输出该编号规则的文本（去掉 "[ n] " 前缀），无则空
  local n="$1" s
  s="$(sed -n "s/^\[[[:space:]]*${n}\][[:space:]]*//p" <<<"${FW_RAW}")"
  fw_first_line "${s}"
}

SSHD_CFG="/etc/ssh/sshd_config"
SSHD_D="/etc/ssh/sshd_config.d"
HARD="${SSHD_D}/01-hardening.conf"

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
  local cur="$1"
  command -v ufw >/dev/null 2>&1 || return 0
  fw_refresh
  if [[ "$(fw_state)" != "active" ]]; then
    die "ufw 未启用。请先用菜单 1 初始化 / 重新应用防火墙配置（铁律：UFW 先于 sshd）"
  fi
  if ! fw_has_rule "${SSH_PORT}/tcp"; then
    die "ufw 已启用但未放行 ${SSH_PORT}/tcp。请先用菜单 1 应用防火墙配置（铁律：UFW 先于 sshd）"
  fi
  if [[ -n "${cur}" && "${cur}" != "${SSH_PORT}" ]] && ! fw_has_rule "${cur}/tcp"; then
    die "迁移期间旧端口 ${cur}/tcp 必须保持放行（闸门二确认前不能断退路）。请先用菜单 1 重新应用防火墙配置"
  fi
  return 0
}

# ==================== 动作：初始化 ====================

do_init() {
  local cur ssh_port suggest p
  cur="$(sshd_port)"
  if [[ -z "${cur}" ]]; then
    die "无法读取 sshd 当前端口（sshd -T 失败），中止。手动跑 sshd -T 看报错（常见：/run/sshd 缺失，mkdir -p /run/sshd）"
  fi
  log "sshd 当前端口：${cur}"

  # 端口：conf 已有则确认沿用，否则给随机建议值（回车采纳；手动输入则用输入值）
  ssh_port="$(conf_val SSH_PORT)"
  if v_ssh_port "${ssh_port}" >/dev/null 2>&1; then
    if ! ask_yesno "沿用 conf 中的 SSH 端口 ${ssh_port}？" y; then ssh_port=""; fi
  fi
  if [[ -z "${ssh_port}" ]]; then
    suggest="$(rand_port)"
    log "随机建议端口：${suggest}（回车采纳，或自行输入）"
    ssh_port="$(ask_input_def "新 SSH 端口（1024-65535，避开 22/2222）" v_ssh_port "${suggest}")"
    conf_update "SSH_PORT" "${ssh_port}"
    log "SSH_PORT 已写入 ${CONF}：${ssh_port}"
  fi
  # 临时放行当前端口（迁移期间旧端口仍需可用；菜单 2 的加固流程闸门确认后移除）
  if [[ "${cur}" == "${ssh_port}" ]]; then
    log "sshd 已在新端口 ${cur} 上，无需迁移：不添加旧端口临时规则"
  else
    if conf_has "OLD_SSH_PORT" && [[ "$(conf_read "OLD_SSH_PORT")" != "${cur}" ]]; then
      warn "conf 记录的旧端口 $(conf_read "OLD_SSH_PORT") 与 sshd 实际 ${cur} 不一致，以 sshd 实际为准"
    fi
    conf_update "OLD_SSH_PORT" "${cur}"
    ufw allow "${cur}/tcp"
    log "已临时放行旧端口 ${cur}/tcp（菜单 2 的 SSH 加固确认新端口后移除）"
  fi

  ALLOWED_PORTS="$(conf_get "ALLOWED_PORTS" "额外放行端口（逗号分隔，如 80,443；空留空）" v_ports_list)"

  log "配置 UFW：默认拒绝入站，允许出站"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${ssh_port}/tcp"
  if [[ -n "${ALLOWED_PORTS}" ]]; then
    for p in ${ALLOWED_PORTS//,/ }; do
      ufw allow "${p}/tcp"
      log "已放行业务端口 ${p}/tcp"
    done
  fi

  # 铁律：确认新端口已放行才允许启用防火墙
  # 顺序不能反：若规则真缺失，先 enable 会当场切断当前 SSH 会话，报错信息都送不到用户手里
  fw_refresh
  if ! fw_has_rule "${ssh_port}/tcp"; then
    die "ufw 中未见 ${ssh_port}/tcp 放行规则，拒绝启用（防锁死）。请检查 ufw 输出后重试"
  fi
  ufw --force enable
  log "UFW 已启用（默认拒绝入站：仅上述端口可达）"
  do_status
}

# ==================== 动作：维护 ====================

do_status() {
  local old
  fw_refresh
  log "ufw 状态："
  printf '%s\n' "${FW_VERB}"
  printf '\n'
  if [[ "$(fw_state)" == "active" ]]; then
    log "规则（编号，删除用菜单 5）："
    printf '%s\n' "${FW_RAW}"
  else
    # 未启用时 ufw 不给带编号的列表（status numbered 为空），但规则确实已在 user.rules 里
    log "ufw 未启用：以下为已添加的规则（无编号，启用后菜单 4 才能按编号删除）："
    printf '%s\n' "${FW_ADDED}"
  fi
  old="$(conf_val OLD_SSH_PORT)"
  if [[ -n "${old}" && "${old}" != "$(conf_val SSH_PORT)" ]] && fw_has_rule "${old}/tcp"; then
    warn "旧端口 ${old}/tcp 的临时规则仍在（菜单 2 的 SSH 加固确认新端口可用后应删除）"
  fi
}

do_allow() {
  local op ports protos src p proto
  printf '  1) tcp   2) udp   3) tcp+udp\n'
  op=""
  while :; do
    read -rp "选择协议 [1-3]（回车取消） " op || die "输入中断"
    [[ -z "${op}" ]] && return 0
    if [[ "${op}" == "1" || "${op}" == "2" || "${op}" == "3" ]]; then break; fi
    printf '请输入 1、2 或 3。\n'
  done
  ports=""
  while :; do
    read -rp "端口（1-65535，逗号分隔可多个） " ports || die "输入中断"
    if [[ -z "${ports}" ]]; then printf '端口不能为空。\n'; continue; fi
    if v_ports_list "${ports}"; then break; fi
  done
  src=""
  if ask_yesno "限制来源 IP（如 1.2.3.4 或 10.0.0.0/8）？" n; then
    while :; do
      read -rp "来源地址 " src || die "输入中断"
      [[ -n "${src}" ]] && break
      printf '来源地址不能为空。\n'
    done
  fi
  case "${op}" in
    1) protos="tcp" ;;
    2) protos="udp" ;;
    *) protos="tcp udp" ;;
  esac
  for p in ${ports//,/ }; do
    for proto in ${protos}; do
      if [[ -n "${src}" ]]; then
        ufw allow from "${src}" to any port "${p}" proto "${proto}"
      else
        ufw allow "${p}/${proto}"
      fi
      log "已放行 ${p}/${proto}${src:+（仅 ${src}）}"
    done
  done
  fw_refresh
}

do_delete() {
  local num count port rule
  fw_refresh
  # 未启用时 ufw 不提供带编号的规则列表（status numbered 为空），而 `ufw --force delete N`
  # 是按 user.rules 顺序取第 N 条——编号无从核对，宁可不做也不删错规则
  if [[ "$(fw_state)" != "active" ]]; then
    warn "ufw 未启用，拿不到规则编号，无法按编号删除"
    log "可选：菜单 6 先启用再回来删除；或用 'ufw show added' 查看，再执行 'ufw delete allow <规则>'"
    return 0
  fi
  count="$(fw_rule_count)"
  printf '%s' "${FW_RAW}"
  printf '\n'
  if [[ "${count}" == "0" ]]; then log "当前没有可删除的规则"; return 0; fi
  num=""
  while :; do
    read -rp "删除第几条？[1-${count}]（回车取消） " num || die "输入中断"
    [[ -z "${num}" ]] && return 0
    if [[ "${num}" =~ ^[0-9]+$ ]] && (( num >= 1 )) && (( num <= count )); then break; fi
    printf '编号超出范围，重填。\n'
  done
  rule="$(fw_rule_line "${num}")"
  if [[ -z "${rule}" ]]; then warn "未找到编号 ${num} 的规则（列表可能已变化）"; return 0; fi
  port="${rule%%[[:space:]]*}"
  printf '将删除：[%s] %s\n' "${num}" "${rule}"
  if [[ "${port}" == "$(conf_val SSH_PORT)/tcp" || "${port}" == "$(sshd_port)/tcp" ]]; then
    warn "这是 SSH 端口的放行规则：删除会立刻断开当前连接，若没有其他端口可用就是锁死"
  fi
  if ask_yesno "确认删除这条规则？" n; then
    # || true：编号可能已被并发改动，ufw 拒绝删除时不该中断脚本
    ufw --force delete "${num}" || warn "删除编号 ${num} 失败（列表可能已变化），请重开菜单核对"
    log "已删除编号 ${num}"
    do_status
  fi
}

do_toggle() {
  local sshp
  fw_refresh
  if [[ "$(fw_state)" == "active" ]]; then
    warn "禁用 ufw 后所有端口对公网暴露（只剩 sshd 自身策略）；重启后也不会自动启用"
    if ask_yesno "确认禁用 ufw？" n; then
      ufw disable
      log "ufw 已禁用（菜单 6 可再启用）"
    else
      log "保持启用"
    fi
    return 0
  fi
  sshp="$(conf_val SSH_PORT)"
  [[ -n "${sshp}" ]] || sshp="$(sshd_port)"
  if [[ -z "${sshp}" ]]; then
    warn "无法确定 SSH 端口（conf 无 SSH_PORT 且 sshd -T 读不到），先走菜单 1 初始化"
    return 0
  fi
  if ! fw_has_rule "${sshp}/tcp"; then
    log "启用前先补放行 SSH 端口 ${sshp}/tcp（铁律：UFW 先于 sshd）"
    ufw allow "${sshp}/tcp"
  fi
  if ask_yesno "启用 ufw（默认拒绝入站）？" y; then
    ufw --force enable
    log "ufw 已启用"
  fi
}

do_default() {
  local which val
  fw_refresh
  log "当前默认策略：入站 $(fw_default_in) / 出站 $(fw_default_out)"
  printf '  1) 入站 incoming   2) 出站 outgoing\n'
  which=""
  while :; do
    read -rp "改哪一项？[1-2]（回车取消） " which || die "输入中断"
    [[ -z "${which}" ]] && return 0
    if [[ "${which}" == "1" || "${which}" == "2" ]]; then break; fi
    printf '请输入 1 或 2。\n'
  done
  printf '  1) allow（放行）   2) deny（拒绝）\n'
  val=""
  while :; do
    read -rp "设为？[1-2]（回车取消） " val || die "输入中断"
    [[ -z "${val}" ]] && return 0
    if [[ "${val}" == "1" || "${val}" == "2" ]]; then break; fi
    printf '请输入 1 或 2。\n'
  done
  case "${val}" in
    1) val="allow" ;;
    *) val="deny" ;;
  esac
  if [[ "${which}" == "1" && "${val}" == "allow" ]]; then
    warn "入站默认放行 = 防火墙基本失效（只剩未放行项被挡不住），仅在调试时用"
    if ! ask_yesno "确认把入站默认策略改为 allow？" n; then return 0; fi
    ufw default allow incoming
  elif [[ "${which}" == "1" ]]; then
    ufw default deny incoming
  elif [[ "${val}" == "allow" ]]; then
    ufw default allow outgoing
  else
    ufw default deny outgoing
  fi
  fw_refresh
  log "默认策略已更新：入站 $(fw_default_in) / 出站 $(fw_default_out)"
}

do_ports() {
  local cur new olds nrm p sshp
  fw_refresh
  sshp="$(conf_val SSH_PORT)"
  cur="$(conf_val ALLOWED_PORTS)"
  printf '当前业务端口清单：%s\n' "${cur:-(空)}"
  if [[ -n "${cur}" ]]; then
    new="$(ask_input_def "业务端口（逗号分隔）" v_ports_list "${cur}")"
  else
    new="$(ask_input "业务端口（逗号分隔，如 80,443；回车=留空）" v_ports_list)"
  fi
  if [[ "${new}" == "${cur}" ]]; then log "清单未变化"; return 0; fi
  conf_update "ALLOWED_PORTS" "${new}"
  log "ALLOWED_PORTS 已更新：${new:-(空)}"
  olds=" ${cur//,/ } "
  nrm=" ${new//,/ } "
  for p in ${cur//,/ }; do
    if [[ "${nrm}" == *" ${p} "* ]]; then continue; fi
    if [[ "${p}" == "${sshp}" ]]; then warn "跳过 ${p}（当前 SSH 端口，勿在此删除）"; continue; fi
    if fw_has_rule "${p}/tcp"; then
      # || true：删不存在的规则时 ufw 返回 1，不该因此中断整个清单同步
      ufw --force delete allow "${p}/tcp" || warn "删除 ${p}/tcp 规则失败，请手动执行：ufw delete allow ${p}/tcp"
      log "已删除 ${p}/tcp（不在新清单中）"
    fi
  done
  for p in ${new//,/ }; do
    if [[ "${olds}" == *" ${p} "* ]]; then continue; fi
    ufw allow "${p}/tcp"
    log "已放行 ${p}/tcp"
  done
  fw_refresh
}

# ==================== 动作：SSH 加固 ====================

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
    die "系统用户 ${ADMIN_USER} 不存在。AllowUsers 写它会让所有账号（含你当前会话）下次登录被拒。先跑 04-user.sh 建用户，或用菜单 9 改 ADMIN_USER"
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
    fw_refresh
    if fw_has_rule "${cur}/tcp"; then
      # || true：删不存在的规则时 ufw 返回 1，不该因此把整个流程判失败
      ufw delete allow "${cur}/tcp" || warn "删除 ${cur}/tcp 规则失败，请手动执行：ufw delete allow ${cur}/tcp"
      log "已移除 ${cur} 临时放行规则（ufw）"
    fi
  fi
  log ""
  log "SSH 加固完成。提醒：云安全组若仍放行 ${cur}，请手动关闭。"
  log "云厂商预置用户（如 ubuntu/admin）仍存在但已被 AllowUsers 屏蔽；确认不用可手动删除。"
}

# ==================== 动作：SSH 维护 ====================

do_show() {
  local eff
  fw_refresh
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
    printf '%s\n' "${FW_PLAIN}"
    if fw_has_rule "${SSH_PORT}/tcp"; then printf '%s%s 已放行 ✓%s\n' "${C_G}" "${SSH_PORT}/tcp" "${C_0}"
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
    warn "端口迁移顺序：先在菜单 1 重新应用防火墙配置（放行新端口 + 临时保留当前端口），再回菜单 2 应用加固"
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
    fw_refresh
    if command -v ufw >/dev/null 2>&1 && ! fw_has_rule "${newport}/tcp"; then
      warn "ufw 未放行 ${newport}/tcp，现在重启 sshd 会锁死"
      if ask_yesno "先放行 ${newport}/tcp 再继续？" y; then
        ufw allow "${newport}/tcp"
        fw_refresh
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

require_root
require_tty
require_distro

command -v ufw >/dev/null 2>&1 || die "未找到 ufw，请先执行 01-base.sh（安装基础工具）"
command -v sshd >/dev/null 2>&1 || die "未找到 sshd，请确认已安装 openssh-server"

# 首次运行（conf 无 SSH_PORT）自动做防火墙初始化
if ! conf_has "SSH_PORT"; then
  log "首次运行：执行防火墙初始化配置"
  do_init
  log "初始化完成"
fi

SSH_PORT="$(conf_val SSH_PORT)"
[[ -n "${SSH_PORT}" ]] || die "conf 中无 SSH_PORT（防火墙初始化未完成）。请重新运行本脚本并完成菜单 1"

ADMIN_USER="$(conf_val ADMIN_USER)"
if ! v_user "${ADMIN_USER}" >/dev/null 2>&1; then
  ADMIN_USER="$(ask_input "管理员用户名" v_user)"
  conf_update "ADMIN_USER" "${ADMIN_USER}"
fi

# 未加固则接着走加固流程。ufw 未启用时不硬闯（铁律：UFW 先于 sshd），
# 只提示走菜单 1 —— 否则 do_apply 的前置自检会 die 成死胡同（重跑还是同一条路）
fw_refresh
if is_hardened; then
  log "SSH 已按本脚本策略加固，进入维护菜单（按 0 退出）"
elif [[ "$(fw_state)" == "active" ]]; then
  log "SSH 尚未加固，进入加固流程"
  do_apply
  log "加固流程结束，进入维护菜单（按 0 退出）"
else
  warn "SSH 未加固，且 ufw 当前未启用：请先用菜单 1 初始化 / 重新应用防火墙，再回来用菜单 2 加固（铁律：UFW 先于 sshd）"
  log "进入维护菜单（按 0 退出）"
fi

while :; do
  fw_refresh
  F_STATE="$(fw_state)"
  if [[ "${F_STATE}" == "active" ]]; then
    F_STATE_DESC="${C_G}active ✓${C_0}"
  else
    F_STATE_DESC="${C_Y}${F_STATE} ⚠${C_0}"
  fi
  F_RULES="$(fw_rule_count)"
  F_SSH_PORT="$(conf_val SSH_PORT)"
  F_SSHD_PORT="$(sshd_port)"
  F_SSH_DESC="${F_SSH_PORT:-未配置}"
  if [[ -n "${F_SSHD_PORT}" ]]; then
    F_SSH_DESC="${F_SSH_DESC}${C_D}（sshd 实际 ${F_SSHD_PORT}）${C_0}"
  fi
  F_PORTS="$(conf_val ALLOWED_PORTS)"
  EFF="$(ssh_eff)"
  E_ROOT="$(eff_val "${EFF}" permitrootlogin)"
  E_PWD="$(eff_val "${EFF}" passwordauthentication)"
  E_USERS="$(eff_val "${EFF}" allowusers)"
  E_TRIES="$(eff_val "${EFF}" maxauthtries)"
  HARD_USERS=""
  [[ -f "${HARD}" ]] && HARD_USERS="$(sed -n 's/^AllowUsers[[:space:]]\+//p' "${HARD}" | tr -d '\r')"
  if [[ -n "${HARD_USERS}" && "${HARD_USERS}" != "${ADMIN_USER}" ]]; then
    E_USERS="${E_USERS} ${C_Y}（conf 已改为 ${ADMIN_USER}，按 2 应用）${C_0}"
  fi
  if [[ -f "${HARD}" ]]; then HARD_DESC="已写入 ✓"; else HARD_DESC="${C_Y}未写入 ⚠${C_0}"; fi
  if ! command -v ufw >/dev/null 2>&1; then
    UFW_DESC="${C_Y}未安装 ufw ⚠${C_0}"
  elif fw_has_rule "${SSH_PORT}/tcp"; then
    UFW_DESC="${C_G}${SSH_PORT}/tcp 已放行 ✓${C_0}"
  else
    UFW_DESC="${C_Y}${SSH_PORT}/tcp 未放行 ⚠${C_0}"
  fi
  printf '%s\n' "${C_D}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_0}"
  printf '%s 防火墙 + SSH 加固 · %s%s\n' "${C_B}" "${C_G}" "${ADMIN_USER}"
  printf '%s\n' "${C_D}───────────────────────────────────${C_0}"
  printf '  防火墙      %b\n' "${F_STATE_DESC}"
  printf '  默认策略    入站 %s / 出站 %s\n' "$(fw_default_in)" "$(fw_default_out)"
  printf '  规则数      %s\n' "${F_RULES}"
  printf '  SSH 端口    %b\n' "${F_SSH_DESC}"
  printf '  业务端口    %s\n' "${F_PORTS:-(空)}"
  printf '%s\n' "${C_D}───────────────────────────────────${C_0}"
  printf '  root 登录   %s\n' "${E_ROOT}"
  printf '  密码登录    %s\n' "${E_PWD}"
  printf '  AllowUsers  %b\n' "${E_USERS}"
  printf '  MaxAuthTries %s\n' "${E_TRIES}"
  printf '  加固文件    %b\n' "${HARD_DESC}"
  printf '  ufw 放行    %b\n' "${UFW_DESC}"
  printf '%s\n' "${C_D}───────────────────────────────────${C_0}"
  printf '  %s1%s) 防火墙初始化 / 重新应用（默认拒绝入站 + 放行 SSH 与业务端口）\n' "${C_G}" "${C_0}"
  printf '  %s2%s) SSH 加固 / 重新应用（写 01-hardening.conf，双闸门）\n' "${C_G}" "${C_0}"
  printf '  %s3%s) 状态总览（ufw 规则 + sshd 生效值 + 加固文件 + drop-in 覆盖）\n' "${C_G}" "${C_0}"
  printf '  %s4%s) 放行端口（allow，可限来源 IP）\n' "${C_G}" "${C_0}"
  printf '  %s5%s) 删除规则（按编号）\n' "${C_G}" "${C_0}"
  printf '  %s6%s) 启用 / 禁用防火墙\n' "${C_G}" "${C_0}"
  printf '  %s7%s) 修改默认策略（入站 / 出站）\n' "${C_G}" "${C_0}"
  printf '  %s8%s) 修改业务端口清单（conf ALLOWED_PORTS，并按清单增删规则）\n' "${C_G}" "${C_0}"
  printf '  %s9%s) 修改参数（SSH 端口 / 管理员用户，写入 conf）\n' "${C_G}" "${C_0}"
  printf '  %s10%s) 从备份恢复 01-hardening.conf\n' "${C_G}" "${C_0}"
  printf '  %s0%s) 退出\n' "${C_R}" "${C_0}"
  printf '%s\n' "${C_D}───────────────────────────────────${C_0}"
  OP=""
  while :; do
    read -rp "选择操作 [0-10] " OP || die "输入中断"
    if [[ "${OP}" =~ ^([0-9]|10)$ ]]; then break; fi
    printf '请输入 0-10。\n'
  done
  case "${OP}" in
    0) break ;;
    1) do_init ;;
    2) do_apply ;;
    3) do_status; printf '\n'; do_show ;;
    4) do_allow ;;
    5) do_delete ;;
    6) do_toggle ;;
    7) do_default ;;
    8) do_ports ;;
    9) do_edit_params ;;
    10) do_restore ;;
  esac
done

log "第 5–6 步完成"
log "提醒：云平台安全组要同步放行（ufw 放行 ≠ 云安全组放行），两边不一致就是服务不通的常见坑"