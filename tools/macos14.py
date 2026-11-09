#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Apple Silicon macOS 14 local runtime (build, prepare, launch)."""
import argparse
from contextlib import ExitStack, contextmanager
import ctypes
import fcntl
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

from mac_chain_check import check as check_chain
from macos14_bundle import BUNDLE_NAME, GUARD_NAME, HOST_NAME, create_bundle

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/macos14"
LOCK_NAME = ".s2arm-macos14.lock"
REQUIRED_FILES = (
    "main.npdm", "main.patched.bin", "main.fixups.tsv", "main.gates.tsv",
    "addr_need.tsv", "romfs.s2aidx", "ctl/control.nacp", "unpack.tsv",
    ".stage_direct", "shaders/direct/keys.tsv",
)


def platform_error():
    version = platform.mac_ver()[0]
    if sys.platform != "darwin" or platform.machine() != "arm64" or int((version or "0").split(".")[0]) < 14:
        return "需要 macOS 14 或更新版本，以及原生 arm64 Python（Apple 芯片）。"
    return ""


def environment():
    env = os.environ.copy()
    env.update(S2A_MACOS14="1", S2A_PACK_PLAT="macos")
    # Persistent build servers inherit the output lock descriptor from the build.
    env.update(UseSharedCompilation="false", MSBUILDDISABLENODEREUSE="1", DOTNET_CLI_USE_MSBUILD_SERVER="0")
    if env.get("S2A_DEVELOPER_DIR") or env.get("DEVELOPER_DIR"):
        env["S2A_DEVELOPER_DIR"] = env.get("S2A_DEVELOPER_DIR") or env["DEVELOPER_DIR"]
        env["DEVELOPER_DIR"] = env["S2A_DEVELOPER_DIR"]
    for name in ("S2A_TC_RESOLVED", "S2A_TC_SDK", "S2A_TC_METAL",
                 "S2A_PREBUILT_TOOLS", "S2A_NX_UNPACK", "S2A_SHELL", "DSX_LIB"):
        env.pop(name, None)
    python = env.get("S2A_PYTHON") or env.get("S2A_PY") or sys.executable
    python = shutil.which(python) or python
    env.update(S2A_PYTHON=python, S2A_PY=python)
    env["PATH"] = os.pathsep.join((str(Path(python).parent), str(ROOT / "tools/bin"), os.environ.get("PATH", "")))
    dotnet = env.get("DOTNET") or shutil.which("dotnet", path=env["PATH"])
    if not dotnet:
        local = Path.home() / ".dotnet/dotnet"
        if os.access(local, os.X_OK):
            dotnet = str(local)
    if dotnet:
        env["DOTNET"] = shutil.which(dotnet, path=env["PATH"]) or dotnet
    return env


def probe(command, env):
    try:
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors="replace", timeout=20)
        return result.returncode == 0, result.stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        return False, str(error)


def bash_status(env):
    requested = env.get("S2A_BASH") or "bash"
    bash = shutil.which(os.path.expanduser(requested), path=env["PATH"])
    hint = "将新版 bash 放在 PATH 首位，或用 S2A_BASH 指定其路径"
    if not bash:
        return None, f"Bash 5+（找不到 {requested}，{hint}）"
    bash = os.path.abspath(bash)
    ok, version = probe([bash, "-p", "-c", 'printf "%s" "$BASH_VERSION"'], env)
    major = version.partition(".")[0]
    if not ok or not major.isdecimal() or int(major) < 5:
        found = f"{bash} {version}" if ok and major.isdecimal() else bash
        return None, f"Bash 5+（当前：{found}，{hint}）"
    return bash, f"Bash {version}（{bash}）"


def prepared_info(prepared):
    missing = [name for name in REQUIRED_FILES if not (prepared / name).is_file()]
    if not (prepared / "romfs").is_dir():
        missing.append("romfs/")
    if missing:
        raise ValueError("直连准备产物缺失：" + ", ".join(missing))
    lines = (prepared / "unpack.tsv").read_text(encoding="utf-8").splitlines()
    fields = dict(line.split("\t", 1) for line in lines if "\t" in line)
    title_id = fields.get("title_id", "").upper()
    if not re.fullmatch(r"[0-9A-F]{16}", title_id):
        raise ValueError("准备产物 unpack.tsv 缺有效的 title_id。")
    return title_id, fields.get("name") or title_id


