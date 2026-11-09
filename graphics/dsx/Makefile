# 直连着色器翻译库 libdsx（11-08 拆苹果端通用渲染器第一步）：直连出库 / 设备首遇现编与渲染器共用的翻译段，纯 C + SPIRV-Cross，不引 Metal / ObjC。
#   源码 = 本目录全部 *.c（colorround / spvx / spill / tessxc / vpullc / dsx_xc）；SPIRV-Cross（graphics/third_party/spirv_cross）只在这里编一份。
#   产物（<仓库根>/build/dsx，不进仓）：libdsx.dylib（工具 / 单测）、mac/libdsx.a 与 ios/libdsx.a（静态链接：宿主 / iOS App 与 libnxgal 一起链，graphics/build.mk）、linux/libdsx.so（Linux 出包机）。
#   导出 = dsx_abi.h 里标 NXGAL_API 的函数；其余（含 spvc_*）-fvisibility=hidden。用法：make -C graphics/dsx
ROOT  := $(abspath ../..)
# Xcode 选法同 graphics/metal/Makefile（S2A_DEVELOPER_DIR > 环境 DEVELOPER_DIR > xcode-select）
_S2A_ENV_DD := $(DEVELOPER_DIR)
include $(ROOT)/tools/toolchain.env
include $(ROOT)/tools/macos14.mk
DEVELOPER_DIR := $(or $(S2A_DEVELOPER_DIR),$(_S2A_ENV_DD),$(shell xcode-select -p 2>/dev/null))
export DEVELOPER_DIR MACOSX_DEPLOYMENT_TARGET
OUT   := $(ROOT)/build/$(if $(S2A_MACOS14_CFLAGS),macos14/)dsx
MACOS14_STAMP := $(if $(S2A_MACOS14_CFLAGS),$(call s2a_macos14_stamp,$(OUT)))
# SRCDIR：本库 C 源所在目录（缺省本目录；可指向副本另编一份，SPIRV-Cross 仍取本树那份）
SRCDIR ?= $(ROOT)/graphics/dsx
.DELETE_ON_ERROR:
SRCS  := $(sort $(notdir $(wildcard $(SRCDIR)/*.c)))
HDRS  := $(wildcard $(SRCDIR)/*.h)
# 路径映射（PFX / MACSYS）同 graphics/metal/Makefile：发布的库不带出包机用户目录，各机同一份 SDK 路径映射成固定名
PFX   := -ffile-prefix-map=$(ROOT)=.
# 这里不引 Metal，使用所选编译器配套的 SDK 和 libc++ 头。macOS 14 档只在渲染器和宿主上使用新 SDK 的 Metal 头。
MAC_SDK := $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun --sdk macosx --show-sdk-path 2>/dev/null)
XC_APP := $(if $(DEVELOPER_DIR),$(abspath $(DEVELOPER_DIR)/../..))
XC_APP_REAL := $(if $(XC_APP),$(shell cd $(XC_APP) 2>/dev/null && pwd -P))
MACSYS := $(if $(MAC_SDK),-isysroot $(MAC_SDK) -ffile-prefix-map=$(MAC_SDK)=MacOSX.sdk) $(if $(XC_APP),-ffile-prefix-map=$(XC_APP)=Xcode.app) $(if $(XC_APP_REAL),-ffile-prefix-map=$(XC_APP_REAL)=Xcode.app)
IOS_SDK := $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
IOS_FLAGS := -arch arm64 -isysroot $(IOS_SDK) -mios-version-min=$(IPHONEOS_DEPLOYMENT_TARGET)
SPVC_DIR := $(ROOT)/graphics/third_party/spirv_cross
SPVC_SRC := $(addprefix $(SPVC_DIR)/,spirv_cfg.cpp spirv_cross.cpp spirv_cross_c.cpp spirv_cross_parsed_ir.cpp spirv_glsl.cpp spirv_msl.cpp spirv_parser.cpp)
SPVC_DEF := -DSPIRV_CROSS_C_API_MSL=1 -DSPIRV_CROSS_C_API_GLSL=1
# 本库 C 源的编译参数（不含路径：翻译键 graphics/tools/shbake/xc_key.sh 读它进键，SPIRV-Cross 头目录在编译行单加）
DSX_CFLAGS := -std=gnu11 -O2 -g -Wall -Wextra -Wno-unused-parameter -Werror
# SPIRV-Cross 目标文件单独成 Mac 静态库（graphics/metal 的单测 / vk_core / vk_xlate 等直接调 spvc_* 的也链它）
SPVC_LIB := $(OUT)/mac/libspvc.a
J     ?= 8

all: $(OUT)/libdsx.dylib $(OUT)/mac/libdsx.a $(if $(S2A_MACOS14_CFLAGS),,$(OUT)/ios/libdsx.a $(OUT)/linux/libdsx.so)
mac: $(OUT)/mac/libdsx.a
ios: $(OUT)/ios/libdsx.a

# 静态库原子出（同 graphics/metal/Makefile LIBCHK：私有目录编、临时名出库、核成员数再改名到位，并行两份互不踩）
LIBCHK = [ $$(ar t $@.$$$$ | grep -c '\.o$$') -ge $$(ls "$$d"/*.o | wc -l) ] || { echo "【红】$@：建出的库成员数少于目标文件数"; exit 1; }
$(SPVC_LIB): $(SPVC_SRC) $(MACOS14_STAMP)
	@mkdir -p $(dir $@)
	d=$$(mktemp -d $@.o.XXXXXX) && trap 'rm -rf "$$d" "$@.$$$$"' EXIT \
	  && (cd "$$d" && for f in $(SPVC_SRC); do clang++ $(PFX) $(MACSYS) $(S2A_MACOS14_CFLAGS) -std=c++17 -O2 -fvisibility=hidden -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) $(SPVC_DEF) -c $$f || exit 1; done) \
	  && ar rcs $@.$$$$ "$$d"/*.o && { $(LIBCHK); } && mv -f $@.$$$$ $@
$(OUT)/mac/libdsx.a: $(addprefix $(SRCDIR)/,$(SRCS)) $(HDRS) $(SPVC_LIB) Makefile
	@mkdir -p $(dir $@)
	d=$$(mktemp -d $@.o.XXXXXX) && trap 'rm -rf "$$d" "$@.$$$$"' EXIT \
	  && (cd "$$d" && for f in $(addprefix $(SRCDIR)/,$(SRCS)); do clang $(PFX) $(MACSYS) $(S2A_MACOS14_CFLAGS) $(DSX_CFLAGS) -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -fvisibility=hidden -I$(SPVC_DIR) -c $$f || exit 1; done) \
	  && libtool -static -o $@.$$$$ "$$d"/*.o $(SPVC_LIB) && { $(LIBCHK); } && mv -f $@.$$$$ $@
# dylib = mac 静态库整份链入（与静态链进宿主 / iOS App 的是同一批目标文件）
$(OUT)/libdsx.dylib: $(OUT)/mac/libdsx.a
	clang $(MACSYS) $(S2A_MACOS14_CFLAGS) -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -dynamiclib -install_name @rpath/libdsx.dylib -o $@ -Wl,-force_load,$< -lc++
$(OUT)/ios/libdsx.a: $(addprefix $(SRCDIR)/,$(SRCS)) $(HDRS) $(SPVC_SRC) Makefile
	@mkdir -p $(dir $@)
	d=$$(mktemp -d $@.o.XXXXXX) && trap 'rm -rf "$$d" "$@.$$$$"' EXIT \
	  && (cd "$$d" && for f in $(SPVC_SRC); do clang++ $(PFX) -std=c++17 -O2 -fvisibility=hidden $(IOS_FLAGS) $(SPVC_DEF) -c $$f || exit 1; done \
	      && for f in $(addprefix $(SRCDIR)/,$(SRCS)); do clang $(PFX) $(DSX_CFLAGS) -fvisibility=hidden $(IOS_FLAGS) -I$(SPVC_DIR) -c $$f || exit 1; done) \
	  && ar rcs $@.$$$$ "$$d"/*.o && { $(LIBCHK); } && mv -f $@.$$$$ $@
# Linux 出包机（#783，取代原 graphics/metal 的 linux/libnxgal.so 三段小库）：与 Mac 同一源码集合 + SPIRV-Cross；用宿主 CC / CXX
$(OUT)/linux/libdsx.so: $(addprefix $(SRCDIR)/,$(SRCS)) $(HDRS) $(SPVC_SRC) Makefile
	@mkdir -p $(dir $@)
	d=$$(mktemp -d $@.o.XXXXXX) && trap 'rm -rf "$$d" "$@.$$$$"' EXIT \
	  && (cd "$$d" && for f in $(SPVC_SRC); do $(CXX) $(PFX) -std=c++17 -O2 -fPIC -fvisibility=hidden $(SPVC_DEF) -c $$f || exit 1; done \
	      && for f in $(addprefix $(SRCDIR)/,$(SRCS)); do $(CC) $(PFX) $(DSX_CFLAGS) -fPIC -fvisibility=hidden -I$(SPVC_DIR) -c $$f || exit 1; done) \
	  && $(CXX) -shared -o $@.$$$$ "$$d"/*.o && mv -f $@.$$$$ $@

clean:
	rm -rf $(OUT)
.PHONY: all mac ios clean
