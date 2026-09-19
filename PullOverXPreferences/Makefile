# PullOver X 偏好设置 bundle —— Theos 子项目(由上层 Makefile 的 SUBPROJECTS 进入)。
#
# 运行时资源(specifier plist、图标、本地化 strings)沿用打包树里的
# Package/Library/PreferenceBundles/PullOverXPreferences.bundle;Resources/
# 只放 Theos 组包所需的 Info.plist(源树中原本没有)。

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = PullOverXPreferences

# 白名单页(PullOverXPreferences.plist 的 PSLinkListCell)的 detail 类
# ATLApplicationListMultiSelectionController 由 com.opa334.altlist 提供,
# bundle 源码不直接引用 ATL 符号;若不显式产生加载命令,Settings 进程不会
# 加载 AltList,类查找失败导致白名单页只有标题没有内容。-needed_framework
# 强制在链接产物里保留 LC_LOAD(不被 -dead_strip 省略)。tbd 按方案区分
# install-name:roothide 为 @loader_path/.jbroot/...,rootless 为 @rpath/
# (需补 /var/jb 的 rpath),rootful 为绝对路径。
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
PO_ALTLIST_FRAMEWORK_DIR = $(CURDIR)/Frameworks/_rootless
PO_ALTLIST_LDFLAGS = -F$(PO_ALTLIST_FRAMEWORK_DIR) -framework AltList -Wl,-needed_framework,AltList -Wl,-rpath,/var/jb/Library/Frameworks
else ifeq ($(THEOS_PACKAGE_SCHEME),rootful)
PO_ALTLIST_LDFLAGS = -F$(CURDIR)/Frameworks -framework AltList -Wl,-needed_framework,AltList
else
PO_ALTLIST_LDFLAGS = -F$(CURDIR)/Frameworks/_roothide -framework AltList -Wl,-needed_framework,AltList
endif

# POApplicationHelper 与 Xcode 工程一致也编进 bundle:Settings 进程加载时
# 无法解析 SpringBoard tweak 里的符号(flat namespace dlopen 会报
# symbol not found in flat namespace '_OBJC_CLASS_$_POApplicationHelper')。
PullOverXPreferences_FILES = PullOverXPreferencesController.m QSFavoritesPickerController.m POStepperTableCell.m POTimeStepperTableCell.m ../POLocalization.m ../PullOverX/POApplicationHelper.m
PullOverXPreferences_INSTALL_PATH = /Library/PreferenceBundles
PullOverXPreferences_FRAMEWORKS = UIKit CoreGraphics
PullOverXPreferences_PRIVATE_FRAMEWORKS = Preferences AppSupport
PullOverXPreferences_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/PullOverX
PullOverXPreferences_LDFLAGS = $(PO_ALTLIST_LDFLAGS) -undefined dynamic_lookup -Wl,-w -Wl,-dead_strip

PullOverXPreferences_RESOURCE_DIRS = Resources Package/Library/PreferenceBundles/PullOverXPreferences.bundle

include $(THEOS_MAKE_PATH)/bundle.mk