def host_path():
    bundle = BUILD / BUNDLE_NAME
    host = bundle / "Contents/MacOS" / HOST_NAME
    if not (bundle / "Contents/Info.plist").is_file() or not host.is_file() or not os.access(host, os.X_OK):
        raise ValueError(f"找不到可执行的 {BUNDLE_NAME} 宿主，请先运行 build。")
    if not (host.parent / GUARD_NAME).is_file():
        raise ValueError(f"{BUNDLE_NAME} 缺地址窗口护栏库，请重新运行 build。")
    return host


def metal_device_available():
    try:
        # A command-line process needs CoreGraphics to obtain the default Metal device.
        ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        metal = ctypes.CDLL("/System/Library/Frameworks/Metal.framework/Metal")
        default_device = metal.MTLCreateSystemDefaultDevice
        default_device.restype = ctypes.c_void_p
        return bool(default_device())
    except (OSError, AttributeError):
        return False


def doctor(args, env, bash_check=None, report_check=None):
    scope = args.scope or "all"
    ready = True

    def report(phase, ok, message):
        nonlocal ready
        ready = ready and ok
        if report_check is None:
            print(f"[{phase}] {'OK' if ok else '缺少'} {message}")
        else:
            report_check(phase, bool(ok), message)

    if scope in ("all", "build", "prepare"):
        phase = "build/prepare" if scope == "all" else scope
        bash_ready, bash_message = bash_check
        report(phase, bash_ready, bash_message)
        ok, sdks = probe([env.get("DOTNET", "dotnet"), "--list-sdks"], env)
        installed = [line.split()[0] for line in sdks.splitlines() if re.match(r"^10\.\d+\.\d+", line)] if ok else []
        report(phase, bool(installed), ".NET 10 SDK " + (", ".join(installed) or "（请安装官方 arm64 SDK，或指定 DOTNET）"))
        ok, _ = probe(["python3", "-c", "import sys; assert sys.version_info >= (3, 11)"], env)
        report(phase, ok, "PATH 上的 Python 3.11+（建议将 Python 3.12 虚拟环境的 bin 放在 PATH 首位）")

    if scope in ("all", "build"):
        ok, _ = probe(["xcrun", "--sdk", "macosx", "clang", "--version"], env)
        report("build", ok, "Apple clang")
        for name in ("make", "cmake", "meson", "ninja", "perl", "curl"):
            report("build", bool(shutil.which(name, path=env["PATH"])), name)
        ok, sdk = probe(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env)
        sdk = env.get("S2A_MACOS_SDKROOT") or (sdk if ok else "")
        metal_headers = "System/Library/Frameworks/Metal.framework/Headers/MTL4CommandQueue.h"
        report("build", bool(sdk and (Path(sdk) / metal_headers).is_file()),
               f"含 Metal 4 头的 macOS SDK（S2A_MACOS_SDKROOT，当前：{sdk or '未找到'}）")

    if scope in ("all", "prepare"):
        if bash_ready:
            ok, message = probe([env["S2A_BASH"], "-c", 'source "$1"', "macos14", ROOT / "tools/toolchain.sh"], env)
            report("prepare", ok, "离线工具链 " + (message or "macOS SDK / Metal"))
        ok, _ = probe([env["S2A_PYTHON"], "-c", "import capstone, lz4, numpy, PIL, zstandard"], env)
        report("prepare", ok, "Python 包（launchers/macos/requirements-runtime.txt）")
        fonts = args.fonts or env.get("S2A_FONTS")
        if fonts:
            report("prepare", any(Path(fonts).expanduser().glob("*.bfttf")), "共享 .bfttf 字体")
        else:
            ok, _ = probe([env["S2A_PYTHON"], "-c", "import fontTools, pathops"], env)
            report("prepare", ok, "开源字体生成器（pack/fonts/requirements.txt 或提供 --fonts）")
        ok, _ = probe([env["S2A_PYTHON"], "-c", "import sys; sys.path.insert(0, 'pack'); import rewriter; "
                       "rewriter.override() or rewriter.bundled() or rewriter.dependency_dir()"], env)
        report("prepare", ok, "C 改写器（runtime/rewriter/prepare_deps.py 或 S2A_REWRITER_C）")
        for name in ("git", "cmake", "perl", "zstd"):
            report("prepare", bool(shutil.which(name, path=env["PATH"])), name)

    if scope in ("all", "run"):
        report("run", metal_device_available(), "当前进程可用的默认 Metal 设备")
        try:
            host_path()
            report("run", True, f"{BUNDLE_NAME} 宿主及护栏库")
        except ValueError as error:
            report("run", False, str(error))
        try:
            if not args.prepared:
                raise ValueError("请用 --prepared 指定 prepare 的产物根。")
            prepared = args.prepared.expanduser().resolve()
            prepared_info(prepared)
            report("run", check_chain(prepared) == 0, "准备产物与 NVN 链号")
        except (OSError, ValueError) as error:
            report("run", False, str(error))

    return 0 if ready else 1


