#!/usr/bin/env bash
set -euo pipefail
FUNCS="log warn die err_trap require_root require_tty require_distro ask_yesno ask_input ask_input_def backup_file conf_has conf_read conf_write conf_get conf_update v_any v_yesno v_user v_pubkey v_ssh_port v_ports_list"
SCRIPTS="01-update.sh 02-tools.sh 04-user.sh 05-ufw.sh 06-ssh.sh 07-fail2ban.sh 09-bbr.sh 12-verify.sh"
declare -i BAD=0
for fn in $FUNCS; do
  declare -A H=()
  for f in $SCRIPTS; do
    [[ -f "$f" ]] || continue
    body=$(sed -n "/^${fn}()/,/\$/p" "$f" | sed -n '1p')     # 单行函数取行
    body2=$(sed -n "/^${fn}() {/,/^\}/p" "$f")               # 多行函数取块
    body="${body:-$body2}"
    [[ -n "$body" ]] || body="$body2"
    # 用 grep 精确行
    line=$(grep "^${fn}()" "$f" 2>/dev/null | head -1 || true)
    [[ -z "$line" ]] && continue
    if [[ "$line" == *"{"* ]] && [[ "$line" != *"}"* ]]; then
      body=$(sed -n "/^${fn}() {/,/^\}/p" "$f")
    else
      body="$line"
    fi
    h=$(printf '%s' "$body" | md5sum | cut -c1-8)
    H[$h]="${H[$h]:-} $f"
  done
  c=0; for _ in "${!H[@]}"; do c=$((c+1)); done
  if [[ $c -gt 1 ]]; then
    echo "❌ $fn ($c 种):"
    for h in "${!H[@]}"; do echo "    ${H[$h]}"; done
    BAD+=1
  fi
done
[[ $BAD -eq 0 ]] && echo "=== 一致性 OK ===" || echo "=== ${BAD} 个函数仍有差异 ==="
