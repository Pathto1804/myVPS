#!/usr/bin/env bash
# VPS 初始化 · 02 基础工具
# 自包含 + 幂等 + 交互闸门。用法：sudo bash 02-tools.sh
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/02-tools.sh

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CONF="/root/.vps-init.conf"
# shellcheck disable=SC2034  # 公共内联块统一保留
BK_ROOT="/root/vps-init-backups"

if [[ -t 1 ]]; then
  C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  # shellcheck disable=SC2034
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

ask_input_def() {
  # ask_input_def <提示> <校验函数名> <默认值>——空输入取默认值
  local prompt="$1" v="$2" def="$3" val
  while :; do
    read -rp "${prompt} [回车=建议: ${def}] " val || die "输入中断"
    val="${val:-${def}}"
    if "${v}" "${val}"; then printf '%s' "${val}"; return 0; fi
  done
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

v_any()      { return 0; }

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

require_root
require_tty
require_distro

log "安装基础工具……"
export DEBIAN_FRONTEND=noninteractive
apt-get update
# 空 TOOLS_EXTRA 时 word-splitting 为无参数，安全
apt-get install -y ${BASE} ${TOOLS_EXTRA}

log "本次安装包：${BASE} ${TOOLS_EXTRA}"
log "第 2 步完成"