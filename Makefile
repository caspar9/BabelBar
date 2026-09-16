APP_NAME   := BabelBar
DIST       := dist
APP        := $(DIST)/$(APP_NAME).app
BINARY     := .build/release/$(APP_NAME)
SIGN_ID    := -
VERSION    := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
DMG        := $(DIST)/$(APP_NAME)-$(VERSION).dmg
DMG_STAGE  := $(DIST)/dmg-stage

.PHONY: build compile run install dmg clean

# `build` produces a signed .app bundle in dist/
build: compile
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BINARY)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
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
