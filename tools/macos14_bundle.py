# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Stage the local Mac host as an AppKit application bundle."""

import ctypes
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

HOST_NAME = "s2arm-host"
GUARD_NAME = "libs2a_vaguard.dylib"
BUNDLE_NAME = "S2Arm Local.app"
BUNDLE_ID = "local.s2arm.macos14"


def create_bundle(host: Path, guard: Path, bundle: Path) -> Path:
    """Publish a complete app and return its executable path."""
    if bundle.is_symlink() or bundle.suffix != ".app":
        raise ValueError(f"本机宿主的应用目录无效：{bundle}")
    if bundle.exists():
        with (bundle / "Contents/Info.plist").open("rb") as info:
            existing = plistlib.load(info)
        if existing.get("CFBundleIdentifier") != BUNDLE_ID or existing.get("CFBundleExecutable") != HOST_NAME:
            raise ValueError(f"本机宿主的应用目录已被占用：{bundle}")

    with tempfile.TemporaryDirectory(prefix=".s2arm-app-", dir=bundle.parent) as staging:
        new = Path(staging) / bundle.name
        macos = new / "Contents/MacOS"
        macos.mkdir(parents=True)
        shutil.copy2(host, macos / HOST_NAME)
        # The host weak-links this library with @executable_path.
        shutil.copy2(guard, macos / GUARD_NAME)
        with (new / "Contents/Info.plist").open("wb") as info:
            plistlib.dump({
                "CFBundleDisplayName": "S2Arm Local",
                "CFBundleExecutable": HOST_NAME,
                "CFBundleIdentifier": BUNDLE_ID,
                "CFBundleName": "S2Arm Local",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "14.0",
            }, info)
        signed = subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(new)],
            capture_output=True, text=True,
        )
        if signed.returncode:
            raise ValueError(f"本机宿主应用签名失败：{signed.stderr.strip()}")
        if bundle.exists():
            # Replace both Mach-O files together. The old app lands in staging.
            swap = ctypes.CDLL(None, use_errno=True).renamex_np
            swap.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
            swap.restype = ctypes.c_int
            if swap(os.fsencode(new), os.fsencode(bundle), 2) != 0:  # RENAME_SWAP
                error = ctypes.get_errno()
                raise OSError(error, os.strerror(error), bundle)
        else:
            os.rename(new, bundle)
    return bundle / "Contents/MacOS" / HOST_NAME
