TUIST ?= tuist
DERIVED_DATA ?= ./.derivedData
WORKSPACE := CodexSessions.xcworkspace
SCHEME := CodexSessions

.PHONY: generate open build run clean

generate:
	$(TUIST) generate

open: generate
	open $(WORKSPACE)

build: generate
	xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) -configuration Debug -destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) build

run: build
	open -n $(DERIVED_DATA)/Build/Products/Debug/$(SCHEME).app

clean:
	rm -rf $(DERIVED_DATA)
