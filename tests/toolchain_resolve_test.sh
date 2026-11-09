#!/bin/bash
# 工具链解析单测（tools/toolchain.sh，两个假 Xcode + 假 xcrun / xcode-select，约 1 秒）：bash tests/toolchain_resolve_test.sh
# 期望（10-25 维护者「按用户实际装的版本走，不写死」，按规则手写）：
#   ① 启动器传了 S2A_DEVELOPER_DIR=A → 用 A（Metal / SDK 取 A 的），即使 xcode-select 指 B
#   ② 没传 → 用装着的 Xcode 里版本最新的 A（即使 xcode-select 指旧的 B；11-07 Duo：旧 SDK 出的壳在 iOS 新机型上缩小显示）；装着的都不是 Xcode 才退到 xcode-select
#   ③ 解析一次、全程共用：上游用 A 解析过，子进程再 source（此时 xcode-select 改指 B）照旧是 A，不串版本
#   ④ 目标 iOS 大版本：启动器给了 S2A_PSO_OS=26 就用 26；没给按 SDK 大版本（A 的 SDK 27.0 → 27）
#   ⑩ 没指定、找不到装着的 Xcode、xcode-select 指不到 → 报「目录不在」、不退到 tools/toolchain.env 里写的版本
#   ⑤ 能力不够报清楚、不报版本号：没有 Metal 编译器 → 「没有 Metal 编译器」；SDK 17.0 低于下限 18 → 「低于产物下限」；都退出非 0
#   ⑥ #403 正例：合法 Apple 版本行 / 退出 0 → 成功；⑦ 退出 0 但 stdout 只有 error 文本 → 拒绝
#   ⑧ 合法版本 stdout + error 文本 stderr + 退出 1 → 拒绝；⑨ 空 stdout + error 文本 stderr + 退出 1 → 拒绝
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/bin $T/A $T/B $T/C $T/D $T/E $T/F $T/G $T/H; echo 27.0 > $T/A/sdk; echo "Apple metal version 32023.921" > $T/A/metal; echo 26.5 > $T/B/sdk; echo "Apple metal version 32023.883" > $T/B/metal
echo 27.0 > $T/C/sdk; echo 17.0 > $T/D/sdk; echo "Apple metal version 1" > $T/D/metal   # C 没有 Metal 编译器；D 的 SDK 太老
echo 27.0 > $T/E/sdk; echo "Apple metal version 32023.921" > $T/E/metal                     # E 合法版本 / 退出 0
echo 27.0 > $T/F/sdk; echo "error: Metal toolchain is not installed" > $T/F/metal           # F 退出 0 但 stdout 是 error 文本
echo 27.0 > $T/G/sdk; echo "Apple metal version 32023.921" > $T/G/metal; echo "error: Metal toolchain component unavailable" > $T/G/metal.err; echo 1 > $T/G/metal.rc   # G 合法版本 + stderr error / 退出 1
echo 27.0 > $T/H/sdk; : > $T/H/metal; echo "error: Metal toolchain component unavailable" > $T/H/metal.err; echo 1 > $T/H/metal.rc   # H 空 stdout + stderr error / 退出 1
cat > $T/bin/xcrun <<'EOF'
#!/bin/bash
if [ -f "$DEVELOPER_DIR/mac-only" ]; then
  case " $* " in *" macosx "*) ;; *) exit 1;; esac
