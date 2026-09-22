#!/usr/bin/env bash
#
# swap.sh - VPS Swap 交互管理脚本（Debian / Ubuntu）
#
# 用法:
#   sudo bash swap.sh
#
# 功能: 查看 / 创建(替换) / 调整 swappiness / 关闭并删除 swap 文件
# 依赖: 仅系统自带工具（util-linux、coreutils、procps）
# 限制:
#   - 不支持 btrfs / ZFS 上的 swap 文件（脚本会检测并明确报错）
#   - OpenVZ / LXC 容器无法自行启用 swap（内核限制，脚本会检测并解释）
#   - 只管理 swap 文件，不动 swap 分区
#
# 本脚本对系统的全部改动（均可在"删除"流程中完整回滚）:
#   1. swap 文件本体（默认 /swapfile）
#   2. /etc/fstab 中的一行 swap 条目（每次修改前自动备份）
#   3. /etc/sysctl.d/99-swappiness.conf（swappiness 配置，可选）

set -uo pipefail

# ============ 常量 ============

readonly FSTAB=/etc/fstab
readonly SYSCTL_CONF=/etc/sysctl.d/99-swappiness.conf
readonly SWAPPINESS_RE='^([0-9]|[1-9][0-9]|100)$'
readonly MIN_SWAP_MB=64        # swap 最小值
readonly WARN_FREE_MB=2048     # 创建 swap 后分区剩余低于此值时警告

# 主菜单选项（ask_option 的输入与 case 匹配共用同一常量，避免两处维护）
readonly M_STATUS="查看 Swap 状态"
readonly M_CREATE="创建 / 替换 Swap"
readonly M_SWAPPINESS="调整 swappiness"
readonly M_DELETE="关闭并删除 Swap"
readonly M_QUIT="退出"

# 运行期状态
PARTIAL_FILE=""                # 创建流程未完成时的 swap 文件路径（供 trap 清理）
FSTAB_BAK=""                   # 最近一次 fstab 备份路径
FSTAB_BAK_COUNT=0              # 同一次运行内的备份序号（防同秒覆盖）
FSTAB_BASELINE=0               # fstab 修改前 findmnt --verify 的退出码（校验基线）

# ============ 颜色与输出 ============

if [[ -t 1 ]]; then
  readonly C_G=$'\e[32m' C_Y=$'\e[33m' C_R=$'\e[31m' C_B=$'\e[1m' C_0=$'\e[0m'
else
  readonly C_G='' C_Y='' C_R='' C_B='' C_0=''
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s\n' "$C_G" "$*" "$C_0"; }
warn() { printf '%s%s[警告]%s %s\n' "$C_Y" "$C_B" "$C_0" "$*" >&2; }
err()  { printf '%s%s[错误]%s %s\n' "$C_R" "$C_B" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ============ 失败清理 ============
# 创建流程中途失败或被 Ctrl+C 打断时，删除半成品 swap 文件，不留残留。

cleanup() {
  local rc=$?
  if [[ -n "$PARTIAL_FILE" ]]; then
    swapoff "$PARTIAL_FILE" 2>/dev/null || true
    rm -f -- "$PARTIAL_FILE"
    err "操作未完成，已清理残留文件: $PARTIAL_FILE"
    if [[ -n "$FSTAB_BAK" && -f "$FSTAB_BAK" ]]; then
      err "如 fstab 异常，可用备份恢复: cp -a $FSTAB_BAK $FSTAB"
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ============ 交互 helper ============
# 约定: ask_option / ask_value 把结果写入全局变量 ANSWER；confirm 只用返回码。

# ask_option [--zero "0号选项文本"] "提示" "选项1" "选项2" ... -> ANSWER = 选中的选项文本
# --zero 时额外提供 0) 编号选项（菜单约定 0 = 退出类操作）
ask_option() {
  local zero_label=""
  if [[ "${1-}" == "--zero" ]]; then
    zero_label="$2"
    shift 2
  fi
  local prompt="$1"; shift
  local opts=("$@") i input lo max
  max=${#opts[@]}
  if [[ -n "$zero_label" ]]; then lo=0; else lo=1; fi
  while true; do
    printf '\n%s%s%s\n' "$C_B" "$prompt" "$C_0"
    for i in "${!opts[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${opts[$i]}"
    done
    [[ -n "$zero_label" ]] && printf '  0) %s\n' "$zero_label"
    printf '请输入编号 [%d-%d]: ' "$lo" "$max"
    read -r input || die "输入中断，退出"
    if [[ "$input" == "0" && -n "$zero_label" ]]; then
      ANSWER="$zero_label"
      return 0
    fi
    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= max )); then
      ANSWER="${opts[input - 1]}"
      return 0
    fi
    warn "无效输入: $input（请输入 $lo-$max 的编号）"
  done
}

# ask_value "提示" "校验正则" "默认值(可空)" -> ANSWER = 输入值（空输入取默认值）
ask_value() {
  local prompt="$1" regex="$2" default="${3-}" input
  while true; do
    if [[ -n "$default" ]]; then
      printf '%s [默认: %s]: ' "$prompt" "$default"
    else
      printf '%s: ' "$prompt"
    fi
    read -r input || die "输入中断，退出"
    input="${input:-$default}"
    if [[ "$input" =~ $regex ]]; then
      ANSWER="$input"
      return 0
    fi
    warn "输入无效，请重新输入"
  done
}

# confirm "问题" [y|n 默认值] -> 返回码 0=是 1=否
confirm() {
  local prompt="$1" default="${2:-y}" ans
  while true; do
    if [[ "$default" == "y" ]]; then
      printf '%s [Y/n]: ' "$prompt"
    else
      printf '%s [y/N]: ' "$prompt"
    fi
    read -r ans || die "输入中断，退出"
    ans="${ans:-$default}"
    case "$ans" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) warn "请输入 y 或 n" ;;
    esac
  done
}

