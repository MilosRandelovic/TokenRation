# TokenRation Makefile

.PHONY: all build test format lint icon app release clean help

# The sources both format and lint operate on, named once so the two cannot drift apart.
FORMAT_PATHS = Package.swift Sources Tests

# Default target
all: build

# Build the application
build:
	swift build

# Run the test suite
test:
	swift test

# Format the sources in place
format:
	swift format --in-place --recursive $(FORMAT_PATHS)

# The check CI runs. --strict is what makes a finding fail: plain `lint` reports problems and
# still exits 0. Not every finding is fixable by `make format` — the documentation-comment
# rules need editing by hand.
lint:
	swift format lint --strict --recursive $(FORMAT_PATHS)

# Regenerate Resources/AppIcon.icns from scripts/make-icon.swift
icon:
	swift scripts/make-icon.swift

# Build TokenRation.app for local use (ad-hoc signed)
app:
	./scripts/build-app.sh

# Build a distributable release and update the Homebrew cask
release:
	./scripts/release.sh

# Clean build artifacts
clean:
	rm -rf .build TokenRation.app TokenRation.zip

# Show help
help:
	@echo "Available targets:"
	@echo "  build    - Build the application"
	@echo "  test     - Run the test suite"
	@echo "  format   - Format the sources in place"
	@echo "  lint     - Check formatting and lint rules (what CI runs)"
	@echo "  icon     - Regenerate the app icon"
	@echo "  app      - Build TokenRation.app (ad-hoc signed, local use)"
	@echo "  release  - Build a distributable release and update the cask"
	@echo "  clean    - Clean build artifacts"
	@echo "  help     - Show this help"