fi
case " $* " in *" --show-sdk-version "*) cat "$DEVELOPER_DIR/sdk" 2> /dev/null || exit 1;; *" metal --version "*) cat "$DEVELOPER_DIR/metal" 2> /dev/null || exit 1; [ ! -f "$DEVELOPER_DIR/metal.err" ] || cat "$DEVELOPER_DIR/metal.err" >&2; [ ! -f "$DEVELOPER_DIR/metal.rc" ] || exit "$(cat "$DEVELOPER_DIR/metal.rc")";; *) exit 1;; esac
EOF
printf '#!/bin/bash\ncat %s/sel\n' $T > $T/bin/xcode-select; chmod +x $T/bin/*
# 假 Xcode 安装目录：XA（版本 91.0，Developer = A 的内容）、XB（90.0，= B）；② 里没指定时应挑版本高的 XA
mkxc() { mkdir -p $T/apps/$1.app/Contents/Developer/usr/bin; cp $T/$2/* $T/apps/$1.app/Contents/Developer/; : > $T/apps/$1.app/Contents/Developer/usr/bin/xcodebuild
  printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.apple.dt.Xcode</string><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>' $3 > $T/apps/$1.app/Contents/Info.plist; }
mkxc XcodeA A 91.0; mkxc XcodeB B 90.0; XA=$T/apps/XcodeA.app/Contents/Developer; XB=$T/apps/XcodeB.app/Contents/Developer
export PATH=$T/bin:$PATH S2A_MACHINE_NO_LOCAL=1 S2A_TC_QUIET=1 S2A_XCODE_SEARCH=$T/apps; unset DEVELOPER_DIR S2A_DEVELOPER_DIR S2A_TC_RESOLVED S2A_TC_METAL S2A_TC_SDK S2A_TC_SDK_NAME S2A_PSO_OS S2A_MACOS14 S2A_PACK_PLAT
Q() { bash -c "source $H/tools/toolchain.sh || exit 7; echo \"\$DEVELOPER_DIR|\$S2A_TC_METAL|\$S2A_TC_SDK|\$S2A_PSO_OS\"" 2>&1; }
R() { S2A_DEVELOPER_DIR=$1 bash -c "source $H/tools/toolchain.sh || exit 7; echo \"\$S2A_TC_RESOLVED|\$S2A_TC_METAL\"" 2>&1; }
echo $T/B > $T/sel
o1=$(S2A_DEVELOPER_DIR=$T/A Q); o2=$(echo $XB > $T/sel; Q); echo $T/B > $T/sel; o2b=$(S2A_XCODE_SEARCH=$T/none Q)
ck "① 启动器传 A、xcode-select 指 B → 用 A（${o1##*/}）" '[ "$o1" = "$T/A|Apple metal version 32023.921|27.0|27" ]'
ck "② 没传、装着 XcodeA 91.0 与 XcodeB 90.0、xcode-select 指 B → 用最新的 A（${o2##*/}）" '[ "$o2" = "$XA|Apple metal version 32023.921|27.0|27" ]'
ck "② 没传、找不到装着的 Xcode → 退到 xcode-select 的 B（${o2b##*/}）" '[ "$o2b" = "$T/B|Apple metal version 32023.883|26.5|26" ]'
o3=$(S2A_DEVELOPER_DIR=$T/A bash -c "source $H/tools/toolchain.sh; echo $T/B > $T/sel; unset S2A_DEVELOPER_DIR; bash -c 'source $H/tools/toolchain.sh; echo \"\$DEVELOPER_DIR|\$S2A_TC_METAL\"'" 2>&1)
ck "③ 上游用 A 解析过、子进程再 source（xcode-select 已改指 B）→ 照旧 A、不串版本（${o3##*/}）" '[ "$o3" = "$T/A|Apple metal version 32023.921" ]'
o4=$(S2A_DEVELOPER_DIR=$T/A S2A_PSO_OS=26 Q)
ck "④ 启动器给了目标 iOS 26 → 用 26；没给按 SDK 推（①里是 27）（${o4##*|}）" '[ "${o4##*|}" = 26 ] && [ "${o1##*|}" = 27 ]'
o5=$(S2A_DEVELOPER_DIR=$T/C Q); r5=$?; o6=$(S2A_DEVELOPER_DIR=$T/D Q); r6=$?
ck "⑤ 没有 Metal 编译器 → 退出非 0、说缺 Metal（rc=${r5}）；SDK 17.0 → 退出非 0、说低于下限（rc=${r6}）；不提「27.1」" '[ $r5 != 0 ] && [[ "$o5" == *"没有 Metal 编译器"* ]] && [ $r6 != 0 ] && [[ "$o6" == *"低于产物下限"* ]] && [[ "$o5$o6" != *27.1* ]]'
o7=$(R $T/E); r7=$?; o8=$(R $T/F); r8=$?; o9=$(R $T/G); r9=$?; o10=$(R $T/H); r10=$?
ck "⑥ 合法版本行 / 退出 0 → 成功（rc=${r7}）" '[ $r7 = 0 ] && [ "$o7" = "1|Apple metal version 32023.921" ]'
ck "⑦ 退出 0 但 stdout 是 error 文本 → 拒绝、不说成功（rc=${r8}）" '[ $r8 != 0 ] && [[ "$o8" == *"没有 Metal 编译器"* ]] && [[ "$o8" != *"1|"* ]]'
ck "⑧ 合法版本 stdout + error 文本 stderr + 退出 1 → 拒绝（rc=${r9}）" '[ $r9 != 0 ] && [[ "$o9" == *"没有 Metal 编译器"* ]] && [[ "$o9" != *"1|"* ]]'
ck "⑨ 空 stdout + error 文本 stderr + 退出 1 → 拒绝（rc=${r10}）" '[ $r10 != 0 ] && [[ "$o10" == *"没有 Metal 编译器"* ]] && [[ "$o10" != *"1|"* ]]'
# ⑩ 没指定、xcode-select 也指不到（10-25 维护者：全仓不写死 Xcode 路径 / 版本）→ 不退到仓库里写的版本：退出非 0、说「目录不在」、不提 27.1
: > $T/sel; o11=$(S2A_XCODE_SEARCH=$T/none Q); r11=$?
ck "⑩ 没指定、找不到装着的 Xcode、xcode-select 空 → rc=${r11}、不退到仓库写的版本（${o11:0:60}…）" '[ $r11 != 0 ] && [[ "$o11" == *目录不在* ]] && [[ "$o11" != *27.1* ]]'
# Apple Silicon 本机兼容档：只有 macosx SDK 的夹具，不能借用先前解析的 iOS 工具链。
mkdir -p "$T/Mac"
printf '%s\n' 15.2 > "$T/Mac/sdk"
printf '%s\n' 'Apple metal version 32023.404' > "$T/Mac/metal"
touch "$T/Mac/mac-only"
cat > "$T/bin/uname" <<'EOF'
#!/bin/bash
if [ "$1" = -sm ]; then printf '%s\n' "$S2A_TEST_UNAME"; else /usr/bin/uname "$@"; fi
EOF
chmod +x "$T/bin/uname"
MAC() {
  S2A_MACOS14=1 S2A_PACK_PLAT="$1" S2A_DEVELOPER_DIR="$T/Mac" S2A_TEST_UNAME="$2" \
  S2A_TC_RESOLVED=1 DEVELOPER_DIR="$T/A" S2A_TC_METAL='Apple metal version 999' S2A_TC_SDK_NAME=iphoneos S2A_PSO_OS=27 \
  bash -c '. "$1/tools/toolchain.sh" || exit 7; printf "%s|%s|%s|%s|%s\n" "$S2A_TC_SDK_NAME" "$S2A_TC_SDK" "$MACOSX_DEPLOYMENT_TARGET" "$S2A_MACOS14_METAL_STD" "$S2A_PSO_OS"' _ "$H" 2>&1
}
o12=$(MAC macos 'Darwin arm64')
ck "⑪ macOS 14 档只取 macosx SDK、最低 14.0、MSL 3.1（${o12}）" '[ "$o12" = "macosx|15.2|14.0|metal3.1|14" ]'
o13=$(MAC ios 'Darwin arm64'); r13=$?
o14=$(MAC macos 'Darwin x86_64'); r14=$?
ck "⑫ 兼容档拒绝 iOS 与 Intel（rc=$r13/${r14}）" '[ $r13 = 7 ] && [ $r14 = 7 ] && [[ "$o13$o14" == *"仅支持 Apple Silicon"* ]]'
[ $bad = 0 ] && echo "toolchain_resolve 单测全过" || { echo "toolchain_resolve 单测有不通"; exit 1; }