# ============ 系统状态探测 ============
# 原则: 每次实时读系统真相，不缓存、不写脚本私有状态文件，
# 因此可以管理任何来源（包括其他工具创建）的 swap。

get_mem_mb()      { free -m | awk '/^Mem:/{print $2}'; }
get_mem_h()       { free -h | awk '/^Mem:/{print $2}'; }
get_swappiness()  { sysctl -n vm.swappiness 2>/dev/null || echo '?'; }

# 交互默认值用: 取不到当前 swappiness 时回退 10
get_swappiness_default() {
  local v
  v=$(get_swappiness)
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 10
}

# 当前已启用的 swap 文件列表（不含分区），每行一个路径
get_active_swap_files() { awk 'NR>1 && $2=="file"{print $1}' /proc/swaps; }

# $1 是否为当前已启用的 swap 文件
is_active_swap() { awk -v p="$1" 'NR>1 && $2=="file" && $1==p{f=1} END{exit (f?0:1)}' /proc/swaps; }

# 缩进展示内存/Swap 概览（free 前三行）
show_free_h() { free -h | sed -n '1,3p' | sed 's/^/  /'; }

# $1 所在挂载点的文件系统类型
get_fstype_of()   { findmnt -n -o FSTYPE "$1" 2>/dev/null; }

# $1 所在分区的剩余空间（MB）
get_avail_mb()    { df -BM --output=avail "$1" | awk 'NR==2{gsub(/M$/,"");print}'; }

# fstab 中的全部 swap 条目路径（每行一个）
fstab_swap_entries() { awk '$3=="swap"{print $1}' "$FSTAB" 2>/dev/null; }

# fstab 中是否存在指向 $1 的条目
fstab_has_entry() { awk -v p="$1" '$1==p{f=1} END{exit (f?0:1)}' "$FSTAB" 2>/dev/null; }

# ============ fstab 安全写入 ============
# fstab 是本脚本唯一的高危写操作（写坏会导致系统无法启动），
# 因此每次修改前备份，修改后用 findmnt --verify 校验，
# 校验失败且修改前基线正常时自动恢复备份。

fstab_backup() {
  FSTAB_BAK_COUNT=$((FSTAB_BAK_COUNT + 1))
  FSTAB_BAK="$FSTAB.bak.$(date +%Y%m%d-%H%M%S).$FSTAB_BAK_COUNT"
  cp -a -- "$FSTAB" "$FSTAB_BAK" || die "备份 $FSTAB 失败"
  info "已备份 fstab -> $FSTAB_BAK"
}

# 修改 fstab 前调用: 备份并记录校验基线
fstab_prepare_edit() {
  fstab_backup
  findmnt --verify >/dev/null 2>&1
  FSTAB_BASELINE=$?
}

