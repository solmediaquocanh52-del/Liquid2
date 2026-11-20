THEOS_PACKAGE_SCHEME ?= rootless
TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidGlassBar
LiquidGlassBar_FILES = Tweak.x
LiquidGlassBar_CFLAGS = -fobjc-arc
LiquidGlassBar_FRAMEWORKS = UIKit QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += LiquidGlassBarPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
