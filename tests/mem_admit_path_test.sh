#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：tools/mem_admit.sh
# 队列账本在带空格的路径下，路径片段可能撞上无关文件。直接测准入判定，不起实际作业。
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d /tmp/s2a-mem-path.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT
printf 'on\n' > "$T/Application"

ticket() { printf '%s\t%s\t%s\t%s\t%s\t1\n' "$MA_ME" "$2" "$3" "$4" "$5" > "$MA_DIR/q.$1.$MA_ME"; }

check() (
  export S2A_MEM_DIR="$T/Application Support/S2Arm macOS 14/$1"
  export S2A_MEM_STARVE_S=10 S2A_MEM_AVAIL_GB=5
  export GLOBSORT=-name  # 调用方的 Bash 5.3 设置不应改变队列顺序
  source "$H/tools/mem_admit.sh"
  mkdir -p "$MA_DIR" || exit 1
  MA_ME=$$ MA_NEED10=20 MA_TOTAL10=100 MA_CORES=1 MA_NCORES=4
  MA_CLS=dsh MA_KEY=current MA_PRIO= MA_SRC=估
  MA_TK="$MA_DIR/q.20.$MA_ME" MA_USE="$MA_DIR/use.$MA_ME"
  now=$(date +%s); aged=$((now - 60))
  case $1 in
    head) MA_NEED10=120 ;;
    aged) ticket 10 40 dsh older "$aged" ;;
    later) ticket 10 80 dsh too_large "$aged"; ticket 30 40 dsh newer "$aged" ;;
    priority) ticket 01 40 appbuild first "$now" ;;
  esac
  ticket 20 "$MA_NEED10" dsh current "$now"
  _ma_try; rc=$?
  case $1 in
    head|later)
      [ "$rc" = 0 ] && [ ! -e "$MA_TK" ] && [ "$(cut -f2-4 "$MA_USE")" = "$MA_NEED10"$'\tdsh\tcurrent' ] ;;
    aged) [ "$rc" = 2 ] && [ -f "$MA_TK" ] && [ ! -e "$MA_USE" ] && [[ "$MA_WHY" = *dsh/older*给它预留* ]] ;;
    priority) [ "$rc" = 2 ] && [ -f "$MA_TK" ] && [ ! -e "$MA_USE" ] && [[ "$MA_WHY" = *优先类别*appbuild/first* ]] ;;
  esac
)

bad=0
for scenario in head aged later priority; do
  check "$scenario"; rc=$?
  if [ "$rc" = 0 ]; then
    echo "通 带空格路径 $scenario"
  else
    echo "不通 带空格路径 ${scenario}（rc=${rc}）"
    bad=1
  fi
done
exit "$bad"