# 修改 fstab 后调用: 校验; 失败且基线正常时自动从备份恢复
fstab_verify_or_restore() {
  local rc
  findmnt --verify >/dev/null 2>&1
  rc=$?
  if (( rc != 0 )); then
    if (( FSTAB_BASELINE == 0 )); then
      err "fstab 校验失败，正在从备份恢复..."
      cat "$FSTAB_BAK" > "$FSTAB" || die "恢复 $FSTAB 失败，请手动执行: cp -a $FSTAB_BAK $FSTAB"
      die "fstab 已恢复原状，操作中止"
    else
      warn "fstab 校验发现问题，但修改前基线同样异常（非本次修改引起），请手动检查: $FSTAB"
    fi
  fi
}

# 追加一行 "$1 none swap sw 0 0"
fstab_append_swap() {
  fstab_prepare_edit
  printf '%s none swap sw 0 0\n' "$1" >> "$FSTAB" || die "写入 $FSTAB 失败"
  fstab_verify_or_restore
}

# 移除所有指向 $1 的 swap 条目（用 awk 重写，cat 回写以保留原文件权限/属主）
fstab_remove_swap() {
  local tmp
  fstab_prepare_edit
  tmp=$(mktemp) || die "创建临时文件失败"
  awk -v p="$1" '$1 != p' "$FSTAB" > "$tmp" || { rm -f "$tmp"; die "处理 $FSTAB 失败"; }
  cat "$tmp" > "$FSTAB" || { rm -f "$tmp"; die "写回 $FSTAB 失败，请手动检查备份: $FSTAB_BAK"; }
  rm -f "$tmp"
  fstab_verify_or_restore
}

# ============ 工具函数 ============

