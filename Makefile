# PullOver X — Theos 构建(roothide scheme),供 build_roothide.sh 调用。
#
# 复用既有打包树 PullOverX/Package:THEOS_LAYOUT_DIR 指向该目录后,Theos
# 从中读取 DEBIAN/control 与 DEBIAN/postinst;Library/ 树(MobileSubstrate
# filter、PreferenceLoader 入口、偏好包资源)由下方 internal-stage rsync。
#
# 与 build.sh(Xcode 路线)的对应关系:
#   PullOverX.dylib        <- PullOverX/ 下除相机兼容外的全部源 + POLocalization.m
#   PullOverXCamera.dylib  <- PullOverX/POCameraCompatibility.m(注入媒体 daemon)
#   PullOverXPreferences.bundle <- PullOverXPreferences/ 子项目(bundle.mk)
#
# Usage(通常经由 build_roothide.sh):
#   THEOS_PACKAGE_SCHEME=roothide TARGET=iphone:clang:16.5:15.0 make package

export ARCHS = arm64 arm64e

TARGET ?= iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= roothide

export DEBUG = 0
export FINALPACKAGE = 1

# Theos 会 rsync $(THEOS_LAYOUT_DIR)/DEBIAN 进 staging,并用其中的 control
# 生成包描述(Architecture/Version 由 Theos 按 scheme 自动改写)。
THEOS_LAYOUT_DIR = $(CURDIR)/PullOverX/Package

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PullOverX PullOverXCamera

# 与 xcconfig 一致:宿主/私有符号一律运行时解析,roothide 需显式链 libroothide。
SCHEME_LDFLAGS = -undefined dynamic_lookup -Wl,-w -Wl,-dead_strip

PullOverX_FILES = $(filter-out PullOverX/POCameraCompatibility.m,$(wildcard PullOverX/*.m PullOverX/*.mm)) POLocalization.m
PullOverX_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
PullOverX_CFLAGS = -fobjc-arc
PullOverX_LDFLAGS = $(SCHEME_LDFLAGS) -lroothide

# 相机兼容 dylib:MSHookMessageEx 显式链 substrate(与 build.sh 相同)。
PullOverXCamera_FILES = PullOverX/POCameraCompatibility.m
PullOverXCamera_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
PullOverXCamera_CFLAGS = -fobjc-arc
PullOverXCamera_LDFLAGS = $(SCHEME_LDFLAGS)
PullOverXCamera_LIBRARIES = substrate

# INSTALL=0 关闭 tweak.mk 自带的 staging(它会要求根目录存在同名 filter
# plist,并把库拷进 $(THEOS)/lib);改为在 internal-stage 统一收集。
PullOverX_INSTALL = 0
PullOverXCamera_INSTALL = 0

SUBPROJECTS += PullOverXPreferences

internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(THEOS_OBJ_DIR)/PullOverX.dylib" "$(THEOS_OBJ_DIR)/PullOverXCamera.dylib" "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"$(ECHO_END)
	$(ECHO_NOTHING)rsync -a "PullOverX/Package/Library/" "$(THEOS_STAGING_DIR)/Library/"$(ECHO_END)
	$(ECHO_NOTHING)rsync -a "PullOverXPreferences/Package/Library/" "$(THEOS_STAGING_DIR)/Library/"$(ECHO_END)

before-package::
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst" 2>/dev/null || true$(ECHO_END)

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
