#!/usr/bin/env bash
# VPS 初始化 · 05 UFW 防火墙（菜单式管理）
# 自包含 + 幂等 + 交互闸门。用法：sudo bash 05-ufw.sh
# 首次运行自动执行初始化（默认拒绝入站 + 放行 SSH 与业务端口），之后进入维护菜单。
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/05-ufw.sh

set -euo pipefail

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

# ==================== 防火墙辅助 ====================

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
  # 临时放行当前端口（迁移期间旧端口仍需可用；06-ssh.sh 闸门确认后移除）
  if [[ "${cur}" == "${ssh_port}" ]]; then
    log "sshd 已在新端口 ${cur} 上，无需迁移：不添加旧端口临时规则"
  else
    if conf_has "OLD_SSH_PORT" && [[ "$(conf_read "OLD_SSH_PORT")" != "${cur}" ]]; then
      warn "conf 记录的旧端口 $(conf_read "OLD_SSH_PORT") 与 sshd 实际 ${cur} 不一致，以 sshd 实际为准"
    fi
    conf_update "OLD_SSH_PORT" "${cur}"
    ufw allow "${cur}/tcp"
    log "已临时放行旧端口 ${cur}/tcp（06-ssh.sh 闸门确认后移除）"
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
    log "规则（编号，删除用菜单 4）："
    printf '%s\n' "${FW_RAW}"
  else
    # 未启用时 ufw 不给带编号的列表（status numbered 为空），但规则确实已在 user.rules 里
    log "ufw 未启用：以下为已添加的规则（无编号，启用后菜单 4 才能按编号删除）："
    printf '%s\n' "${FW_ADDED}"
  fi
  old="$(conf_val OLD_SSH_PORT)"
  if [[ -n "${old}" && "${old}" != "$(conf_val SSH_PORT)" ]] && fw_has_rule "${old}/tcp"; then
    warn "旧端口 ${old}/tcp 的临时规则仍在（06-ssh.sh 闸门确认新端口可用后应删除）"
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
    log "可选：菜单 5 先启用再回来删除；或用 'ufw show added' 查看，再执行 'ufw delete allow <规则>'"
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
      log "ufw 已禁用（菜单 5 可再启用）"
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

# ==================== 脚本主体 ====================

require_root
require_tty
require_distro

command -v ufw >/dev/null 2>&1 || die "未找到 ufw，请先执行 02-tools.sh（安装基础工具）"

# 首次运行（conf 无 SSH_PORT）自动初始化，之后进维护菜单
if ! conf_has "SSH_PORT"; then
  log "首次运行：执行初始化配置"
  do_init
  log "初始化完成，进入维护菜单（按 0 退出）"
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
  printf '%s\n' "${C_D}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_0}"
  printf '%s 防火墙管理 · ufw\n' "${C_B}"
  printf '%s\n' "${C_D}───────────────────────────────────${C_0}"
  printf '  防火墙      %b\n' "${F_STATE_DESC}"
  printf '  默认策略    入站 %s / 出站 %s\n' "$(fw_default_in)" "$(fw_default_out)"
  printf '  规则数      %s\n' "${F_RULES}"
  printf '  SSH 端口    %b\n' "${F_SSH_DESC}"
  printf '  业务端口    %s\n' "${F_PORTS:-(空)}"
  printf '%s\n' "${C_D}───────────────────────────────────${C_0}"
  printf '  %s1%s) 初始化 / 重新应用配置（默认拒绝入站 + 放行 SSH 与业务端口）\n' "${C_G}" "${C_0}"
  printf '  %s2%s) 查看规则详情（verbose + 编号）\n' "${C_G}" "${C_0}"
  printf '  %s3%s) 放行端口（allow，可限来源 IP）\n' "${C_G}" "${C_0}"
  printf '  %s4%s) 删除规则（按编号）\n' "${C_G}" "${C_0}"
  printf '  %s5%s) 启用 / 禁用防火墙\n' "${C_G}" "${C_0}"
  printf '  %s6%s) 修改默认策略（入站 / 出站）\n' "${C_G}" "${C_0}"
  printf '  %s7%s) 修改业务端口清单（conf ALLOWED_PORTS，并按清单增删规则）\n' "${C_G}" "${C_0}"
  printf '  %s0%s) 退出\n' "${C_R}" "${C_0}"
  printf '%s\n' "${C_D}───────────────────────────────────${C_0}"
  OP=""
  while :; do
    read -rp "选择操作 [0-7] " OP || die "输入中断"
    if [[ "${OP}" =~ ^[0-7]$ ]]; then break; fi
    printf '请输入 0-7。\n'
  done
  case "${OP}" in
    0) break ;;
    1) do_init ;;
    2) do_status ;;
    3) do_allow ;;
    4) do_delete ;;
    5) do_toggle ;;
    6) do_default ;;
    7) do_ports ;;
  esac
done

log "第 5 步完成"
log "提醒：云平台安全组要同步放行（ufw 放行 ≠ 云安全组放行），两边不一致就是服务不通的常见坑"