# macOS 14 本机启动器与运行实验版

此分支 `codex/macos14-launcher-v0.1.7` 基于上游正式版 `v0.1.7`（`944ad83e958bc0106c3de4d25a4898558bf39618`）。目标是 Apple Silicon Mac 上的本机游戏准备和运行，包含原有 SwiftUI 游戏库、设置、全局与单游戏输入映射编辑器、原生游戏窗口和独立存档目录。这个构建入口不构建 Android APK 或 iOS IPA。

这是兼容性实验分支。上游公开仓库与原 beta 8 没有共同 Git 历史，因此在正式版上重新移入兼容补丁；已验证的 beta 8 分支 `codex/macos14-local-runtime`（`b350d668c`）保持原样。最低系统版本只对显式本机配置生效，普通发行构建仍使用上游默认配置。下文分开记录两个基线的验证范围。

## 工具准备

- macOS 14 或更新系统，Apple Silicon，原生 arm64 Python 3.11+（推荐 3.12）。
- .NET 10 arm64 SDK，Bash 5+、Apple clang、make、CMake、Meson、Ninja、Perl、Git、curl、zstd。macOS 自带的 Bash 3.2 不足以执行准备脚本；可用 Homebrew 安装 Bash，或用 `S2A_BASH` 指定独立安装的位置。
- 能在本机运行的 Xcode 及 Metal 编译器，支持 Metal 3.1。开发时使用 Xcode 16.2。
- 准备 OpenGL 游戏的离线库还需要 `glslangValidator`（Homebrew 的 `glslang`）。固定版 SPIRV-Cross 由本机档从仓库源码按需构建。
- 编译 Metal 后端的 Objective-C 代码需要含 Metal 4 声明的 macOS SDK，因为同一源码仍包含较新系统的渲染后端。旧 Xcode 的 SDK 不够时，使用 `S2A_MACOS_SDKROOT` 指定单独准备的较新 SDK；不用切换系统全局的 `xcode-select`。开发时验证了 Apple clang 16 + macOS 26.5 SDK、部署目标 14.0 的组合。DSX / SPIRV-Cross 的 C++ 代码仍使用所选 Xcode 配套的 SDK，避免新版 libc++ 依赖旧 clang 不支持的内建函数。
- 源码工作树需放在绝对路径不含空白字符的目录，Make 会按空白拆分部分链接参数。游戏库、游戏原件和私有运行状态目录支持带空格的路径。

在本工作树根目录设置本机路径并安装固定依赖：

```sh
export S2A_DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer"
export S2A_MACOS_SDKROOT="/path/to/MacOSX26.sdk"
export DOTNET="/path/to/dotnet/dotnet"
export DOTNET_ROOT="${DOTNET%/*}"
export S2A_BASH="/path/to/bash5/bin/bash"
python3.12 -m venv build/macos14-venv
export S2A_PYTHON="$PWD/build/macos14-venv/bin/python3"
export PATH="${S2A_PYTHON%/*}:$DOTNET_ROOT:$PATH"
"$S2A_PYTHON" -m pip install -r launchers/macos/requirements-runtime.txt -r pack/fonts/requirements.txt
"$S2A_PYTHON" runtime/rewriter/prepare_deps.py build/rewriter-deps
export S2A_RUN_ROOT="$PWD/.s2arm-local/run"
```

`prepare_deps.py` 是显式联网准备步骤，校验固定源码的 SHA-256；依赖目录已完整时不要重复解压。可用 `S2A_REWRITER_DEPS` 指向其他已准备目录。没有共享 `.bfttf` 字体时，游戏准备会使用仓库的开源字体生成流程，首次需下载固定字体来源。

已有自己的共享字体时，给 `doctor --for prepare` 和 `prepare` 同时加上 `--fonts "/path/to/fonts"`，即可使用该目录的 `.bfttf`，跳过开源字体生成。

## 图形启动器

设置好上述本机工具路径后，在工作树根目录构建：

```sh
"$S2A_PYTHON" launchers/macos/build_app.py --macos14-local
# 已准备好共享字体时可加 --fonts "/path/to/fonts"
open "build/macos14-launcher/S2Arm macOS 14.app"
```

这是依赖本机源码工作树和工具的开发应用，不是可拷给其他电脑的便携发行包。应用只构建 `S2ArmLauncher`，最低系统版本为 14.0，使用 macOS 14 可用的材质和按钮；不构建正式版的便携引擎、iOS 壳或移动安装工具。它不会通过正式版更新入口替换自己。

应用会把明确选择的 Python、Bash、.NET、Xcode 和 SDK 路径写入签封的 `LocalProfile.json`。从 Finder 打开不需要先在终端导出环境变量；这些工具或工作树移动后需重新构建应用。使用磁盘镜像中的 Xcode 时，准备游戏前应挂载该镜像。

