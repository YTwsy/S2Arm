# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Explicit toolchain and operation scope for the macOS 14 local launcher."""

import os
from pathlib import Path

from errors import Failure

PROFILE = "macos14-local"
LIBRARY_PROFILE_MISMATCH = "游戏库归属与当前启动器不同，请选择独立的游戏库。"
OPERATIONS = frozenset({
    "preflight", "prepareEngine", "setup", "keys", "import", "catalog", "remove",
    "delete", "clean", "spaceSurvey", "spaceFree", "diagnostics", "saveInput",
    "build", "launch", "customize", "saveStatus", "saveBackup", "saveInspect", "saveRestore",
    "community", "communitySave",
})
REQUIRED = frozenset({"python", "bash", "dotnet", "sdkRoot", "path"})
CACHE_FIELDS = {
    "nugetPackages": "NUGET_PACKAGES",
    "sourceCache": "S2A_BUILD_CACHE",
    "rewriterDeps": "S2A_REWRITER_DEPS",
    "tzdataCache": "S2A_TZDATA_CACHE",
}


def profile(c):
    return PROFILE if getattr(c, "local_toolchain", None) is not None else None


def absolute(value):
    return (isinstance(value, str) and not any(char in value for char in ("\0", "\n", "\r", os.pathsep))
            and Path(value).is_absolute())


def contains(directory, path):
    if path.is_relative_to(directory):
        return True
    # macOS volumes may compare names without case, while Path does not.
    for candidate in (path, *path.parents):
        try:
            if candidate.samefile(directory):
                return True
        except (FileNotFoundError, NotADirectoryError):
            continue
    return False


def settings(request, engine, library):
    profile = request.get("runtimeProfile")
    if profile is None:
        return None
    if profile != PROFILE or request.get("engineBundle"):
        raise Failure("无效的 macOS 本机运行配置。")
    if request["operation"] not in OPERATIONS:
        raise Failure("本机启动器只支持 macOS 游戏操作。")
    if contains(engine, library) or contains(library, engine):
        raise Failure("请选择源码工作树外的私有游戏库，游戏库也不能包含源码工作树。")
    config = request.get("localToolchain")
    if not isinstance(config, dict) or not REQUIRED <= config.keys() or config.keys() - REQUIRED - CACHE_FIELDS.keys():
        raise Failure("本机工具链配置缺失或含不支持的字段。")
    if (not isinstance(config["path"], list) or not all(absolute(item) for item in config["path"])
            or not all(absolute(value) for name, value in config.items() if name != "path")):
        raise Failure("本机工具链配置需要绝对路径。")
    return config


def environment(c, env):
    config = c.local_toolchain
    cache = c.work_root / "cache"
    for variable in ("DOTNET_MULTILEVEL_LOOKUP", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET",
                     "IPHONEOS_DEPLOYMENT_TARGET", "DSX_LIB"):
        env.pop(variable, None)
    env.update(S2A_MACOS14="1", S2A_DIRECT_TARGETS="mac",
               S2A_MACOS_SDKROOT=config["sdkRoot"], S2A_BASH=config["bash"],
               DOTNET=config["dotnet"], DOTNET_ROOT=str(Path(config["dotnet"]).resolve().parent),
               S2A_PYTHON=config["python"], S2A_PY=config["python"],
               S2A_BUILD_CACHE=str(cache / "build"), NUGET_HTTP_CACHE_PATH=str(cache / "nuget-http"),
               CLANG_MODULE_CACHE_PATH=str(cache / "clang-modules"),
               UseSharedCompilation="false", MSBUILDDISABLENODEREUSE="1", DOTNET_CLI_USE_MSBUILD_SERVER="0")
    for name, variable in CACHE_FIELDS.items():
        if name in config:
            env[variable] = config[name]
    paths = [str(Path(config[tool]).parent) for tool in ("bash", "python", "dotnet")]
    paths += [str(c.engine / "tools/bin"), *config["path"], "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    env["PATH"] = os.pathsep.join(dict.fromkeys(paths))
    return env


def cli(c):
    # Jobs may be loaded from signed Resources while the compiler uses the
    # explicitly selected, writable engine checkout.
    import sys
    sys.path.insert(0, str(c.engine / "tools"))
    import macos14
    return macos14


def compile_host(c, env, log_root, build_lock):
    tools = cli(c)
    # Make receives these archive paths as words. Keep game-independent
    # compiler caches in the same build root as the CLI, outside the
    # potentially space-containing Application Support job path.
    cache = tools.BUILD / "run/s2arm/cache"
    host_env = dict(env, **{key: str(cache / name) for key, name in (
        ("S2A_CS_CACHE", "nxaot"), ("S2A_VPX_CACHE", "vpx"),
        ("S2A_OPUS_CACHE", "opus"), ("S2A_DAV1D_CACHE", "dav1d"),
        ("S2A_GLSLANG_CACHE", "glslang"),
    )})
    c.run(tools.host_build_command(), log_root / "host.log", host_env, pass_fds=(build_lock,))
    return tools.build_host_bundle().parents[2]
