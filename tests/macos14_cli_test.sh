#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# macOS 14 本机入口的参数、产物边界和私有运行目录。假宿主只处理原创测试字节。
H=$(cd "$(dirname "$0")/.." && pwd)
exec python3 -B "$H/tests/macos14_cli_test.py"
