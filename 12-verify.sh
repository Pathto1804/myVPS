#!/usr/bin/env bash
# VPS 初始化 · verify 终检 + 归档
# 自包含 + 只读检查。用法：sudo bash 12-verify.sh
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/12-verify.sh
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CONF="/root/.vps-init.conf"
REPORT="/root/vps-init-report.md"

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
require_distro() {
  local id
  id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
  [[ "${id}" == "debian" || "${id}" == "ubuntu" ]] || die "仅支持 Debian/Ubuntu，当前发行版：${id:-未知}"
}

# 结果统计与收集
RED=0; YEL=0; OKN=0
declare -a REPORT_LINES=()
ok()      { OKN=$((OKN+1)); REPORT_LINES+=("✓ $*"); printf '  %s✓%s %s\n' "${C_G}" "${C_0}" "$*"; }
bad()     { RED=$((RED+1)); REPORT_LINES+=("✗ $*"); printf '  %s✗%s %s\n' "${C_R}" "${C_0}" "$*"; }
caution() { YEL=$((YEL+1)); REPORT_LINES+=("! $*"); printf '  %s!%s %s\n' "${C_Y}" "${C_0}" "$*"; }

# ---- 读取 conf（缺失则降级：只查系统状态，不询问）----
HAS_CONF=0
SSH_PORT=""; ADMIN_USER=""; ALLOWED_PORTS=""; OLD_PORT=""
if [[ -f "${CONF}" ]]; then
  HAS_CONF=1
  SSH_PORT="$(sed -n "s/^SSH_PORT='\(.*\)'\$/\1/p" "${CONF}" | head -n 1)"
  ADMIN_USER="$(sed -n "s/^ADMIN_USER='\(.*\)'\$/\1/p" "${CONF}" | head -n 1)"
  ALLOWED_PORTS="$(sed -n "s/^ALLOWED_PORTS='\(.*\)'\$/\1/p" "${CONF}" | head -n 1)"
  OLD_PORT="$(sed -n "s/^OLD_SSH_PORT='\(.*\)'\$/\1/p" "${CONF}" | head -n 1)"
else
  warn "未找到 ${CONF}，降级为纯系统状态检查（conf 汇总将缺失）"
fi

require_root
require_distro

log "VPS 初始化终检"
echo ""

# ---- 1-3. sshd 实际生效值 ----
ACTUAL_PORT=""
if command -v sshd >/dev/null 2>&1; then
  ACTUAL_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' | tr -d '\r')"
  PWD_AUTH="$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2; exit}')"
  ROOT_LOGIN="$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2; exit}')"

  # 1. 端口
  if [[ -z "${ACTUAL_PORT}" ]]; then
    bad "sshd 实际端口无法读取"
  elif [[ -n "${SSH_PORT}" && "${ACTUAL_PORT}" != "${SSH_PORT}" ]]; then
    bad "sshd 端口：实际 ${ACTUAL_PORT} != conf 配置 ${SSH_PORT}"
  elif [[ -n "${SSH_PORT}" ]]; then
    ok "sshd 端口 = ${ACTUAL_PORT}（与 conf 一致）"
  else
    caution "sshd 端口 = ${ACTUAL_PORT}（conf 缺失，无法比对）"
  fi

  # 2/3. 认证策略
  [[ "${PWD_AUTH}" == "no" ]] && ok "passwordauthentication = no" || bad "passwordauthentication = ${PWD_AUTH:-未知}（须为 no）"
  [[ "${ROOT_LOGIN}" == "no" ]] && ok "permitrootlogin = no" || bad "permitrootlogin = ${ROOT_LOGIN:-未知}（须为 no）"
else
  bad "未找到 sshd，无法校验端口/认证策略"
fi

# ---- 4-5. ufw ----
if command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    ok "ufw 已启用"
    if [[ -n "${ACTUAL_PORT}" ]] && ufw status | grep -qw "${ACTUAL_PORT}/tcp"; then
      ok "ufw 已放行当前 SSH 端口 ${ACTUAL_PORT}/tcp"
    else
      bad "ufw 未放行当前 SSH 端口 ${ACTUAL_PORT:-?}/tcp"
    fi
    if [[ -n "${OLD_PORT}" ]]; then
      if [[ "${OLD_PORT}" == "${ACTUAL_PORT}" ]]; then
        caution "旧端口 ${OLD_PORT} 与当前 SSH 端口相同（可能未做端口迁移或重复初始化）"
      elif ufw status | grep -qw "${OLD_PORT}/tcp"; then
        bad "ufw 仍放行旧端口 ${OLD_PORT}/tcp（若已完成 06，应移除临时规则）"
      else
        ok "ufw 已关闭旧端口 ${OLD_PORT}/tcp"
      fi
    else
      caution "conf 缺失，无法核验旧端口关闭情况；请人工确认初始端口（如 22 或厂商随机端口）已从 ufw 与安全组移除"
    fi
  else
    bad "ufw 未启用"
  fi
