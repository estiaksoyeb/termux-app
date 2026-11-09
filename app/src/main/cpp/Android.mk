LOCAL_PATH:= $(call my-dir)
include $(CLEAR_VARS)
LOCAL_MODULE := libtermux-bootstrap
LOCAL_SRC_FILES := termux-bootstrap-zip.S termux-bootstrap.c
# termux-bootstrap-zip.S pulls the bootstrap ZIP in with `.incbin`, but the
# assembler's generated dependency file only lists the .S itself, so make never
# notices when the archive changes and ships stale bytes inside the APK.
# Declaring it as an additional dependency makes ndk-build rebuild when it does.
LOCAL_ADDITIONAL_DEPENDENCIES := $(LOCAL_PATH)/bootstrap-aarch64.zip
# NDK r27 defaults to 4 KB alignment; keep libs loadable on 16 KB page-size devices.
LOCAL_LDFLAGS += -Wl,-z,max-page-size=16384
include $(BUILD_SHARED_LIBRARY)
