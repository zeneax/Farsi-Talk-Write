# FarsiTalkWrite build
#
# SwiftPM is deliberately not used. This project has no external dependencies, and
# the Command Line Tools install this was developed against had a broken
# libPackageDescription, so swiftc is driven directly. That also gives us exact
# control over the .app bundle layout and signing, which TCC is sensitive to.

APP_NAME    := FarsiTalkWrite
BUNDLE_ID   := com.shahram.farsitalkwrite
BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
MACOS_DIR   := $(APP_BUNDLE)/Contents/MacOS
RES_DIR     := $(APP_BUNDLE)/Contents/Resources
BINARY      := $(MACOS_DIR)/$(APP_NAME)
INSTALL_DIR := /Applications

SOURCES     := $(shell find Sources -name '*.swift')
SDK         := $(shell xcrun --show-sdk-path)
TARGET      := arm64-apple-macos14.0

# TCC ties Input Monitoring and Accessibility grants to the code signature.
# Ad-hoc signing ("-") changes the hash on every build, so those permissions must
# be re-granted after each rebuild. Create a self-signed Code Signing certificate
# in Keychain Access named "FarsiTalkWrite Dev" and the grants survive rebuilds:
#     make SIGN_ID="FarsiTalkWrite Dev"
# Auto-detect the stable self-signed identity. TCC grants and Keychain ACLs are
# bound to the code signature, so ad-hoc signing ("-") invalidates them on every
# rebuild — which shows up as permission dialogs and repeated "wants to use your
# confidential information" prompts. Falls back to ad-hoc if the cert is absent.
#
# Recreate it with:  make signing-cert
SIGN_ID     ?= $(shell security find-certificate -c "FarsiTalkWrite Dev" >/dev/null 2>&1 \
                 && echo "FarsiTalkWrite Dev" || echo "-")

SWIFTC_FLAGS := -O -target $(TARGET) -sdk $(SDK) \
                -framework AppKit -framework AVFoundation \
                -framework CoreAudio -framework AudioToolbox \
                -framework CoreGraphics -framework Carbon \
                -framework IOKit -framework Security

# ---------------------------------------------------------------------------
# Universal (Intel + Apple Silicon) build for distribution to other Macs.
#
# Entirely separate from the normal build: different output directory, different
# deployment target, no effect on `make`, `make install`, or /Applications.
#
# macOS 12 is the floor because that is the newest release 2015 Macs can run;
# a lower floor still runs on newer systems, it just cannot use newer APIs.
# The source compiles unmodified at this target.
# ---------------------------------------------------------------------------
UNIVERSAL_DIR     := $(BUILD_DIR)/universal
UNIVERSAL_APP     := $(UNIVERSAL_DIR)/$(APP_NAME).app
UNIVERSAL_DEPLOY  := 12.0

.PHONY: all build bundle sign install clean run check doctor icon signing-cert universal

# Creates the stable self-signed code-signing identity used by `sign`. Run once.
# macOS Security cannot read OpenSSL 3's default PKCS#12 encryption, hence the
# explicit legacy algorithms.
signing-cert:
	@security find-certificate -c "FarsiTalkWrite Dev" >/dev/null 2>&1 \
		&& echo "Certificate already exists." && exit 0 || true
	@TMP=$$(mktemp -d); \
	openssl req -newkey rsa:2048 -nodes -keyout $$TMP/key.pem -x509 -days 3650 \
		-out $$TMP/cert.pem -subj "/CN=FarsiTalkWrite Dev/O=FarsiTalkWrite/C=US" \
		-addext "extendedKeyUsage=codeSigning" \
		-addext "basicConstraints=critical,CA:false" \
		-addext "keyUsage=critical,digitalSignature" 2>/dev/null; \
	openssl pkcs12 -export -inkey $$TMP/key.pem -in $$TMP/cert.pem -out $$TMP/b.p12 \
		-passout pass:ftw -name "FarsiTalkWrite Dev" \
		-macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES 2>/dev/null; \
	security import $$TMP/b.p12 -k ~/Library/Keychains/login.keychain-db -P ftw \
		-T /usr/bin/codesign -T /usr/bin/security; \
	rm -rf $$TMP
	@echo "Created “FarsiTalkWrite Dev”. Rebuild with: make install"


all: bundle

# Regenerates Resources/AppIcon.icns from Tools/make-icon.swift. Only needed when
# the icon design changes; the .icns is committed so a normal build does not
# depend on it.
icon:
	@swiftc -O Tools/make-icon.swift -o /tmp/ftw-make-icon
	@rm -rf /tmp/ftw-icon && /tmp/ftw-make-icon /tmp/ftw-icon
	@iconutil -c icns /tmp/ftw-icon/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "Regenerated Resources/AppIcon.icns"

build: $(BUILD_DIR)/$(APP_NAME)-bin

$(BUILD_DIR)/$(APP_NAME)-bin: $(SOURCES)
	@mkdir -p $(BUILD_DIR)
	swiftc $(SWIFTC_FLAGS) $(SOURCES) -o $@

bundle: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS_DIR) $(RES_DIR)
	@cp $(BUILD_DIR)/$(APP_NAME)-bin $(BINARY)
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(RES_DIR)/AppIcon.icns
	@printf 'APPL????' > $(APP_BUNDLE)/Contents/PkgInfo
	@$(MAKE) --no-print-directory sign
	@echo "Built $(APP_BUNDLE)"

