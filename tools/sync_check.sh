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

# ---- 包清单一致性：02-tools.sh 的 BASE / TOOLS_EXTRA 默认值 vs README 与手动教程 ----
norm_list() { tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'; }
BASE_LIST="$(sed -n 's/^BASE="\(.*\)"$/\1/p' 02-tools.sh | norm_list)"
EXTRA_LIST="$(sed -n 's/.*v_any "\([^"]*\)").*/\1/p' 02-tools.sh | norm_list)"
README_BASE="$(grep -o '`sudo ca-certificates[^`]*`' README.md | head -1 | tr -d '`' | norm_list)"
README_EXTRA="$(grep -o '默认 `jq [^`]*`' README.md | head -1 | sed 's/默认 //' | tr -d '`' | norm_list)"
TUT_LIST="$(sed -n '/^apt install -y sudo ca-certificates/,/[^\\]$/p' docs/tutorial.md \
            | tr -d '\\' | sed 's/^apt install -y //' | norm_list)"
EXPECT_ALL="$(printf '%s %s' "${BASE_LIST}" "${EXTRA_LIST}" | norm_list)"

check_list() {   # check_list <名称> <02-tools.sh 侧> <文档侧>
  [[ "$2" == "$3" ]] && return 0
  echo "❌ $1 与 02-tools.sh 不一致"
  echo "    02-tools.sh: $2"
  echo "    $1: $3"
  BAD+=1
}

if [[ -z "${BASE_LIST}" ]]; then
  echo "❌ 未能从 02-tools.sh 提取 BASE 包清单"
  BAD+=1
else
  check_list "README 包清单" "${BASE_LIST}" "${README_BASE}"
  check_list "README TOOLS_EXTRA 默认值" "${EXTRA_LIST}" "${README_EXTRA}"
  check_list "tutorial 包清单" "${EXPECT_ALL}" "${TUT_LIST}"
fi

# ---- 公共变量一致性：定义必须唯一一致；用到就必须定义 ----
# 覆盖全部脚本（含 08-swap.sh）：08 自带独立 helper，不参与公共函数比对，
# 但只要它用了 CONF/BK_ROOT 就必须自己定义（set -u 下未定义即崩）。
# 背景：变量赋值原先不在自检范围内——06/07/09 曾漏定义 BK_ROOT，
# 首次运行因 backup_file 对不存在文件提前返回而掩盖，重跑触发备份时才崩。
ALL_SCRIPTS="${SCRIPTS} 08-swap.sh"
check_var() {   # check_var <变量名>
  local var="$1" val="" val_src="" v="" line="" defs=""
  for f in ${ALL_SCRIPTS}; do
    [[ -f "$f" ]] || continue
    defs="$(grep -E "^[[:space:]]*(readonly[[:space:]]+)?${var}=" "$f" || true)"
    if [[ -n "${defs}" ]]; then
      while IFS= read -r line; do
        v="${line#*=}"
        v="${v%\"}"; v="${v#\"}"          # 去外层双引号
        if [[ -z "${val}" ]]; then
          val="${v}"; val_src="${f}"
        elif [[ "${v}" != "${val}" ]]; then
          echo "❌ ${var} 取值不一致：${val_src}=${val} vs ${f}=${v}"
          BAD+=1
        fi
      done <<<"${defs}"
    elif grep -v '^[[:space:]]*#' "$f" | grep -qE "\\\$\{?${var}[^A-Za-z0-9_]"; then
      echo "❌ ${var} 在 ${f} 中被使用但从未定义（set -u 下会崩）"
      BAD+=1
    fi
  done
}
check_var CONF
check_var BK_ROOT

# ---- 脚本清单完整性：预期脚本文件必须存在（防误删/改名）----
for f in ${ALL_SCRIPTS}; do
  [[ -f "${f}" ]] || { echo "❌ 缺少脚本文件：${f}"; BAD+=1; }
done

[[ $BAD -eq 0 ]] && echo "=== 一致性 OK ===" || echo "=== ${BAD} 处仍有差异 ==="
