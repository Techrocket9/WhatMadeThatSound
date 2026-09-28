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
AGENT_LABEL := com.matthewy.WhatMadeThatSound.Agent

.PHONY: all build test install uninstall status clean

all: build

build:
	./scripts/build-app.sh

test:
	swift test --package-path Packages/WhatMadeThatSoundKit

install: build
	@if [ -d "$(INSTALLED)" ]; then rm -rf "$(INSTALLED)"; fi
	ditto "$(BUILD_APP)" "$(INSTALLED)"
	@# If an older copy's agent is running, restart it from the new binary.
	-launchctl kickstart -k "gui/$$(id -u)/$(AGENT_LABEL)" 2>/dev/null
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
