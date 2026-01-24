.PHONY: lint test build ci

lint:
	swiftlint lint --strict TVECore/Sources AnimiApp

test:
	cd TVECore && swift test

build:
	xcodebuild build \
		-project AnimiApp/AnimiApp.xcodeproj \
		-scheme AnimiApp \
		-destination 'generic/platform=iOS Simulator' \
		-configuration Debug \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO

ci:
	@set -e; \
	$(MAKE) lint; \
	$(MAKE) test; \
	$(MAKE) build; \
	echo "CI passed"
