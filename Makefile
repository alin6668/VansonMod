TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# 多巴胺 (Dopamine) rootless 越狱
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# ============================================================
# 1. VansonMod UI App
# ============================================================
APPLICATION_NAME = VansonMod

VansonMod_RESOURCE_DIRS = Resources

PACKAGE_VERSION = $(shell grep -i "Version:" control | awk '{print $$2}')

VansonMod_FILES = \
	main.mm \
	src/core/VMAppDelegate.mm \
	src/core/VMRootViewController.mm \
	src/core/UpdateCore.cpp \
	src/core/ScriptCore.cpp \
	src/core/HookCore.cpp \
	src/memory/VMMemoryEngine.mm \
	src/memory/core/MemoryCore.cpp \
	src/ui/main/VMAppSelectViewController.mm \
	src/ui/main/VMModifierViewController.mm \
	src/ui/main/VMSettingsViewController.mm \
	src/ui/main/VMLockListViewController.mm \
	src/ui/main/VMLockListDataSource.mm \
	src/utils/managers/VMFavoriteManager.mm \
	src/ui/main/VMScriptViewController.mm \
	src/ui/main/VMScriptToolsViewController.mm \
	src/ui/main/VMGlobalBackupViewController.mm \
	src/ui/memory/VMHexEditorViewController.mm \
	src/ui/memory/VMHexRowEditorViewController.mm \
	src/ui/memory/VMMemoryBrowserViewController.mm \
	src/ui/memory/VMMemoryActionSheet.mm \
	src/ui/memory/VMSignatureSearchViewController.mm \
	src/ui/memory/VMModuleListViewController.mm \
	src/ui/pointer/VMPointerSearchViewController.mm \
	src/ui/pointer/VMPointerLockCell.mm \
	src/ui/pointer/VMSignatureLockCell.mm \
	src/ui/pointer/VMSavedPointersViewController.mm \
	src/ui/pointer/VMPointerSessionListViewController.mm \
	src/ui/pointer/VMPointerVerifierViewController.mm \
	src/ui/pointer/VMItemEditViewController.mm \
	src/ui/patch/VMPatcherViewController.mm \
	src/ui/patch/VMRVAManagerCell.mm \
	src/ui/patch/VMBackupListViewController.mm \
	src/utils/managers/VMBackupManager.mm \
	src/utils/managers/BackupCore.mm \
	src/utils/managers/PointerCore.mm \
	src/memory/core/SessionCore.mm \
	src/utils/managers/PatchCore.mm \
	src/utils/managers/StorageCore.mm \
	src/utils/managers/VMLockManager.mm \
	src/utils/managers/VMPointerManager.mm \
	src/utils/managers/VMUpdateManager.mm \
	src/utils/managers/VMScriptManager.mm \
	src/utils/models/VMDataSession.mm \
	src/utils/models/VMPointerChain.mm \
	src/utils/models/VMRVAPatch.mm \
	src/utils/models/VMSignatureModel.mm \
	src/utils/models/VMScriptModel.mm \
	src/utils/helpers/VMLocalization.mm \
	src/utils/helpers/VMUIHelper.mm \
	src/utils/helpers/VMShareHelper.mm \
	src/utils/helpers/VMIconHelper.mm \
	src/utils/helpers/VMStoragePathHelper.mm \
	src/utils/managers/LockCore.mm \
	src/utils/managers/VMLockEngine.mm \
	src/utils/helpers/LocalizationCore.cpp \
	src/utils/helpers/lang/Lang_EN.cpp \
	src/utils/helpers/lang/Lang_CN.cpp \
	src/utils/helpers/lang/Lang_TW.cpp \
	src/utils/helpers/lang/Lang_JA.cpp \
	src/utils/helpers/lang/Lang_KO.cpp \
	src/utils/helpers/lang/Lang_RU.cpp \
	src/utils/helpers/lang/Lang_ES.cpp \
	src/utils/helpers/lang/Lang_VI.cpp \
	src/utils/helpers/lang/Lang_PT.cpp \
	src/utils/helpers/lang/Lang_FR.cpp \
	src/utils/helpers/lang/Lang_DE.cpp \
	src/utils/helpers/lang/Lang_TH.cpp \
	src/utils/helpers/lang/Lang_AR.cpp \
	src/utils/managers/VMImportHandler.mm \
	src/core/SystemCore.cpp \
	src/core/VMDebugCore.cpp \
	src/core/VMDebugEngine.mm \
	src/core/AuditCore.cpp \
	src/ui/memory/VMWatchpointViewController.mm \
	src/ui/memory/VMProcessAuditViewController.mm