# "2G" / "512m" / "1024"(纯数字按 MB) -> MB 数值（stdout）；格式非法返回 1
size_to_mb() {
  local s="$1" n u
  if [[ "$s" =~ ^([0-9]+)([GgMm]?)$ ]]; then
    n=$((10#${BASH_REMATCH[1]}))
    u="${BASH_REMATCH[2],,}"
    if [[ "$u" == "g" ]]; then
      echo $((n * 1024))
    else
      echo "$n"
    fi
    return 0
  fi
  return 1
}

# 按物理内存给出推荐大小（MB）: 内存 <= 2G 推荐 2G，更大推荐 4G（封顶）
recommend_size_mb() {
  local mem
  mem=$(get_mem_mb)
  [[ "$mem" =~ ^[0-9]+$ ]] || mem=2048
  if (( mem <= 2048 )); then echo 2048; else echo 4096; fi
}

# 写入并立即生效 swappiness（$1 = 值）
write_swappiness() {
  local val="$1"
  mkdir -p /etc/sysctl.d
  if [[ -f "$SYSCTL_CONF" ]] && grep -q '^vm\.swappiness' "$SYSCTL_CONF" 2>/dev/null; then
    sed -i "s/^vm\.swappiness.*/vm.swappiness = $val/" "$SYSCTL_CONF"
  else
    printf 'vm.swappiness = %s\n' "$val" >> "$SYSCTL_CONF"
  fi
  sysctl -p "$SYSCTL_CONF" >/dev/null || die "应用 swappiness 失败"
  ok "swappiness 已设置为 $val（写入 $SYSCTL_CONF）"
}

# 删除单个 swap 文件: 停用（若在用）-> 删文件 -> 移除 fstab 条目
delete_swap_file() {
  local path="$1"
  if is_active_swap "$path"; then
    info "正在停用 $path（若 swap 正被使用可能需要一些时间）..."
    if ! swapoff "$path" 2>/dev/null; then
      err "swapoff 失败: $path"
      return 1
    fi
  fi
  rm -f -- "$path" || { err "删除文件失败: $path"; return 1; }
  if fstab_has_entry "$path"; then
    fstab_remove_swap "$path"
  fi
  ok "已删除 $path"
}

# ============ 菜单顶部状态摘要 ============

show_status_line() {
  local mem swap
  mem=$(get_mem_h)
  swap=$(free -h | awk '/^Swap:/{print $2}')
  if [[ -z "$swap" || "$swap" == "0B" || "$swap" == "0" ]]; then
    swap="未启用"
  fi
  printf '内存: %s | Swap: %s | swappiness: %s' "$mem" "$swap" "$(get_swappiness)"
}

# ============ 功能: 查看状态 ============

do_status() {
  local -a files entries
  printf '\n%s========== Swap 状态 ==========%s\n' "$C_B" "$C_0"

  info "内存使用:"
  show_free_h

  echo
  mapfile -t files < <(get_active_swap_files)
  if ((${#files[@]} > 0)); then
    info "已启用的 swap:"
    # 注意: 不带 --output，默认列即 NAME TYPE SIZE USED PRIO；
    # 某些 util-linux 版本会把 --output 解析成 --output-all 的前缀而报错
    swapon --show | sed 's/^/  /'
  else
    info "已启用的 swap: 无"
  fi

  echo
  if [[ -f "$SYSCTL_CONF" ]]; then
    info "swappiness 当前值: $(get_swappiness)（配置文件: $SYSCTL_CONF）"
  else
    info "swappiness 当前值: $(get_swappiness)（无独立配置文件，使用系统默认）"
  fi

  echo
  mapfile -t entries < <(fstab_swap_entries)
  if ((${#entries[@]} > 0)); then
    info "fstab 中的 swap 条目:"
    printf '  %s\n' "${entries[@]}"
  else
    info "fstab 中的 swap 条目: 无"
  fi

  echo
  info "根分区空间:"
  df -h / | sed -n '2p' | sed 's/^/  /'
}

# ============ 功能: 创建 / 替换 ============

do_create() {
  local -a active size_opts
  local f mb mark rec_mb mem_h size_label size_mb path dir fstype avail_mb
  local cur_sw new_sw=""

  # -- 已有 swap: 询问替换（先删后建，不并存）还是取消 --
  mapfile -t active < <(get_active_swap_files)
  if ((${#active[@]} > 0)); then
    warn "检测到已启用的 swap 文件:"
    printf '  %s\n' "${active[@]}"
    if confirm "替换 = 先删除以上 swap 文件，再创建新的。是否继续替换?" "y"; then
      for f in "${active[@]}"; do
        delete_swap_file "$f" || die "替换失败: 无法删除旧 swap 文件 $f"
      done
    else
      info "已取消。"
      return 0
    fi
  fi

  # -- 收集输入: 大小 --
  rec_mb=$(recommend_size_mb)
  mem_h=$(get_mem_h)
  for mb in 1024 2048 4096 8192; do
    mark=""
    (( mb == rec_mb )) && mark="（推荐）"
    size_opts+=("$((mb / 1024))G$mark")
  done
  size_opts+=("自定义大小")

  ask_option "请选择 Swap 大小（物理内存: $mem_h）" "${size_opts[@]}"
  size_label=$ANSWER
  case "$size_label" in
    "1G"*) size_mb=1024 ;;
    "2G"*) size_mb=2048 ;;
    "4G"*) size_mb=4096 ;;
    "8G"*) size_mb=8192 ;;
    *)
      while true; do
        ask_value "自定义大小（如 2G、512M，纯数字按 MB 计算）" '^[0-9]+[GgMm]?$' "1024"
        size_mb=$(size_to_mb "$ANSWER") || { warn "无法解析大小"; continue; }
        if (( size_mb < MIN_SWAP_MB )); then
          warn "Swap 至少需要 ${MIN_SWAP_MB}MB"
          continue
        fi
        break
      done
      ;;
  esac

  # -- 收集输入: 路径 --
  while true; do
    ask_value "Swap 文件路径" '^/[A-Za-z0-9._/-]+$' '/swapfile'
    path=$ANSWER
    if [[ "$path" == *".."* || "$path" == */ ]]; then
      warn "路径不合法（不能包含 .. 或以 / 结尾）"
      continue
    fi
    dir=$(dirname -- "$path")
    if [[ ! -d "$dir" ]]; then
      warn "目录不存在: $dir"
      continue
    fi
    if [[ -e "$path" ]]; then
      warn "文件已存在: $path（请换一个路径，或先用「删除」功能清理）"
      continue
    fi
    break
  done

  # -- 前置检查: 文件系统 --
  fstype=$(get_fstype_of "$dir")
  case "$fstype" in
    btrfs|zfs)
      die "文件系统 $fstype 不支持常规方式的 swap 文件（$dir 所在分区），本脚本不处理，已退出。"
      ;;
    "")
      warn "无法识别 $dir 的文件系统类型，将继续尝试。"
      ;;
  esac

  # -- 前置检查: 磁盘剩余空间 --
  avail_mb=$(get_avail_mb "$dir")
  [[ "$avail_mb" =~ ^[0-9]+$ ]] || die "无法获取磁盘剩余空间"
  if (( size_mb > avail_mb )); then
    err "空间不足: 需要 ${size_mb}M，该分区仅剩 ${avail_mb}M"
    return 1
  fi
  if (( avail_mb - size_mb < WARN_FREE_MB )); then
    warn "创建后该分区剩余空间仅 $((avail_mb - size_mb))M（不足 ${WARN_FREE_MB}M），系统运行可能紧张"
    confirm "仍要继续?" "n" || { info "已取消。"; return 0; }
  fi

  # -- 收集输入: swappiness --
  cur_sw=$(get_swappiness_default)
  if confirm "是否同时调整 swappiness（当前: ${cur_sw}）?" "y"; then
    ask_value "swappiness 值（0-100，VPS 常用 10）" "$SWAPPINESS_RE" "10"
    new_sw=$ANSWER
  fi

  # -- 汇总确认 --
  printf '\n%s---------- 即将执行 ----------%s\n' "$C_B" "$C_0"
  printf '  Swap 文件:   %s (%sM)\n' "$path" "$size_mb"
  printf '  文件系统:    %s\n' "${fstype:-未知}"
  printf '  开机持久化:  写入 %s\n' "$FSTAB"
  if [[ -n "$new_sw" ]]; then
    printf '  swappiness:  %s -> %s\n' "$cur_sw" "$new_sw"
  fi
  printf '%s------------------------------%s\n' "$C_B" "$C_0"
  confirm "确认执行?" "y" || { info "已取消。"; return 0; }

  # -- 执行: 从这里起 PARTIAL_FILE 生效，任何失败/Ctrl+C 都会触发清理 --
  PARTIAL_FILE="$path"

  info "1/5 创建文件（${size_mb}M）..."
  if ! fallocate -l "${size_mb}M" "$path" 2>/dev/null; then
    warn "fallocate 不可用（${fstype:-该文件系统}可能不支持），改用 dd 逐块写入，无进度显示，请耐心等待..."
    dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=none 2>/dev/null \
      || die "创建文件失败"
  fi

  info "2/5 设置权限（600）..."
  chmod 600 "$path" || die "chmod 失败"

  info "3/5 格式化为 swap..."
  mkswap "$path" >/dev/null || die "mkswap 失败"

  info "4/5 启用 swap..."
  if ! swapon "$path" 2>/dev/null; then
    local virt
    virt=$(systemd-detect-virt 2>/dev/null || true)
    case "$virt" in
      openvz|lxc)
        err "swapon 失败: 当前运行在 ${virt} 容器中，内核不允许自行启用 swap。"
        err "此类 VPS 无法使用本脚本创建 swap（如需 swap 请联系服务商）。"
        ;;
      *)
        err "swapon 失败（未知原因），可运行 dmesg | tail 查看内核日志。"
        ;;
    esac
    die "已清理，未对系统留下改动"
  fi
  ok "  swap 已启用"

  info "5/5 写入 fstab 实现开机持久化..."
  if fstab_has_entry "$path"; then
    warn "$FSTAB 已存在 $path 的条目，跳过写入"
  else
    fstab_append_swap "$path"
  fi

  # 全部成功，解除清理标记
  PARTIAL_FILE=""

  if [[ -n "$new_sw" ]]; then
    write_swappiness "$new_sw"
  fi

  printf '\n'
  ok "完成！当前内存状态:"
  show_free_h
  printf '\n'
}

# ============ 功能: 调整 swappiness ============

do_swappiness() {
  local cur val
  printf '\n%s========== 调整 swappiness ==========%s\n' "$C_B" "$C_0"
  cur=$(get_swappiness)
  info "当前值: $cur（0 = 尽量不用 swap，100 = 积极使用；VPS 一般推荐 10）"
  if [[ -f "$SYSCTL_CONF" ]]; then
    info "配置文件: $SYSCTL_CONF"
  else
    info "尚无独立配置文件，将创建: $SYSCTL_CONF"
  fi
  ask_value "新的 swappiness 值（0-100）" "$SWAPPINESS_RE" "$(get_swappiness_default)"
  val=$ANSWER
  if [[ "$val" == "$(get_swappiness)" ]]; then
    info "与当前值相同，未修改。"
    return 0
  fi
  write_swappiness "$val"
  info "验证: 当前生效值 = $(get_swappiness)"
}

# ============ 功能: 关闭并删除 ============

do_delete() {
  local -a files
  local f prompt
  printf '\n%s========== 关闭并删除 Swap ==========%s\n' "$C_B" "$C_0"

  # 候选 = 已启用的 swap 文件 + fstab 有条目、文件存在但未启用的残留
  # （后者如开机时 swapon 失败留下的死条目，不清理会让"创建"因文件已存在而被拒）
  mapfile -t files < <(get_active_swap_files)
  while read -r f; do
    [[ -n "$f" ]] || continue
    [[ -f "$f" ]] || continue
    is_active_swap "$f" || files+=("$f")
  done < <(fstab_swap_entries)
  if ((${#files[@]} == 0)); then
    info "没有可删除的 swap 文件（无已启用的，也无 fstab 残留条目）。"
    return 0
  fi

  # swap 分区只读展示，绝不处理
  if awk 'NR>1 && $2=="partition"' /proc/swaps | grep -q .; then
    info "注: 检测到 swap 分区，本脚本只处理 swap 文件，不会触碰分区。"
  fi

  for f in "${files[@]}"; do
    printf '\n'
    if is_active_swap "$f"; then
      prompt="确认删除 $f ?（停用 + 删除文件 + 移除 fstab 条目）"
    else
      prompt="确认清理 $f ?（当前未启用，仅删除文件 + 移除 fstab 条目）"
    fi
    if confirm "$prompt" "n"; then
      delete_swap_file "$f" || err "删除 $f 失败，已跳过"
    fi
  done

  # 全部 swap 文件删除后，询问是否顺带移除 swappiness 配置
  mapfile -t files < <(get_active_swap_files)
  if ((${#files[@]} == 0)) && [[ -f "$SYSCTL_CONF" ]] \
     && confirm "是否同时移除 swappiness 配置（$SYSCTL_CONF）?" "n"; then
    rm -f -- "$SYSCTL_CONF"
    sysctl -w vm.swappiness=60 >/dev/null
    ok "已移除 $SYSCTL_CONF；运行时 swappiness 已设为 60（Debian/Ubuntu 默认值），重启后同样生效"
  fi
}

# ============ 前置检查与主菜单 ============

preflight() {
  [[ $EUID -eq 0 ]] || die "请以 root 身份运行: sudo bash swap.sh"

  # 交互脚本需要真实终端（防止 curl | bash 场景下 read 吃到管道内容）
  [[ -t 0 ]] || die "标准输入不是终端。请先下载脚本再运行: curl -fLO <脚本地址> && sudo bash swap.sh"

  local os_id=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
  fi
  case "$os_id" in
    debian|ubuntu) ;;
    *)
      if [[ "${ID_LIKE:-}" == *debian* ]]; then
        warn "检测到 ${PRETTY_NAME:-未知发行版}（Debian 系），按 Debian/Ubuntu 流程继续。"
      else
        die "本脚本仅支持 Debian/Ubuntu，当前系统: ${PRETTY_NAME:-未知}"
      fi
      ;;
  esac

  local cmd
  for cmd in awk sed free findmnt swapon swapoff mkswap fallocate dd chmod sysctl df; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖命令: $cmd"
  done
}

main_menu() {
  while true; do
    printf '\n%s========== VPS Swap 管理工具 ==========%s\n' "$C_B" "$C_0"
    printf '%s\n' "$(show_status_line)"
    ask_option --zero "$M_QUIT" "请选择操作" \
      "$M_STATUS" \
      "$M_CREATE" \
      "$M_SWAPPINESS" \
      "$M_DELETE"
    case "$ANSWER" in
      "$M_STATUS")     do_status ;;
      "$M_CREATE")     do_create ;;
      "$M_SWAPPINESS") do_swappiness ;;
      "$M_DELETE")     do_delete ;;
      "$M_QUIT")       info "再见！"; exit 0 ;;
    esac
  done
}

main() {
  preflight
  main_menu
}

main "$@"
