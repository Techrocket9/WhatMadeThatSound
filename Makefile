# What Made That Sound — build, test, install.
#
#   make            build build/What Made That Sound.app (release, ad-hoc signed)
#   make test       run the unit and Core Audio integration tests
#   make install    copy the app to /Applications and open it (it enables recording on first launch)
#   make uninstall  turn off background recording and remove the app (history is kept)
#
# Set SIGN_IDENTITY="Developer ID Application: …" to sign with a real identity.

APP_NAME    := What Made That Sound
BUILD_APP   := build/$(APP_NAME).app
INSTALL_DIR ?= /Applications
INSTALLED   := $(INSTALL_DIR)/$(APP_NAME).app

.PHONY: all build test install uninstall status clean

all: build

build:
	./scripts/build-app.sh

test:
	swift test --package-path Packages/WhatMadeThatSoundKit

# The build copy is removed after installing: with ad-hoc signing, a second copy
# of the app with the same bundle identifier can take over the agent's
# registration. Opening the new copy re-registers the agent for its binary.
install: build
	@# Quit a running viewer so the new version is what opens (the agent keeps running).
	-@pkill -f "$(INSTALLED)/Contents/MacOS/$(APP_NAME)" && sleep 1
	@if [ -d "$(INSTALLED)" ]; then rm -rf "$(INSTALLED)"; fi
	ditto "$(BUILD_APP)" "$(INSTALLED)"
	rm -rf "$(BUILD_APP)"
	open "$(INSTALLED)"

uninstall:
	@if [ -x "$(INSTALLED)/Contents/MacOS/$(APP_NAME)" ]; then \
		"$(INSTALLED)/Contents/MacOS/$(APP_NAME)" --unregister-agent; \
	fi
	rm -rf "$(INSTALLED)"
	@echo "Removed $(INSTALLED). Recorded history remains in ~/Library/Application Support/WhatMadeThatSound"

status:
	@"$(INSTALLED)/Contents/MacOS/$(APP_NAME)" --agent-status
	@"$(INSTALLED)/Contents/MacOS/WhatMadeThatSoundAgent" status

clean:
	rm -rf build .build Packages/WhatMadeThatSoundKit/.build