# 依赖框架 (已移除 AVFoundation — 音频保活由独立守护进程替换)
VansonMod_FRAMEWORKS = UIKit CoreGraphics MobileCoreServices UniformTypeIdentifiers LinkPresentation JavaScriptCore
VansonMod_CFLAGS = -fobjc-arc -I.
VansonMod_CCFLAGS = -fvisibility=hidden -fvisibility-inlines-hidden -std=c++17 -I.

# 签名权限
VansonMod_CODESIGN_FLAGS = -SVansonMod.entitlements

include $(THEOS_MAKE_PATH)/application.mk

# ============================================================
# 2. vansonmodd 守护进程 (独立于 App，开机自启)
# ============================================================
TOOL_NAME = vansonmodd

vansonmodd_FILES = \
	daemon/main.mm \
	src/api/VMHTTPServer.mm \
	src/api/VMAPIRouter.mm \
	src/memory/VMMemoryEngine.mm \
	src/memory/core/MemoryCore.cpp \
	src/memory/core/SessionCore.mm \
	src/utils/managers/VMLockManager.mm \
	src/utils/managers/VMPointerManager.mm \
	src/utils/managers/BackupCore.mm \
	src/utils/managers/PatchCore.mm \
	src/utils/managers/StorageCore.mm \
	src/utils/managers/PointerCore.mm \
	src/utils/managers/LockCore.mm \
	src/utils/models/VMPointerChain.mm \
	src/utils/models/VMRVAPatch.mm \
	src/utils/models/VMSignatureModel.mm \
	src/utils/models/VMDataSession.mm \
	src/utils/models/VMScriptModel.mm \
	src/utils/helpers/VMStoragePathHelper.mm \
	src/utils/helpers/VMLocalization.mm \
	src/utils/helpers/LocalizationCore.cpp \
	src/utils/helpers/lang/Lang_EN.cpp \
	src/core/SystemCore.cpp

# 守护进程仅需 Foundation (无 UI 框架)
vansonmodd_FRAMEWORKS = Foundation
vansonmodd_CFLAGS = -fobjc-arc -I.
vansonmodd_CCFLAGS = -fvisibility=hidden -fvisibility-inlines-hidden -std=c++17 -I.
vansonmodd_INSTALL_PATH = /usr/local/bin
vansonmodd_CODESIGN_FLAGS = -Sdaemon/daemon.entitlements

include $(THEOS_MAKE_PATH)/tool.mk

# 安装 LaunchDaemon plist → 开机自启守护进程
before-package::
	@mkdir -p $(THEOS_STAGING_DIR)/Library/LaunchDaemons
	@cp daemon/com.vanson.httpd.plist $(THEOS_STAGING_DIR)/Library/LaunchDaemons/
	@mkdir -p $(THEOS_STAGING_DIR)/var/log
	@# 包含 DEB 安装/卸载脚本
	@mkdir -p $(THEOS_STAGING_DIR)/DEBIAN
	@cp postinst $(THEOS_STAGING_DIR)/DEBIAN/postinst 2>/dev/null || true
	@cp prerm $(THEOS_STAGING_DIR)/DEBIAN/prerm 2>/dev/null || true
	@chmod +x $(THEOS_STAGING_DIR)/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/prerm 2>/dev/null || true
	@echo "✅ LaunchDaemon plist + 安装脚本 已打包"

# ============================================================
# 打包脚本
# ============================================================
after-package::
	@echo "正在收集产物到 packages/ ..."
	@mkdir -p packages
	@# 收集 DEB (Theos 可能放在根目录或 .theos 里，排除 packages 自身)
	@find . .theos -maxdepth 2 -not -path "./packages/*" -name "*.deb" -type f 2>/dev/null | while read deb; do \
		cp -v "$$deb" packages/ 2>/dev/null || true; \
	done
ifeq ($(SKIP_TIPA),1)
	@echo "跳过 TIPA..."
else
	@echo "正在处理 TIPA..."
	@rm -rf Payload
	@mkdir Payload
	@if [ -d ".theos/_/Applications/$(APPLICATION_NAME).app" ]; then \
		cp -r ".theos/_/Applications/$(APPLICATION_NAME).app" Payload/; \
	elif [ -d ".theos/obj/debug/$(APPLICATION_NAME).app" ]; then \
		cp -r ".theos/obj/debug/$(APPLICATION_NAME).app" Payload/; \
	else \
		cp -r ".theos/obj/$(APPLICATION_NAME).app" Payload/; \
	fi
	@$(eval VERSION := $(shell grep -i "Version:" control | awk '{print $$2}'))
	@echo "检测到版本号: $(VERSION)"
	@rm -f "./packages/$(APPLICATION_NAME)_v$(VERSION).tipa"
	@zip -r "./packages/$(APPLICATION_NAME)_v$(VERSION).tipa" Payload
	@rm -rf Payload
	@echo "打包完成！"
endif
	@echo ""
	@echo "===== packages/ 产物 ====="
	@ls -lh packages/
