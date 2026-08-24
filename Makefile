# MicDownmix
#
# Builds without Xcode: only Command Line Tools are required. The driver is a plain C bundle built
# with clang, the app is a SwiftPM executable assembled into a .app by hand.

DRIVER_NAME  := MicDownmixDriver
DRIVER_BUNDLE := build/$(DRIVER_NAME).driver
APP_BUNDLE   := build/MicDownmix.app
HAL_DIR      := /Library/Audio/Plug-Ins/HAL

ARCHS        := -arch arm64 -arch x86_64

# Sign with Developer ID when it is available, ad-hoc otherwise, so the tree still builds on a
# machine without the certificate.
SIGN_ID      := $(shell security find-identity -v -p codesigning 2>/dev/null \
                  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
CODESIGN_ID  := $(if $(SIGN_ID),$(SIGN_ID),-)
# Notarization requires the hardened runtime and a secure timestamp.
CODESIGN_OPTS := $(if $(SIGN_ID),--options runtime --timestamp,--timestamp=none)
CFLAGS       := -Wall -Wextra -Wno-unused-parameter -O2 -fPIC $(ARCHS)
FRAMEWORKS   := -framework CoreFoundation -framework CoreAudio -framework AudioToolbox

.PHONY: all driver app icon pkg release test verify probe grid clean

all: driver app

# ---------------------------------------------------------------------------- driver

driver: $(DRIVER_BUNDLE)

$(DRIVER_BUNDLE): Driver/MicDownmixDriver.c Driver/Info.plist
	@rm -rf $(DRIVER_BUNDLE)
	@mkdir -p $(DRIVER_BUNDLE)/Contents/MacOS
	cp Driver/Info.plist $(DRIVER_BUNDLE)/Contents/Info.plist
	clang $(CFLAGS) -bundle $(FRAMEWORKS) \
		-o $(DRIVER_BUNDLE)/Contents/MacOS/$(DRIVER_NAME) Driver/MicDownmixDriver.c
	@# coreaudiod refuses to load an unsigned plug-in. An ad-hoc signature satisfies it; no
	@# Apple Developer account is needed.
	codesign --force --sign "$(CODESIGN_ID)" $(CODESIGN_OPTS) $(DRIVER_BUNDLE)
	@echo "built $(DRIVER_BUNDLE)"

# ---------------------------------------------------------------------------- app

app: $(APP_BUNDLE)

$(APP_BUNDLE): $(DRIVER_BUNDLE) $(wildcard Sources/MicDownmixApp/*.swift) $(wildcard Sources/MicDownmixCore/*.swift) Resources/App-Info.plist Resources/MicDownmix.entitlements $(wildcard Resources/MicDownmix.icns)
	@# Universal, matching the driver. Without both slices the app will not launch on an Intel Mac
	@# while the driver loads fine, which looks like a broken app rather than a missing
	@# architecture.
	@#
	@# Each slice is built separately and merged with lipo rather than using SwiftPM's --arch,
	@# which needs xcbuild from a full Xcode install. This way the project builds with Command Line
	@# Tools alone.
	swift build -c release --product MicDownmixApp --scratch-path .build-arm64 \
		-Xswiftc -target -Xswiftc arm64-apple-macos15.0
	swift build -c release --product MicDownmixApp --scratch-path .build-x86_64 \
		-Xswiftc -target -Xswiftc x86_64-apple-macos15.0
	@mkdir -p build
	lipo -create -output build/MicDownmixApp-universal \
		.build-arm64/release/MicDownmixApp .build-x86_64/release/MicDownmixApp
	@# The staged bundle has been observed coming back root-owned after the package is installed,
	@# which makes the next build fail on rm with a wall of Permission denied. Escalate only when
	@# that has actually happened, so a normal build never prompts.
	@if [ -d "$(APP_BUNDLE)" ] && [ ! -w "$(APP_BUNDLE)/Contents" ]; then \
		echo "note: $(APP_BUNDLE) is not writable; removing it needs your password"; \
		osascript -e "do shell script \"rm -rf '$(PWD)/$(APP_BUNDLE)'\" with administrator privileges"; \
	fi
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp Resources/App-Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@# The icon is optional so the tree still builds without artwork present.
	@if [ -f Resources/MicDownmix.icns ]; then \
		cp Resources/MicDownmix.icns $(APP_BUNDLE)/Contents/Resources/; \
	else \
		echo "note: Resources/MicDownmix.icns missing; app will use the generic icon"; \
	fi
	cp build/MicDownmixApp-universal $(APP_BUNDLE)/Contents/MacOS/MicDownmix
	@# The driver rides inside the app, so there is never a second thing to download and the app
	@# can install it itself behind one authorisation prompt.
	cp -R $(DRIVER_BUNDLE) $(APP_BUNDLE)/Contents/Resources/
	@# Shipped inside the bundle so a complete uninstall is always available, including to someone
	@# who never cloned the repo.
	cp Scripts/uninstall.sh $(APP_BUNDLE)/Contents/Resources/
	@# The nested driver is signed first; codesign seals inside out.
	codesign --force --sign "$(CODESIGN_ID)" $(CODESIGN_OPTS) $(APP_BUNDLE)/Contents/Resources/MicDownmixDriver.driver
	codesign --force --sign "$(CODESIGN_ID)" $(CODESIGN_OPTS) \
		--entitlements Resources/MicDownmix.entitlements $(APP_BUNDLE)
	@echo "signed with: $(CODESIGN_ID)"
	@echo "built $(APP_BUNDLE)"

# ---------------------------------------------------------------------------- test

pkg: app
	./Scripts/make-pkg.sh

# Regenerate the app icon from a square PNG: make icon SRC=path/to/icon.png
icon:
	./Scripts/make-icon.sh $(SRC)

release: 
	./Scripts/release.sh

test:
	swift run MicDownmixTests

# End-to-end check against the installed device. Needs the driver installed and the app running.
verify:
	swift run MicDownmixVerify $(SECONDS_ARG)

# Measures every channel of the source interface, to find which one carries the voice.
probe:
	swift run MicDownmixProbe $(SECONDS_ARG)

# Reports which integer grid the virtual device's samples land on.
grid:
	swift run MicDownmixGrid

# ---------------------------------------------------------------------------- install



clean:
	rm -rf build .build .build-arm64 .build-x86_64
