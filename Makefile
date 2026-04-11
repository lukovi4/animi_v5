.PHONY: lint verify test-core app-test test build ci

lint:
	swiftlint lint --strict TVECore/Sources AnimiApp

verify:
	Scripts/verify_module_boundary.sh

test-core:
	cd TVECore && swift test

app-test:
	Scripts/run_animiapp_tests.sh

test: verify test-core app-test

build:
	xcodebuild build \
		-project AnimiApp/AnimiApp.xcodeproj \
		-scheme AnimiApp \
		-destination "$$(Scripts/run_animiapp_tests.sh --print-destination)" \
		-configuration Debug \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO

ci:
	@set -e; \
	$(MAKE) lint; \
	$(MAKE) verify; \
	$(MAKE) test-core; \
	$(MAKE) app-test; \
	$(MAKE) build; \
	echo "CI passed"
