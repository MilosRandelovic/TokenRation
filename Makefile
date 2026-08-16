# TokenRation Makefile

.PHONY: all build test format app release clean help

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
	swift format --in-place --recursive Package.swift Sources Tests

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
	@echo "  app      - Build TokenRation.app (ad-hoc signed, local use)"
	@echo "  release  - Build a distributable release and update the cask"
	@echo "  clean    - Clean build artifacts"
	@echo "  help     - Show this help"