def overlaps(left, right):
    return left.is_relative_to(right) or right.is_relative_to(left)


@contextmanager
def directory_lock(directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(directory / LOCK_NAME, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError(f"另一个本机任务正在使用目录：{directory}") from None
        yield fd
    finally:
        os.close(fd)


def host_build_command():
    return ["make", "host", "S2A_MACOS14=1", "S2A_CS=1", "S2A_MAC_FRONTEND=1", "BUILD=build/macos14"]


def build_host_bundle():
    return create_bundle(BUILD / HOST_NAME, BUILD / GUARD_NAME, BUILD / BUNDLE_NAME)


def build(env):
    with directory_lock(BUILD) as lock:
        result = subprocess.run(host_build_command(), cwd=ROOT, env=env, pass_fds=(lock,))
        if result.returncode != 0:
            return result.returncode
        print(build_host_bundle())
    return 0


def prepare(args, env):
    out = args.out.expanduser().resolve()
    if overlaps(out, ROOT):
        raise ValueError("--out 必须指定源码工作树外的私有目录，且不能包含工作树。")
    source = args.source.expanduser().resolve(strict=True)
    keys = args.keys.expanduser().resolve()
    if not source.is_dir() or not keys.is_file() or not os.access(keys, os.R_OK):
        raise ValueError("需要游戏源目录及可读的 --keys 文件。")
    inputs = [source, keys]
    command = [env["S2A_BASH"], ROOT / "pack/oneclick/oneclick.sh", source,
               "--target", "mac", "--keys", keys, "--out", out]
    for name in ("fonts", "sysdata"):
        value = getattr(args, name) or env.get("S2A_" + name.upper())
        if value:
            value = Path(value).expanduser().resolve(strict=True)
            if not value.is_dir():
                raise ValueError(f"--{name} 需要一个目录。")
            inputs.append(value)
            command.extend(("--" + name, value))
    if args.title_id:
        command.extend(("--title-id", args.title_id))
    if any(overlaps(out, item) for item in inputs):
        raise ValueError("--out 必须与游戏、密钥、字体和系统数据输入分开。")
    env["S2A_DIRECT_TARGETS"] = "mac"
    # Direct preparation can compile DSX and read the host from this build root.
    with directory_lock(BUILD) as build_lock, directory_lock(out) as lock:
        for name in ("roots", "extract", "extract.tmp", "logs", ".seeded", "save-identity.json"):
            if (out / name).is_symlink():
                raise ValueError(f"--out 下的 {name} 不得指向其他目录。")
        with tempfile.NamedTemporaryFile(dir=out, prefix=".oneclick-", suffix=".ndjson") as events:
            result = subprocess.run([*command, "--events", events.name], cwd=ROOT, env=env,
                                    pass_fds=(build_lock, lock))
            if result.returncode != 0:
                return result.returncode
            results = [event for line in events if (event := json.loads(line)).get("ev") == "result"]
        if len(results) != 1 or results[0].get("ok") is not True or not results[0].get("root"):
            raise ValueError("Mac 准备流程没有发布成功的产物根。")
        prepared = Path(results[0]["root"]).resolve(strict=True)
        if not prepared.is_relative_to(out / "roots"):
            raise ValueError("Mac 准备流程返回了私有输出目录以外的产物根。")
        prepared_info(prepared)
        print(f"准备产物根：{prepared}")
    return 0


def run(args, env):
    prepared = args.prepared.expanduser().resolve(strict=True)
    state = args.state.expanduser().resolve()
    if overlaps(prepared, state):
        raise ValueError("--state 必须与准备产物根分开。")
    with ExitStack() as locks:
        # oneclick can prune old prepared roots while refreshing the same output.
        output = prepared.parent.parent
        descriptors = []
        if prepared.parent.name == "roots" and (output / LOCK_NAME).is_file():
            descriptors.append(locks.enter_context(directory_lock(output)))
        host = host_path()
        title_id, name = prepared_info(prepared)
        if check_chain(prepared) != 0:
            return 1
        descriptors.append(locks.enter_context(directory_lock(state)))
        for key, subdir in (("S2A_DOCS", "docs"), ("S2A_RYU_DATA", "ryu"),
                            ("NXGAL_SHADER_CACHE_DIR", "shaders"), ("NXGAL_PSO_DEV_DIR", "pso"),
                            ("S2A_MACRO_DUMP", "macros")):
            path = state / subdir
            if path.is_symlink():
                raise ValueError(f"运行状态子目录不得是符号链接：{path}")
            path.mkdir(mode=0o700, exist_ok=True)
            env[key] = str(path)
        # Empty overrides any inherited seed, including one in the private env.txt.
        env.update(S2A_GAME_DATA=str(prepared), S2A_GAME_ID=title_id, S2A_GAME_NAME=name,
                   S2A_SAVE_DIR="", S2A_AUTOPLAY="0", S2A_IPHONE_VA="0",
                   S2A_INPUT_GUIDE_SHOWN="1", S2A_RUN_S=str(args.seconds or 0), S2A_FRAMES_TSV="")
        with tempfile.NamedTemporaryFile(mode="wb", dir=state, prefix="host-", suffix=".log", delete=False) as log:
            if args.seconds:
                env["S2A_FRAMES_TSV"] = str(Path(log.name).with_suffix(".frames.tsv"))
            print(f"宿主日志：{log.name}", flush=True)
            os.chdir(state)
            os.dup2(log.fileno(), 1)
            os.dup2(log.fileno(), 2)
            # Hold both directories until the host exits, with the same terminal process.
            for descriptor in descriptors:
                os.set_inheritable(descriptor, True)
            os.execve(host, [str(host), str(prepared)], env)


def parser():
    ap = argparse.ArgumentParser(description=__doc__)
    commands = ap.add_subparsers(dest="command", required=True)
    check = commands.add_parser("doctor", help="检查构建、准备与运行环境")
    check.add_argument("--for", dest="scope", choices=("build", "prepare", "run"))
    check.add_argument("--prepared", type=Path)
    check.add_argument("--fonts", type=Path)
    commands.add_parser("build", help="编译 macOS 14 arm64 宿主")
    prep = commands.add_parser("prepare", help="用本地游戏源包生成 Mac 直连产物")
    prep.add_argument("source", type=Path)
    prep.add_argument("--keys", required=True, type=Path)
    prep.add_argument("--out", required=True, type=Path, help="源码工作树外的私有输出目录")
    prep.add_argument("--fonts", type=Path)
    prep.add_argument("--sysdata", type=Path)
    prep.add_argument("--title-id")
    play = commands.add_parser("run", help="在私有运行目录启动已准备的游戏")
    play.add_argument("--prepared", required=True, type=Path)
    play.add_argument("--state", required=True, type=Path)
    play.add_argument("--seconds", type=int, help="诊断用，指定宿主收局秒数")
    return ap


def main(argv=None):
    ap = parser()
    args = ap.parse_args(argv)
    if args.command == "run" and args.seconds is not None and not 1 <= args.seconds < 2**32:
        ap.error("--seconds 必须在 1 到 4294967295 之间。")
    if error := platform_error():
        print(error, file=sys.stderr)
        return 2
    try:
        if args.command == "run":
            return run(args, dict(os.environ, S2A_MACOS14="1"))
        env = environment()
        if args.command == "doctor" and args.scope == "run":
            return doctor(args, env)
        bash, message = bash_status(env)
        if args.command != "doctor" and not bash:
            raise ValueError(message)
        with ExitStack() as stack:
            if bash:
                bash_dir = os.path.dirname(bash)
                if os.path.basename(bash) != "bash":
                    bash_dir = stack.enter_context(tempfile.TemporaryDirectory(prefix="s2arm-bash-"))
                    Path(bash_dir, "bash").symlink_to(bash)
                env.update(S2A_BASH=bash, PATH=bash_dir + os.pathsep + env["PATH"])
            if args.command == "doctor":
                return doctor(args, env, (bool(bash), message))
            if args.command == "build":
                return build(env)
            return prepare(args, env)
    except (OSError, ValueError) as error:
        print(f"【红】{error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
