# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Apple Silicon 本机兼容构建。工具链默认值由 tools/toolchain.env 提供。
ifeq ($(S2A_MACOS14),1)
ifneq ($(shell uname -sm),Darwin arm64)
$(error S2A_MACOS14=1 仅支持 Apple Silicon Mac)
endif
ifneq ($(filter ios ios-% glx-ios,$(MAKECMDGOALS)),)
$(error S2A_MACOS14=1 仅支持 macOS 构建目标)
endif
override MACOSX_DEPLOYMENT_TARGET := $(S2A_MACOS14_DEPLOYMENT_TARGET)
S2A_MACOS14_CFLAGS := -arch arm64 -DS2A_MACOS14=1
S2A_MACOS14_SYSROOT := $(if $(S2A_MACOS_SDKROOT),-isysroot "$(S2A_MACOS_SDKROOT)")
export S2A_MACOS14 S2A_MACOS_SDKROOT MACOSX_DEPLOYMENT_TARGET

# 同一兼容档切换 SDK / Xcode 时重新构建静态库。
s2a_macos14_stamp = $(shell mkdir -p "$(1)" && f="$(1)/.macos14_cfg" && c='$(DEVELOPER_DIR) $(S2A_MACOS14_CFLAGS) $(S2A_MACOS14_SYSROOT) $(MACOSX_DEPLOYMENT_TARGET)' && { [ "$$(cat "$$f" 2>/dev/null)" = "$$c" ] || printf '%s' "$$c" > "$$f"; })$(1)/.macos14_cfg
endif
