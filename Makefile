APP_NAME   := BabelBar
DIST       := dist
APP        := $(DIST)/$(APP_NAME).app
BINARY     := .build/release/$(APP_NAME)
SIGN_ID    := -

.PHONY: build compile run install clean

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

clean:
	swift package clean
	rm -rf $(DIST)