# The hardened runtime (--options runtime) is deliberately NOT used. It requires
# every TCC-gated capability to be backed by an entitlement, and under an ad-hoc
# signature a missing one fails silently: the microphone request never reaches
# TCC, so the app does not even appear in Privacy & Security. Hardened runtime
# only matters for notarised distribution, which this local build is not.
sign:
	@codesign --force --sign "$(SIGN_ID)" \
		--identifier $(BUNDLE_ID) \
		--entitlements Resources/FarsiTalkWrite.entitlements \
		--timestamp=none \
		$(APP_BUNDLE)
	@codesign --verify --verbose=1 $(APP_BUNDLE) 2>&1 | sed 's/^/  /'
	@codesign -d --entitlements - $(APP_BUNDLE) 2>/dev/null | grep -q "audio-input" \
		&& echo "  entitlements: audio-input present" \
		|| echo "  WARNING: audio-input entitlement missing"
ifeq ($(SIGN_ID),-)
	@echo "  NOTE: ad-hoc signed. Input Monitoring and Accessibility must be"
	@echo "        re-granted after every rebuild. See SIGN_ID in the Makefile."
endif

install: bundle
	@rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"
	@echo ""
	@echo "Next:"
	@echo "  1. open $(INSTALL_DIR)/$(APP_NAME).app     (the Setup Guide opens on first run)"
	@echo "  2. Add it to System Settings -> General -> Login Items to start at login."

# Run the built binary directly, outside the bundle. Useful for the CLI
# subcommands; note that TCC-gated features want the signed bundle instead.
run: build
	@$(BUILD_DIR)/$(APP_NAME)-bin $(ARGS)

check: bundle
	@$(BINARY) --check

# Verifies the toolchain itself. This project was blocked once by a Command Line
# Tools install whose compiler and SDK came from different builds.
doctor:
	@echo "swiftc:  $$(swiftc --version 2>&1 | head -1)"
	@echo "sdk:     $(SDK)"
	@echo -n "compile test: "
	@printf 'import Foundation\nprint("ok")\n' > /tmp/ftw-doctor.swift
	@swiftc -sdk $(SDK) -target $(TARGET) /tmp/ftw-doctor.swift -o /tmp/ftw-doctor 2>/tmp/ftw-doctor.err \
		&& /tmp/ftw-doctor \
		|| (echo "FAILED"; echo; grep -m2 "error:" /tmp/ftw-doctor.err; echo; \
		    echo "The Command Line Tools install is broken. Fix with:"; \
		    echo "  sudo rm -rf /Library/Developer/CommandLineTools"; \
		    echo "  sudo xcode-select --install"; exit 1)

# Builds one .app containing both architectures. macOS selects the matching slice
# at launch — the user never chooses, and there is only ever one download.
universal:
	@rm -rf $(UNIVERSAL_DIR)
	@mkdir -p $(UNIVERSAL_DIR)/slices
	@echo "Compiling arm64 slice (macOS $(UNIVERSAL_DEPLOY)+)…"
	@swiftc -O -target arm64-apple-macos$(UNIVERSAL_DEPLOY) -sdk $(SDK) \
		-framework AppKit -framework AVFoundation -framework CoreAudio \
		-framework AudioToolbox -framework CoreGraphics -framework Carbon \
		-framework IOKit -framework Security \
		$(SOURCES) -o $(UNIVERSAL_DIR)/slices/$(APP_NAME)-arm64
	@echo "Compiling x86_64 slice (macOS $(UNIVERSAL_DEPLOY)+)…"
	@swiftc -O -target x86_64-apple-macos$(UNIVERSAL_DEPLOY) -sdk $(SDK) \
		-framework AppKit -framework AVFoundation -framework CoreAudio \
		-framework AudioToolbox -framework CoreGraphics -framework Carbon \
		-framework IOKit -framework Security \
		$(SOURCES) -o $(UNIVERSAL_DIR)/slices/$(APP_NAME)-x86_64
	@mkdir -p $(UNIVERSAL_APP)/Contents/MacOS $(UNIVERSAL_APP)/Contents/Resources
	@lipo -create \
		$(UNIVERSAL_DIR)/slices/$(APP_NAME)-arm64 \
		$(UNIVERSAL_DIR)/slices/$(APP_NAME)-x86_64 \
		-output $(UNIVERSAL_APP)/Contents/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(UNIVERSAL_APP)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(UNIVERSAL_APP)/Contents/Resources/AppIcon.icns
	@printf 'APPL????' > $(UNIVERSAL_APP)/Contents/PkgInfo
	@/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $(UNIVERSAL_DEPLOY)" \
		$(UNIVERSAL_APP)/Contents/Info.plist
	@codesign --force --sign "$(SIGN_ID)" --identifier $(BUNDLE_ID) \
		--entitlements Resources/FarsiTalkWrite.entitlements \
		--timestamp=none $(UNIVERSAL_APP)
	@rm -rf $(UNIVERSAL_DIR)/slices
	@echo ""
	@echo "Built $(UNIVERSAL_APP)"
	@lipo -info $(UNIVERSAL_APP)/Contents/MacOS/$(APP_NAME) | sed 's/^/  /'
	@echo "  minimum macOS: $(UNIVERSAL_DEPLOY)"
	@echo ""
	@echo "  This bundle is NOT installed anywhere. Copy it to the other Mac."
	@echo "  It is signed with a local certificate, so on first launch there the"
	@echo "  user must right-click the app and choose Open (once), or run:"
	@echo "    xattr -dr com.apple.quarantine /Applications/$(APP_NAME).app"

clean:
	@rm -rf $(BUILD_DIR)
	@echo "Cleaned."