else
  bad "ufw 未安装"
fi

# ---- 6. fail2ban ----
if command -v fail2ban-client >/dev/null 2>&1; then
  if systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
    ok "fail2ban sshd jail 运行中"
    if [[ -f /etc/fail2ban/jail.local && -n "${ACTUAL_PORT}" ]] \
       && grep -Eq "^port *= *${ACTUAL_PORT}\$" /etc/fail2ban/jail.local; then
      ok "jail.local 端口与 sshd 一致（${ACTUAL_PORT}）"
    else
      caution "无法确认 jail 端口与 sshd 一致，请人工核对 /etc/fail2ban/jail.local"
    fi
  else
    bad "fail2ban 未运行或 sshd jail 未启用"
  fi
else
  bad "fail2ban 未安装"
fi

# ---- 7. 自动安全更新 ----
UA_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
if [[ -f "${UA_FILE}" ]] \
   && grep -q 'APT::Periodic::Update "[1-9]' "${UA_FILE}" \
   && grep -q 'APT::Periodic::Unattended-Upgrade "[1-9]' "${UA_FILE}"; then
  ok "unattended-upgrades 已启用"
else
  bad "unattended-upgrades 未正确配置（检查 ${UA_FILE}）"
fi

# ---- 8-12. 黄灯项 ----
if [[ -n "$(swapon --show 2>/dev/null)" ]]; then
  ok "swap 已启用"
else
  caution "swap 未启用（如内存充裕可接受）"
fi

CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | tr -d '\r')"
if [[ "${CC}" == "bbr" ]]; then
  ok "BBR 已启用"
else
  caution "BBR 未启用（当前 ${CC:-未知}）"
fi

if timedatectl 2>/dev/null | grep -q 'NTP service: active'; then
  ok "NTP 时间同步正常"
else
  caution "NTP 未激活"
fi

DISK_USAGE="$(df -P / | awk 'NR==2{gsub(/%/,""); print $5}')"
if [[ "${DISK_USAGE:-100}" -lt 90 ]]; then
  ok "根分区使用率 ${DISK_USAGE}%"
else
  caution "根分区使用率 ${DISK_USAGE:-?}%（≥90%）"
fi

if [[ -f /var/run/reboot-required ]]; then
  caution "存在 reboot-required，建议重启"
else
  ok "无需重启"
fi

# ---- 生成报告 ----
HOSTN="$(hostname)"
DATE_STR="$(date '+%Y-%m-%d %H:%M:%S')"
{
  printf '# VPS 初始化终检报告\n\n'
  printf -- '- 主机： %s\n' "${HOSTN}"
  printf -- '- 时间： %s\n' "${DATE_STR}"
  printf -- '- 发行版： %s\n' "$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
  echo ""
  printf '## 配置摘要（来自 %s）\n\n' "${CONF}"
  if [[ "${HAS_CONF}" -eq 1 ]]; then
    [[ -n "${ADMIN_USER}" ]]   && printf -- '- 管理员用户： %s\n' "${ADMIN_USER}"
    [[ -n "${SSH_PORT}" ]]     && printf -- '- SSH 端口： %s\n' "${SSH_PORT}"
    [[ -n "${ALLOWED_PORTS}" ]] && printf -- '- 额外放行端口： %s\n' "${ALLOWED_PORTS}"
    grep -E '^F2B_' "${CONF}" 2>/dev/null | sed 's/^/- /' || true
  else
    echo '- （conf 缺失，无摘要）'
  fi
  echo ""
  echo "## 检查结果（通过 ${OKN} / 红灯 ${RED} / 提示 ${YEL}）"
  echo ""
  printf '%s\n' "${REPORT_LINES[@]}"
} > "${REPORT}"

echo ""
log "报告已写入 ${REPORT}"
if [[ "${RED}" -gt 0 ]]; then
  warn "存在 ${RED} 项红灯：安全基线未达成，退出码 1"
  exit 1
fi
log "无红灯。第 12 步完成（第 13 步：核对报告 + 创建 Snapshot）"
