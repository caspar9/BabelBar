APP_NAME   := BabelBar
DIST       := dist
APP        := $(DIST)/$(APP_NAME).app
BINARY     := .build/release/$(APP_NAME)
SIGN_ID    := -
VERSION    := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
DMG        := $(DIST)/$(APP_NAME)-$(VERSION).dmg
DMG_STAGE  := $(DIST)/dmg-stage

ICON       := Resources/AppIcon.icns
ICON_SRC   := Resources/icon/make-icon.swift
ICONSET    := $(DIST)/AppIcon.iconset

.PHONY: build compile run install dmg icon clean

# `build` produces a signed .app bundle in dist/
build: compile
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BINARY)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp "$(ICON)" "$(APP)/Contents/Resources/AppIcon.icns"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	codesign --force --deep --sign "$(SIGN_ID)" "$(APP)"
	@echo "Built $(APP)"

compile:
	swift build -c release

run: build
	open "$(APP)"

install: build
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/
	@echo "Installed to /Applications/$(APP_NAME).app"

# `icon` re-renders Resources/AppIcon.icns from the CoreGraphics script.
# The .icns is committed, so this only needs to run after editing the script.
icon:
	rm -rf "$(ICONSET)" && mkdir -p "$(ICONSET)"
	swift "$(ICON_SRC)" "$(ICONSET)/icon_512x512@2x.png"
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s "$(ICONSET)/icon_512x512@2x.png" --out "$(ICONSET)/icon_$${s}x$${s}.png" >/dev/null; \
		d=$$((s*2)); [ $$s -eq 512 ] || \
		sips -z $$d $$d "$(ICONSET)/icon_512x512@2x.png" --out "$(ICONSET)/icon_$${s}x$${s}@2x.png" >/dev/null; \
	done
	iconutil -c icns "$(ICONSET)" -o "$(ICON)"
	rm -rf "$(ICONSET)"
	@echo "Built $(ICON)"

# `dmg` wraps the .app in a compressed disk image with an /Applications
# shortcut — the standard drag-to-install layout. Uses only hdiutil.
dmg: build
	rm -rf "$(DMG_STAGE)" "$(DMG)"
	mkdir -p "$(DMG_STAGE)"
	cp -R "$(APP)" "$(DMG_STAGE)/"
	ln -s /Applications "$(DMG_STAGE)/Applications"
	hdiutil create -quiet -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGE)" \
		-ov -format UDZO "$(DMG)"
	rm -rf "$(DMG_STAGE)"
	@echo "Built $(DMG)"

clean:
	swift package clean
	rm -rf $(DIST)