首次打开，在环境检查中准备缺少的内容读取工具，再导入自己的密钥和游戏。首次访问外置磁盘时，macOS 可能弹出访问许可，需要在系统弹窗中允许。游戏库默认位于 `~/Library/Application Support/S2Arm macOS 14/游戏库`，仅登记原件位置，不改写原始游戏文件。库需要放在源码树外的本地 APFS 卷；本机库带专用标记，不能与普通发行库混用。

「设置 → 游戏库与玩家数据 → 选择或切换游戏库…」可选择新的空目录或已有同配置游戏库。准备好的运行版本在库内 `games/<程序号>/current`，存档在 `saves/<程序号>`，准备缓存和运行缓存也跟随游戏库。密钥、启动器偏好和任务日志仍在启动器私有数据目录；开发工具链和显式配置的源码构建缓存仍在本机工具路径。

外置盘若是 exFAT，可以在盘上建立 APFS 稀疏磁盘镜像，挂载后把镜像内的目录作为游戏库。镜像按实际写入增长，设置容量是上限；源游戏文件可以继续留在 exFAT 盘。每次使用前先挂载镜像，退出游戏和启动器后再推出它。

切换游戏库不会自动复制旧库。迁移时应先停下任务和启动器，创建独立的新库标记，复制游戏、存档、`catalog.json`、已有单款映射及存档备份，核对运行清单与存档哈希后再切换；保留旧库可供回退。复制后两份库独立，后续存档不会自动同步。

在「设置」编辑全局键鼠和手柄映射，也可以在游戏详情编辑单款映射。编辑器保留按键录入、死区、摇杆方向与实时输入测试；保存后由下次启动使用。启动时冻结本局映射，优先使用单款配置，其次使用全局配置；无需重新准备游戏。实体手柄的连接和游戏内反馈仍需设备实测。

## 命令行构建与准备游戏

```sh
"$S2A_PYTHON" tools/macos14.py doctor --for build
"$S2A_PYTHON" tools/macos14.py build
"$S2A_PYTHON" tools/macos14.py doctor --for prepare
"$S2A_PYTHON" tools/macos14.py prepare "/path/to/game-source" \
  --keys "/path/to/prod.keys" \
  --out "/path/to/private-macos14-output"
```

构建产物位于 `build/macos14/`。`S2Arm Local.app` 是带本机 ad-hoc 签名的精简游戏窗口，包含服务层宿主和地址窗口护栏库；游戏与状态目录由下述命令传入。裸 `s2arm-host` 也保留，供准备阶段调用。准备入口调用上游的完整 Mac 直连流水线，只发布 Mac 着色器库；若游戏需要自己的解码器或 GLSLC 辅助执行，使用同一份 macOS 14 宿主。图形任务与命令行共用宿主构建锁。

游戏源目录可同时含本体、更新和 DLC。输出目录必须位于本源码工作树之外，并与输入分开，建议放在 APFS 卷上，以便版本化产物使用写时复制。配置生成器保护源码目录，不接受把准备产物放进源码树内，即使该目录已被 Git 忽略。密钥只以路径交给读取器。成功后命令输出“准备产物根”，运行时使用这个版本目录，而不是游戏源目录或输出目录的最外层。

## 运行

```sh
"$S2A_PYTHON" tools/macos14.py doctor --for run --prepared "/path/to/prepared-root"
"$S2A_PYTHON" tools/macos14.py run \
  --prepared "/path/to/prepared-root" \
  --state "/path/to/private-game-state"
```

`--state` 保存本机存档、配置、着色器缓存和每次运行的 `host-*.log`，应长期保留，并与准备产物分开。再次使用同一目录会继续使用其中的存档。入口清除测试用存档种子覆盖；不从其他游戏运行目录导入或重置存档。启动前会校验必需的直连产物和 NVN 链号。

游戏窗口启动时会请求前台焦点。游戏要求失焦暂停时，切换到其他应用会暂停游戏，切回即可继续。菜单「查看键位 / Controls」（⌘K）可查看键鼠映射；默认 `ZL` 是鼠标右键，`ZR` 是键盘 `R`，可同时按下。系统手柄沿用原有输入路径。

诊断时可加 `--seconds 30`，从客体线程启动后计时收局；有实际帧提交时会写同名 `.frames.tsv`。通常直接关闭游戏窗口退出。`doctor --for run` 只检查运行依赖，不要求安装编译工具。

若 `doctor` 报默认 Metal 设备不可用，当前进程无法进入 GPU 验收；需在可访问 GPU 的本机终端 / 桌面会话中再运行。这种环境下不能把“宿主能启动”或 CPU 测试通过作为出帧证明。

## 兼容层边界

