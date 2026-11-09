#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# s2a_macos_deployment_target <RID> <toolchain.env>
s2a_macos_deployment_target() {
  local key=MACOSX_DEPLOYMENT_TARGET
  if [ "${S2A_MACOS14:-0}:$1" = 1:osx-arm64 ]; then key=S2A_MACOS14_DEPLOYMENT_TARGET; fi
  sed -n "s/^${key}=//p" "$2"
}
