.PHONY: all build bundle test test-tsan test-scripts test-all clean

all: build

build:
	swift build

bundle:
	swift build -c release
	@mkdir -p FakeMe.app/Contents/MacOS
	@mkdir -p FakeMe.app/Contents/Resources
	@cp .build/release/FakeMe FakeMe.app/Contents/MacOS/FakeMe
	@cp Sources/FakeMeApp/Info.plist FakeMe.app/Contents/Info.plist
	@cp -f Sources/FakeMeApp/AppIcon.icns FakeMe.app/Contents/Resources/AppIcon.icns 2>/dev/null || true
	@echo 'APPL????' > FakeMe.app/Contents/PkgInfo
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f FakeMe.app
	@echo "Bundle ready: FakeMe.app"

test:
	swift test

test-tsan:
	swift test --sanitize=thread

test-scripts: build
	swift Scripts/verify_crossfade.swift
	swift Scripts/adversarial_crossfade_test.swift
	swiftc -I .build/out/Products/Debug -L .build/out/Products/Debug -lFakeMeCore Scripts/adversarial_memory_stability.swift -o /tmp/adversarial_memory_stability && /tmp/adversarial_memory_stability
	swiftc -o /tmp/stress_test_m1_bin Scripts/stress_test_m1.swift Sources/FakeMeCore/Video/*.swift -framework CoreVideo -framework CoreMedia -framework CoreImage -framework AVFoundation && /tmp/stress_test_m1_bin

test-all: test test-tsan build test-scripts
	@echo "========================================================"
	@echo "  ALL REGRESSION & ADVERSARIAL SUITES PASSED (100%)    "
	@echo "========================================================"

clean:
	swift package clean
	rm -f /tmp/stress_test_m1_bin /tmp/adversarial_crossfade_test /tmp/adversarial_memory_stability /tmp/mismatch_probe
