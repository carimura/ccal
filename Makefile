DERIVED = build.noindex
APP = $(DERIVED)/Build/Products/Release/CCal.app
XCB = xcodebuild -project CCal.xcodeproj -scheme CCal -derivedDataPath $(DERIVED) -quiet

.PHONY: project build run install test perf snapshots clean

project:
	@xcodegen generate --quiet

# Optimized build. There's one app: the copy in /Applications that `make run` installs.
build: project
	$(XCB) -configuration Release build

# Build, install to /Applications (replacing the running copy), and launch.
run: build
	@pkill -x CCal || true
	@while pgrep -x CCal >/dev/null; do sleep 0.1; done
	rm -rf /Applications/CCal.app
	cp -R $(APP) /Applications/
	open /Applications/CCal.app

install: run

# Unit + integration + offscreen rendering tests (fast; uses an in-memory calendar store).
test: project
	$(XCB) test -skip-testing:CCalTests/PerformanceTests -skip-testing:CCalTests/SnapshotTests

clean:
	rm -rf $(DERIVED) CCal.xcodeproj

# Performance tests against an optimized build (what `make install` ships).
perf: project
	$(XCB) -configuration Release ENABLE_TESTABILITY=YES test -only-testing:CCalTests/PerformanceTests

# Renders week/month/inspector screens with fake data to PNGs in ./build.noindex/snapshots.
snapshots: project
	@mkdir -p $(DERIVED)/snapshots
	TEST_RUNNER_SNAPSHOT_DIR=$(CURDIR)/$(DERIVED)/snapshots $(XCB) test -only-testing:CCalTests/SnapshotTests
	@echo "Snapshots in $(DERIVED)/snapshots"
