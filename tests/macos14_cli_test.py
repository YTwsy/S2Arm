#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import macos14


class MacOS14CLI(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.workspace = Path(temporary.name).resolve()
        self.root = self.workspace / "source-tree"
        self.root.mkdir()
        self.build = self.root / "build/macos14"
        self.app = self.build / "S2Arm Local.app"
        self.bash = self.root / "fixture-bash5"
        self.bash.write_text("#!/bin/sh\nprintf '%s' '5.2.0(1)-release'\n")
        self.bash.chmod(0o700)
        bash_env = patch.dict(os.environ, {"S2A_BASH": str(self.bash)})
        bash_env.start()
        self.addCleanup(bash_env.stop)
        for attr, value in (("ROOT", self.root), ("BUILD", self.build), ("platform_error", lambda: "")):
            patcher = patch.object(macos14, attr, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    @staticmethod
    def prepared(path):
        for name in ("main.npdm", "main.patched.bin", "main.fixups.tsv", "main.gates.tsv",
                     "addr_need.tsv", "romfs.s2aidx", "ctl/control.nacp", ".stage_direct",
                     "shaders/direct/keys.tsv"):
            item = path / name
            item.parent.mkdir(parents=True, exist_ok=True)
            item.write_text("synthetic\n")
        (path / "romfs").mkdir()
        (path / "unpack.tsv").write_text("title_id\t0100ABCD00010000\nname\tFixture\n")
        return path

    def test_old_bash_rejects_build_and_prepare_before_dispatch(self):
        old_bash = self.root / "legacy-bash"
        old_bash.write_text("#!/bin/sh\nprintf '%s' '3.2.57(1)-release'\n")
        old_bash.chmod(0o700)
        source = self.workspace / "source"
        source.mkdir()
        keys = self.workspace / "keys"
        keys.touch()
        out = self.workspace / "output"
        real_run = subprocess.run

        def probe_only(command, **options):
            self.assertEqual(command[0], str(old_bash))
            return real_run(command, **options)

        with patch.dict(os.environ, {"S2A_BASH": str(old_bash)}), \
             patch.object(macos14.subprocess, "run", side_effect=probe_only) as spawn, \
             redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(macos14.main(["build"]), 1)
            self.assertEqual(macos14.main(["prepare", str(source), "--keys", str(keys), "--out", str(out)]), 1)
        self.assertEqual(spawn.call_count, 2)
        self.assertIn("Bash 5+", errors.getvalue())
        self.assertIn("3.2.57", errors.getvalue())
        self.assertFalse(self.build.exists())
        self.assertFalse(out.exists())

    def assert_selected_bash(self, env):
        self.assertEqual(env["S2A_BASH"], str(self.bash))
        self.assertEqual(Path(shutil.which("bash", path=env["PATH"])).resolve(), self.bash)

    def test_build_delegates_to_isolated_native_profile(self):
        def make(command, **options):
            self.assertEqual(command, ["make", "host", "S2A_MACOS14=1", "S2A_CS=1",
                                       "S2A_MAC_FRONTEND=1", "BUILD=build/macos14"])
            self.assertEqual(options["cwd"], self.root)
            self.assert_selected_bash(options["env"])
            (self.build / "s2arm-host").touch(mode=0o700)
            (self.build / "libs2a_vaguard.dylib").touch()
            return subprocess.CompletedProcess(command, 0)
        bundled_host = self.app / "Contents/MacOS/s2arm-host"

        def bundle(host, guard, application):
            self.assertTrue(host.is_file())
            self.assertTrue(guard.is_file())
            with self.assertRaisesRegex(ValueError, "另一个本机任务正在使用目录"):
                with macos14.directory_lock(self.build):
                    pass
            return bundled_host

        with patch.object(macos14, "probe", return_value=(True, "5.2.0(1)-release")), \
             patch.object(macos14.subprocess, "run", side_effect=make), \
             patch.object(macos14, "create_bundle", side_effect=bundle, create=True) as publish, \
             redirect_stdout(io.StringIO()) as output:
            self.assertEqual(macos14.main(["build"]), 0)
        publish.assert_called_once_with(self.build / "s2arm-host", self.build / "libs2a_vaguard.dylib", self.app)
        self.assertIn(str(bundled_host), output.getvalue())

    def test_prepare_delegates_full_mac_target_and_uses_this_attempt_result(self):
        source = self.workspace / "Source folder"
        source.mkdir()
        keys = self.workspace / "Key folder/prod.keys"
        keys.parent.mkdir()
        keys.write_bytes(b"synthetic-only")
        out = self.workspace / "Private output"
        prepared = out / "roots/fixture@finished"

        def oneclick(command, **options):
            self.assertEqual(command[:-2], [str(self.bash), self.root / "pack/oneclick/oneclick.sh",
                                            source, "--target", "mac", "--keys", keys, "--out", out])
            self.assertEqual(command[-2], "--events")
            self.assertEqual(options["env"]["S2A_MACOS14"], "1")
            self.assertNotIn("S2A_PREBUILT_TOOLS", options["env"])
            self.assertEqual(options["env"]["S2A_DIRECT_TARGETS"], "mac")
            self.assert_selected_bash(options["env"])
            self.prepared(prepared)
            Path(command[-1]).write_text(json.dumps(dict(ev="result", ok=True, root=str(prepared))) + "\n")
            return subprocess.CompletedProcess(command, 0)

        with patch.dict(os.environ, {"S2A_PREBUILT_TOOLS": "/other/app", "S2A_DIRECT_TARGETS": "ios"}), \
             patch.object(macos14, "probe", return_value=(True, "5.2.0(1)-release")), \
             patch.object(macos14.subprocess, "run", side_effect=oneclick), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(macos14.main(["prepare", str(source), "--keys", str(keys), "--out", str(out)]), 0)
        self.assertIn(str(prepared), output.getvalue())
        self.assertEqual(keys.read_bytes(), b"synthetic-only")
        self.assertEqual(list(source.iterdir()), [])

    def test_prepare_rejects_output_inside_source_before_dispatch(self):
        source = self.workspace / "source"
        source.mkdir()
        keys = self.workspace / "keys"
        keys.touch()
        args = macos14.parser().parse_args(["prepare", str(source), "--keys", str(keys),
                                            "--out", str(source / "output")])
        with patch.object(macos14.subprocess, "run") as spawn, self.assertRaisesRegex(ValueError, "--out"):
            macos14.prepare(args, macos14.environment())
        spawn.assert_not_called()
        self.assertFalse((source / "output").exists())

    def test_prepare_rejects_output_overlapping_checkout_before_lock_or_dispatch(self):
        source = self.workspace / "source"
        source.mkdir()
        keys = self.workspace / "keys"
        keys.touch()
        alias = self.workspace / "checkout-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with patch.object(macos14, "directory_lock") as lock, patch.object(macos14.subprocess, "run") as spawn:
            for out in (self.root / "output", self.root, self.workspace, alias / "output"):
                with self.subTest(out=out):
                    args = macos14.parser().parse_args(["prepare", str(source), "--keys", str(keys),
                                                        "--out", str(out)])
                    with self.assertRaisesRegex(ValueError, "源码工作树外"):
                        macos14.prepare(args, macos14.environment())
        lock.assert_not_called()
        spawn.assert_not_called()
        self.assertFalse((self.root / "output").exists())

    def test_prepare_rejects_stale_receipt(self):
        source = self.workspace / "source"
        source.mkdir()
        keys = self.workspace / "keys"
        keys.touch()
        out = self.workspace / "output"
        prepared = self.prepared(out / "roots/fixture@old")
        logdir = out / "logs"
        logdir.mkdir()
        (logdir / "mac_root.txt").write_text(str(prepared) + "\n")
        args = macos14.parser().parse_args(["prepare", str(source), "--keys", str(keys), "--out", str(out)])
        with patch.object(macos14.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
             self.assertRaisesRegex(ValueError, "没有发布成功"):
            macos14.prepare(args, macos14.environment())

    def test_prepare_lock_follows_inherited_worker(self):
        source = self.workspace / "source"
        source.mkdir()
        keys = self.workspace / "keys"
        keys.touch()
        out = self.workspace / "output"
        args = macos14.parser().parse_args(["prepare", str(source), "--keys", str(keys), "--out", str(out)])
        worker = None

        def oneclick(command, **options):
            nonlocal worker
            env = options["env"]
            self.assertEqual(env.get("UseSharedCompilation"), "false")
            self.assertEqual(env.get("MSBUILDDISABLENODEREUSE"), "1")
            self.assertEqual(env.get("DOTNET_CLI_USE_MSBUILD_SERVER"), "0")
            worker = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.buffer.read()"],
                                      stdin=subprocess.PIPE, pass_fds=options["pass_fds"])
            return subprocess.CompletedProcess(command, 17)

        try:
            with patch.object(macos14.subprocess, "run", side_effect=oneclick):
                self.assertEqual(macos14.prepare(args, macos14.environment()), 17)
            # The preparing process returned, but its in-flight worker still owns the lock.
            with self.assertRaisesRegex(ValueError, "另一个本机任务正在使用目录"):
                with macos14.directory_lock(out):
                    pass
        finally:
            if worker is not None:
                worker.communicate(timeout=5)
        with macos14.directory_lock(out):
            self.assertEqual(worker.returncode, 0)

    def test_run_rejects_lite_root_before_creating_state(self):
        prepared = self.prepared(self.root / "prepared")
        (prepared / ".stage_direct").unlink()
        state = self.root / "state"
        args = macos14.parser().parse_args(["run", "--prepared", str(prepared), "--state", str(state)])
        with patch.object(macos14, "host_path", return_value=self.build / "s2arm-host"), \
             patch.object(macos14.subprocess, "run") as spawn, self.assertRaisesRegex(ValueError, "stage_direct"):
            macos14.run(args, macos14.environment())
        spawn.assert_not_called()
        self.assertFalse(state.exists())

    def test_run_refuses_prepared_root_while_output_is_locked(self):
        output = self.root / "output"
        prepared = self.prepared(output / "roots/fixture@finished")
        state = self.root / "state"
        args = macos14.parser().parse_args(["run", "--prepared", str(prepared), "--state", str(state)])
        with macos14.directory_lock(output), patch.object(macos14, "host_path"), \
             self.assertRaisesRegex(ValueError, "另一个本机任务正在使用目录"):
            macos14.run(args, macos14.environment())
        self.assertFalse(state.exists())

    def test_run_and_doctor_require_a_complete_bundle(self):
        prepared = self.prepared(self.root / "prepared")
        state = self.root / "state"
        self.build.mkdir(parents=True)
        (self.build / "s2arm-host").touch(mode=0o700)
        (self.build / "libs2a_vaguard.dylib").touch()
        args = macos14.parser().parse_args(["run", "--prepared", str(prepared), "--state", str(state)])
        with patch.object(macos14, "metal_device_available", return_value=True), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(macos14.main(["doctor", "--for", "run", "--prepared", str(prepared)]), 1)
        self.assertIn(self.app.name, output.getvalue())
        with self.assertRaisesRegex(ValueError, r"S2Arm Local\.app"):
            macos14.run(args, macos14.environment())
        self.assertFalse(state.exists())

        host = self.app / "Contents/MacOS/s2arm-host"
        host.parent.mkdir(parents=True)
        host.touch(mode=0o700)
        (self.app / "Contents/Info.plist").touch()
        with self.assertRaisesRegex(ValueError, "护栏"):
            macos14.run(args, macos14.environment())
        self.assertFalse(state.exists())

    def test_run_uses_private_state_and_returns_host_failure(self):
        prepared = self.prepared(self.root / "prepared")
        state = self.root / "private state"
        argv = ["run", "--prepared", str(prepared), "--state", str(state), "--seconds", "25"]
        host = self.app / "Contents/MacOS/s2arm-host"
        host.parent.mkdir(parents=True)
        (self.app / "Contents/Info.plist").touch()
        host.write_text("""#!/bin/sh
printf '%s\\n' "$0" "$1" "$PWD" "$S2A_GAME_DATA" "$S2A_RYU_DATA" "$S2A_SAVE_DIR" "$S2A_RUN_S" "$S2A_FRAMES_TSV"
exit 17
""")
        host.chmod(0o700)
        (host.parent / "libs2a_vaguard.dylib").touch()
        bare = self.build / "s2arm-host"
        bare.write_text("#!/bin/sh\nexit 99\n")
        bare.chmod(0o700)
        before = sorted(str(p.relative_to(prepared)) for p in prepared.rglob("*"))
        script = """
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
import macos14
macos14.ROOT = Path(sys.argv[2])
macos14.BUILD = macos14.ROOT / "build/macos14"
macos14.platform_error = lambda: ""
sys.exit(macos14.main(sys.argv[3:]))
"""
        env = dict(os.environ, S2A_SAVE_DIR="/original/saves", S2A_RYU_DATA="/original/ryu")
        result = subprocess.run([sys.executable, "-B", "-c", script, str(Path(macos14.__file__).parent),
                                 str(self.root), *argv], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        logs = list(state.glob("host-*.log"))
        self.assertEqual(len(logs), 1)
        self.assertEqual(logs[0].read_text().splitlines(),
                         [str(host), str(prepared), str(state), str(prepared), str(state / "ryu"), "",
                          "25", str(logs[0].with_suffix(".frames.tsv"))])
        self.assertEqual(sorted(str(p.relative_to(prepared)) for p in prepared.rglob("*")), before)

    def test_run_doctor_does_not_probe_build_or_prepare_tools(self):
        prepared = self.prepared(self.root / "prepared")
        with patch.object(macos14, "metal_device_available", return_value=True), \
             patch.object(macos14, "host_path"), patch.object(macos14, "probe") as probe, \
             redirect_stdout(io.StringIO()) as output:
            self.assertEqual(macos14.main(["doctor", "--for", "run", "--prepared", str(prepared)]), 0)
        probe.assert_not_called()
        self.assertIn("[run] OK", output.getvalue())
        self.assertNotIn(".NET", output.getvalue())


if __name__ == "__main__":
    unittest.main()
