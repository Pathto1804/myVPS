#!/usr/bin/env bash
# VPS 初始化 · 09 BBR + TCP 调优
# 自包含 + 幂等。用法：sudo bash bbr.sh
# 项目：https://raw.githubusercontent.com/Pathto1804/myVPS/main/bbr.sh
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
require_tty()    { [[ -t 0 ]] || die "需要交互终端，不支持无人值守（防锁死设计）"; }
require_distro() {
  local id
  id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
  [[ "${id}" == "debian" || "${id}" == "ubuntu" ]] || die "仅支持 Debian/Ubuntu，当前为 ${id:-未知}"
}

backup_file() {
  local path="$1" stamp dir
  [[ -e "${path}" ]] || { printf ''; return 0; }
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="/root/vps-init-backups/${stamp}"
  mkdir -p "${dir}"
  cp -a "${path}" "${dir}/"
  printf '%s已备份 %s -> %s/\n' "${C_G}" "${path}" "${dir}" >&2
  printf '%s' "${dir}"
}

# ==================== 脚本主体 ====================

require_root
require_tty
require_distro

SYSCTL_CONF="/etc/sysctl.d/99-bbr.conf"

# 目标配置：BBR + fq + TCP 调优（外部获取的调参集，逐行可审）
read -r -d '' CONF_CONTENT <<'EOF' || true
kernel.pid_max = 65535
kernel.panic = 1
kernel.sysrq = 1
kernel.core_pattern = core_%e
kernel.printk = 3 4 1 3
kernel.numa_balancing = 0
kernel.sched_autogroup_enabled = 0

vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.panic_on_oom = 1
vm.overcommit_memory = 1
vm.min_free_kbytes = 64194

net.core.default_qdisc = fq
net.core.netdev_max_backlog = 2000
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.rmem_default = 87380
net.core.wmem_default = 65536
net.core.somaxconn = 256
net.core.optmem_max = 32768

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 0

net.ipv4.tcp_rmem = 8192 87380 748300
net.ipv4.tcp_wmem = 8192 65536 374150
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 4096
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 3
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 0

net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_max_orphans = 65536
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_stdurg = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_syncookies = 1

net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.route.gc_timeout = 100
net.ipv4.neigh.default.gc_stale_time = 120
net.ipv4.neigh.default.gc_thresh3 = 8192
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh1 = 1024

net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1
EOF

# 幂等：内容一致则跳过写入
if [[ -f "${SYSCTL_CONF}" ]] && diff -q <(printf '%s\n' "${CONF_CONTENT}") "${SYSCTL_CONF}" >/dev/null 2>&1; then
  log "配置已存在且一致：${SYSCTL_CONF}，跳过写入"
else
  backup_file "${SYSCTL_CONF}" >/dev/null
  printf '%s\n' "${CONF_CONTENT}" > "${SYSCTL_CONF}"
  log "已写入 ${SYSCTL_CONF}"
fi

# 应用；个别键在当前内核不存在时（如 tcp_fack 已移除）仅警告
if ! sysctl -p "${SYSCTL_CONF}" 2>/dev/null; then
  warn "部分键应用失败（新版内核可能已移除个别键，如 tcp_fack），逐行核对上面输出"
fi

# 验证核心项
CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | tr -d '\r')"
QC="$(sysctl -n net.core.default_qdisc 2>/dev/null | tr -d '\r')"
[[ "${CC}" == "bbr" ]] || die "tcp_congestion_control = ${CC:-未知}，非 bbr；请检查内核版本（需 >= 4.9）"
[[ "${QC}" == "fq" ]]  || warn "default_qdisc = ${QC:-未知}，非 fq（BBR 仍工作，但推荐 fq）"

log "BBR 已启用（congestion_control=${CC}, qdisc=${QC}）"
log "第 9 步完成"
