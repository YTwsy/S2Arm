# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors

from contextlib import nullcontext
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest import skipIf
from unittest.mock import patch

from jobcase import JobCase
import build
from core import Context, Failure, atomic, digest
import library
import macos_local
import toolchain


class MacLocalTests(JobCase):
    def setUp(self):
        super().setUp()
        self.local = self.request | {
            "taskId": "local",
            "library": str(self.c.private / "游戏库"),
            "libraryId": "",
            "runtimeProfile": "macos14-local",
            "localToolchain": {
                "python": sys.executable,
                "bash": str(self.root / "bash5/bin/bash"),
                "dotnet": str(self.root / "dotnet10/dotnet"),
                "sdkRoot": str(self.root / "MacOSX26.sdk"),
                "path": [str(self.root / "build-tools/bin")],
            },
        }
        self.local.update(library.setup(Context(self.local | {"taskId": "local-setup"})))
        self.local_library = Path(self.local["library"])

    def test_profile_rejects_other_platform_operations_before_job_registration(self):
        for operation in ("ipa", "install", "downloadIosPlatform", "platformBuild"):
            with self.subTest(operation=operation):
                with self.assertRaisesRegex(Failure, "只支持 macOS"):
                    Context(self.local | {"operation": operation})
        self.assertFalse((self.c.private / "jobs/local.json").exists())

    def test_refuses_stock_library_before_writing_any_library_file(self):
        target = self.c.library
        existing = target / "iPhone" / "game.ipa"
        existing.parent.mkdir()
        existing.write_bytes(b"fixture export")
        before = {p.relative_to(target): p.read_bytes() for p in target.rglob("*") if p.is_file()}
        c = Context(self.local | {"library": str(target), "libraryId": self.request["libraryId"]})
        with self.assertRaisesRegex(Failure, "游戏库归属"):
            library.setup(c)
        with self.assertRaisesRegex(Failure, "游戏库归属"):
            with c.lock("execution"):
                self.fail("stock library lock must not be opened")
        self.assertEqual({p.relative_to(target): p.read_bytes() for p in target.rglob("*") if p.is_file()}, before)

    def test_only_empty_default_legacy_library_can_be_claimed(self):
        private = self.root / "legacy-data"
        target = private / "游戏库"
        original = self.request | {"privateRoot": str(private), "library": str(target), "taskId": "legacy-setup"}
        original.update(library.setup(Context(original)))
        marker = target / ".s2arm-library.json"
        catalog = target / "catalog.json"
        marker_before = marker.read_bytes()
        catalog_before = catalog.read_bytes()
        c = Context(self.local | original | {"taskId": "legacy-local"})
        existing = target / "iPhone"
        existing.mkdir()
        with self.assertRaisesRegex(Failure, "游戏库归属"):
            library.setup(c)
        self.assertEqual(marker.read_bytes(), marker_before)
        self.assertFalse((target / ".catalog.lock").exists())
        existing.rmdir()
        self.assertEqual(library.setup(c), {"library": str(target.resolve()), "libraryId": original["libraryId"]})
        self.assertEqual(json.loads(marker.read_text()),
                         json.loads(marker_before) | {"runtimeProfile": "macos14-local"})
        self.assertEqual(catalog.read_bytes(), catalog_before)
        c.require_library()
        stock = Context(original | {"taskId": "legacy-stock"})
        with self.assertRaisesRegex(Failure, "游戏库归属"):
            library.setup(stock)
        with self.assertRaisesRegex(Failure, "游戏库归属"):
            stock.require_library()

    def test_library_cannot_overlap_the_resolved_engine(self):
        engine = self.root / "parent/engine"
        engine.mkdir(parents=True)
        libraries = [engine, engine / "inside", engine.parent]
        if os.name != "nt":
            external_link = self.root / "link-to-engine"
            external_link.symlink_to(engine)
            libraries.append(external_link / "inside")
        for library in libraries:
            with self.subTest(library=library):
                private = self.root / "never-created"
                with self.assertRaisesRegex(Failure, "工作树外"):
                    Context(self.local | {"engineDir": str(engine), "library": str(library),
                                          "privateRoot": str(private)})
                self.assertFalse(private.exists())

    def test_environment_preserves_context_paths_and_ignores_inherited_switches(self):
        with patch.dict(os.environ, {"S2A_RYU_DATA": "/outside/saves",
                                    "S2A_RUN_ROOT": "/outside/run",
                                    "S2A_PREBUILT_TOOLS": "/outside/prepare",
                                    "DSX_LIB": "/outside/libdsx.dylib",
                                    "S2A_DIRECT_TARGETS": "ios"}):
            c = Context(self.local)
            env = c.env()
            self.assertEqual(env["S2A_RUN_ROOT"], str(c.work_root / "run"))
            self.assertEqual(env["S2A_PACK_PLAT"], "macos")
            self.assertEqual(env["S2A_DIRECT_TARGETS"], "mac")
            self.assertEqual(env["S2A_MACOS14"], "1")
            self.assertEqual(env["S2A_MACOS_SDKROOT"], self.local["localToolchain"]["sdkRoot"])
            self.assertEqual(env["PATH"].split(os.pathsep)[0], str(self.root / "bash5/bin"))
            self.assertNotIn("S2A_PREBUILT_TOOLS", env)
            self.assertNotIn("S2A_RYU_DATA", env)
            self.assertIsNone(env.get("DSX_LIB"))
            self.assertEqual(self.c.env()["DSX_LIB"], "/outside/libdsx.dylib")
        with self.assertRaisesRegex(Failure, "不支持的字段"):
            Context(self.local | {"localToolchain": self.local["localToolchain"] | {"S2A_RUN_ROOT": "/outside/run"}})

    def test_runtime_manifest_profile_matches_and_still_validates_payload(self):
        runtime = self.c.library / "games" / "0100000000000000" / "releases" / "fixture"
        (runtime / "romfs").mkdir(parents=True)
        host = runtime / "S2ArmGame.app/Contents/MacOS/s2arm-host"
        host.parent.mkdir(parents=True)
        host.write_bytes(b"host")
        host.chmod(0o755)
        manifest = {"schema": 1, "engine": "S2Arm", "target": "macos-arm64",
                    "files": {str(host.relative_to(runtime)): [4, digest(host)]}}
        local = Context(self.local | {"library": str(self.c.library)})
        atomic(runtime / "manifest.json", manifest)
        self.assertEqual(build.validate_runtime(self.c, runtime), manifest)
        with self.assertRaisesRegex(Failure, "配置与当前启动器不同"):
            build.validate_runtime(local, runtime)
        manifest["runtimeProfile"] = macos_local.PROFILE
        atomic(runtime / "manifest.json", manifest)
        self.assertEqual(build.validate_runtime(local, runtime), manifest)
        with self.assertRaisesRegex(Failure, "配置与当前启动器不同"):
            build.validate_runtime(self.c, runtime)
        host.write_bytes(b"wrong")
        with self.assertRaisesRegex(Failure, "缺失或大小不符"):
            build.validate_runtime(local, runtime)

    @skipIf(sys.platform == "win32", "Mac preflight fixture")
    def test_preflight_requires_no_mobile_platform_or_compilers_for_launch(self):
        c = Context(self.local | {"operation": "preflight"})
        def doctor(args, env, bash, report_check):
            report_check(args.scope, False, "fixture compiler")
        tools = SimpleNamespace(bash_status=lambda env: (None, "no bash"),
                                doctor=doctor, metal_device_available=lambda: True)
        with patch("platform.system", return_value="Darwin"), \
             patch("platform.machine", return_value="arm64"), \
             patch("platform.mac_ver", return_value=("14.8.5", (), "")), \
             patch.object(c, "require_source"), patch.object(toolchain, "input_interface", return_value=(False, "")), \
             patch.object(macos_local, "cli", return_value=tools), \
             patch.object(toolchain, "ios_platform", side_effect=AssertionError("mobile probe")), \
             patch.object(toolchain, "reader", side_effect=Failure("fixture reader absent")):
            checks = {item["name"]: item for item in toolchain.preflight(c)["checks"]}
        self.assertTrue(checks["macOS"]["ok"])
        self.assertTrue(all(row["ok"] for row in checks.values() if "launch" in row["requiredFor"]))
        self.assertEqual(checks["fixture compiler"]["requiredFor"], ["prepare"])
        self.assertEqual(checks["S2Arm 内容读取工具"]["action"], "prepareEngine")

    def test_input_capability_probes_the_local_host_only(self):
        engine = self.root / "engine"
        default_host = engine / "build/s2arm-host"
        default_host.parent.mkdir(parents=True)
        default_host.touch()
        c = Context(self.local | {"engineDir": str(engine)})
        with patch.object(toolchain, "_cached_probe", return_value=(True, "fixture")) as probe:
            self.assertFalse(toolchain.input_interface(c)[0])
            probe.assert_not_called()
            local_host = engine / "build/macos14/s2arm-host"
            local_host.parent.mkdir()
            local_host.touch()
            self.assertEqual(toolchain.input_interface(c), (True, "fixture"))
            probe.assert_called_once_with(c, local_host.resolve())

    def test_local_input_probe_uses_system_tools_with_build_xcode_offline(self):
        offline = str(self.root / "not-mounted/Xcode.app/Contents/Developer")
        local = Context(self.local | {"developerDir": offline})
        stock = Context(self.request | {"taskId": "stock-probe", "developerDir": offline})
        executable = self.root / "s2arm-host"
        clt_nm = "/Library/Developer/CommandLineTools/usr/bin/nm"
        calls = []

        def nm(command, *, env, **options):
            calls.append((command, env.get("DEVELOPER_DIR"), env.get("S2A_DEVELOPER_DIR")))
            if env.get("DEVELOPER_DIR") == offline:
                return SimpleNamespace(returncode=1, stdout="")
            return SimpleNamespace(returncode=0, stdout="00000001 T _s2a_vpad_read\n")

        for available, tool in ((True, clt_nm), (False, "/usr/bin/nm")):
            with self.subTest(clt_available=available), \
                 patch.object(toolchain.os, "access", return_value=available), \
                 patch.object(toolchain.subprocess, "run", side_effect=nm):
                verdict = toolchain._input_probe(executable, local)
                self.assertTrue(verdict and verdict[0])
                self.assertEqual(calls[-1], ([tool, "-gU", str(executable)], None, None))
                self.assertIsNone(toolchain._input_probe(executable, stock))
                self.assertEqual(calls[-1], (["nm", "-gU", str(executable)], offline, offline))
                self.assertEqual(local.env()["DEVELOPER_DIR"], offline)

    @skipIf(sys.platform == "win32", "POSIX .NET fixture")
    def test_worker_prepares_reader_with_configured_dotnet_without_touching_offline_library(self):
        dotnet = self.root / "selected-dotnet"
        dotnet.write_text('#!/bin/sh\nset -eu\n[ "$1" = build ] || exit 3\n'
                          'while [ "$1" != -o ]; do shift; done\n'
                          'printf reader > "$2/nx_unpack.dll"\n')
        dotnet.chmod(0o700)
        offline = self.root / "not-mounted" / "library"
        result, terminal = self.worker("prepareEngine", library=str(offline), libraryId="",
                                       runtimeProfile="macos14-local",
                                       localToolchain=self.local["localToolchain"] | {"dotnet": str(dotnet)})
        self.assertEqual(result.returncode, 0, result.stderr)
        reader = Path(terminal["result"]["reader"])
        self.assertTrue(reader.is_relative_to(self.c.private / "tools"))
        self.assertEqual(reader.read_bytes(), b"reader")
        self.assertFalse(offline.parent.exists())

    @skipIf(sys.platform == "win32", "POSIX build lock fixture")
    def test_build_lock_reaches_supervised_child(self):
        c = Context(self.local)
        tools = macos_local.cli(c)
        build_root = self.root / "build"
        with tools.directory_lock(build_root) as descriptor:
            lines = []
            c.run([sys.executable, "-c", "import os,sys; print(os.fstat(int(sys.argv[1])).st_ino)",
                   str(descriptor)], pass_fds=(descriptor,), on_line=lines.append)
            self.assertEqual(lines, [str((build_root / tools.LOCK_NAME).stat().st_ino)])
        with tools.directory_lock(build_root):
            pass

    def test_prepare_uses_distinct_cache_for_local_profile_and_compile_sdk(self):
        game = {"id": "0100000000000000", "packages": []}
        local_host = self.root / "S2ArmGame.app/Contents/MacOS/s2arm-host"
        local_host.parent.mkdir(parents=True)
        local_host.write_bytes(b"host")
        tools = SimpleNamespace(BUILD=self.root / "build", platform_error=lambda: "",
                                bash_status=lambda env: ("/fake/bash", ""),
                                directory_lock=lambda path: nullcontext(9))
        requests = [
            self.request,
            self.local,
            self.local,
            self.local | {"localToolchain": self.local["localToolchain"] |
                          {"sdkRoot": str(self.root / "MacOSX27.sdk")}},
        ]
        roots = []

        def extract(c, game, packages, env, logs, valid):
            roots.append(Path(env["S2A_ROOTS"]).parent.name)
            return self.root / "verified-extract"

        for request in requests:
            c = Context(request | {"operation": "build"})
            with patch.object(c, "require_source"), patch.object(c, "game", return_value=game), \
                 patch.object(c, "fonts_dir", return_value=self.root), \
                 patch.object(build, "require_game"), patch("library.check_pack_space"), \
                 patch.object(build, "tree_hash", return_value="fixture-source"), \
                 patch.object(build, "ensure_extract", side_effect=extract), \
                 patch.object(build, "seed_from_sibling", return_value=False) as sibling, \
                 patch.object(toolchain, "probe", return_value=(True, "fixture-tool")), \
                 patch.object(macos_local, "cli", return_value=tools), \
                 patch.object(macos_local, "compile_host", return_value=local_host.parents[2]), \
                 patch.object(sys, "platform", "darwin"), \
                 patch.object(c, "run", side_effect=Failure("fixture finished")) as run:
                with self.assertRaisesRegex(Failure, "fixture finished"):
                    build.prepare(c)
                self.assertEqual(Path(run.call_args.args[0][1]).name, "seed_root.sh")
                self.assertEqual(sibling.call_count, 0 if request.get("runtimeProfile") else 1)
        default, local, repeat, alternate_sdk = roots
        self.assertNotEqual(default, local)
        self.assertEqual(local, repeat)
        self.assertNotEqual(local, alternate_sdk)

    @skipIf(sys.platform == "win32", "POSIX launch fixture")
    def test_worker_launch_keeps_mapping_and_saves_isolated(self):
        gid = "0100000000000000"
        game_root = self.local_library / "games" / gid
        runtime = game_root / "releases" / "fixture"
        (runtime / "romfs").mkdir(parents=True)
        table = runtime / "addr_need.tsv"
        table.write_text("test address window\n")
        host = runtime / "S2ArmGame.app/Contents/MacOS/s2arm-host"
        host.parent.mkdir(parents=True)
        host.write_text("#!/bin/sh\n"
                        'printf "%s\n" "$S2A_RYU_DATA" "${S2A_SAVE_DIR-unset}" "$S2A_MACOS14" > result.txt\n'
                        'cat "$S2A_INPUT_CONFIG" > mapping.json\n')
        host.chmod(0o755)
        atomic(runtime / "manifest.json", {
            "schema": 1, "engine": "S2Arm", "target": "macos-arm64", "gameId": gid,
            "runtimeProfile": "macos14-local",
            "memoryRequirementsVersion": 2, "memoryRequirementsSha256": digest(table),
            "files": {str(p.relative_to(runtime)): [p.stat().st_size, digest(p)] for p in (table, host)},
        })
        (game_root / "current").symlink_to(runtime.relative_to(game_root))
        atomic(self.local_library / "catalog.json", {"schema": 1, "games": [{"id": gid, "name": "Fixture"}]})
        mapping = {"schema": 1, "keyboard": {"A": {"code": 0}}, "mouse": {}, "gamepad": {},
                   "axes": {}, "deadzone": .15,
                   "mouseOptions": {"mode": "off", "sensitivityX": 1, "sensitivityY": 1}}
        atomic(self.c.private / "default-input.json", mapping)
        extra = {key: self.local[key] for key in ("runtimeProfile", "localToolchain", "library", "libraryId")}
        result, terminal = self.worker("launch", gameId=gid, **extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(terminal["result"]["gameId"], gid)
        run = self.local_library / "temp" / gid
        self.assertEqual((run / "result.txt").read_text().splitlines(),
                         [str(self.local_library / "saves" / gid), "", "1"])
        self.assertEqual(json.loads((run / "mapping.json").read_text()), mapping)
        self.assertEqual(list((self.c.private / "runtime-input" / gid).iterdir()), [])
