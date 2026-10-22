TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CameraFlip
CameraFlip_FILES = Tweak.x
CameraFlip_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo CoreGraphics QuartzCore
CameraFlip_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 Camera"