macOS 14 使用 Metal 3 编码器逐次声明间接资源，并将引用保留到实际 command buffer 完成。已发布的全局纹理句柄表在变更时复制，避免在途绘制读到未经声明的新句柄。macOS 15 及之后仍使用原有驻留集路径。macOS 14 的离线着色器目标为 Metal 3.1 / macOS 14，缓存与默认构建区分；运行时编译也使用系统支持的选项。

本分支没有给出全部游戏兼容、帧率或稳定性保证。完整验收至少需要：成功准备一款真实游戏、启动并持续出帧、验证键鼠 / 手柄输入、正常退出、用同一 `--state` 重开并检查存档。

## beta 8 已验证基线（2026-11-09）

- 设备：Apple M1 Pro、16 GB 内存、macOS 14.8.5；游戏：《ASTRAL CHAIN / 异界锁链》1.0.1。
- 完整 Mac 准备成功：1,348 / 1,348 个着色器键完成校验，容器包含 2,853 条记录。未生成 Android APK 或 iOS IPA。
- 最终宿主及护栏库的 Mach-O 最低系统版本均为 14.0；精简应用通过 `codesign --verify --deep --strict`，运行体检的 GPU、宿主和准备产物三项通过。
- 最终前台测试一局 45 秒，记录 2,590 帧；内置测试输入通道在开始页发送 `ZL + ZR`，画面进入开场剧情；游戏用户存档提交 2 次，退出码 0，日志无红色错误。截图只保留在本机私有运行目录。
- 同一私有状态目录多次重开成功。此前切到其他应用的测试按游戏要求暂停，不能用暂停期间的停帧读数判定渲染失败。
- 射程：1 款游戏、1 种设备，证明准备及开场运行闭环。未完成实体手柄、完整键鼠操作、剧情进度存档读回、长时间游玩或其他游戏验证；这轮读数不能作为整款游戏性能与兼容性承诺。

## v0.1.7 启动器验证（2026-11-09）

- 同一台 M1 Pro / macOS 14.8.5 上，Xcode 16.2 构建的完整启动器为 arm64、最低系统 14.0、链接 SDK 15.2，ad-hoc 签名验证通过。游戏宿主同样为最低系统 14.0。
- 应用实际启动，首次引导、设置页、独立数据目录和本机环境检查正常；真实 .NET 作业构建读取器成功。用户完成首次 T7 系统授权后，图形启动器导入密钥及《ASTRAL CHAIN》本体、1.0.1 更新成功，密钥经实际解密验证。目录扫描已修复误认 AppleDouble `._*.nsp` 侧车的问题，13 项导入测试及旧实现负对照通过。
- 图形任务完整准备成功：解包 8,701 个资源文件、约 9.8 GB；Mac 着色器库核验 1,348 / 1,348 个键、2,853 段，0 个缺失，未生成移动包。修复资源排队路径分词后，重试复用了已经完成的解包与分析，113 秒完成准备及发布；运行清单标记 `macos14-local`，发布的游戏应用最低系统 14.0、签封校验通过。
- 经启动器控制口启动上述新产物，60 秒局记录 3,521 帧；在第 629 帧通过内置测试输入通道发送 `ZL + ZR`，截图确认从开始页进入开场剧情。日志记录游戏用户存档提交 3 次，正常定时退出，图形任务状态 `completed`。临时诊断配置在结束后移除，存档和截图留在独立私有目录。此项不等于实体手柄、完整键鼠操作、剧情进度存档读回或长时间游玩已验证。
- 使用 beta 8 已准备的同链号游戏数据，对新版宿主做了两次 45 秒短局：Metal 3 初始化、首帧提交和定时退出正常，但两局都在失焦后按游戏要求暂停。第二局退出码 0；未取得持续帧表或发送到开始页的输入，因此不作为新版持续运行、输入或存档验收证据。没有修改失焦暂停机制。
- Swift 定向测试 19 项通过，包含双语输入编辑器离屏渲染、映射快照及真实 Python 作业；另有本机 AI 提示词测试 2 项通过。本地化和前端布局测试 20 项通过。本机应用包含明确的工具路径与 Mac 操作提示。
- Metal 3 CPU 资源与交接回归、gfxmode 19 项、着色器工具链 22 项、直连阶段 41 项、弱链接 14 项及 Metal 4 棘轮 3 项通过。CPU 回归不等同于实际 GPU / 游戏验收。

在配置好上述工具路径后，可独立运行不需要 GPU 的资源生命周期回归：

```sh
make -C graphics/nvn S2A_MACOS14=1 test-m3-residency
"$S2A_PYTHON" tests/macos14_cli_test.py
```

请用此分支的 `prepare` 重新准备游戏。NVN 链号一致只能证明翻译链身份一致，不能证明其他构建生成的 Metal 库支持 macOS 14。
