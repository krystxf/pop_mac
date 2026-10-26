.PHONY: build test lint format app run install clean

build:
	swift build

test:
	swift test

lint:
	swiftformat --lint .

format:
	swiftformat .

app:
	./scripts/bundle.sh

run: app
	open build/PopMac.app

install: app
	rm -rf ~/Applications/PopMac.app
	mkdir -p ~/Applications
	cp -R build/PopMac.app ~/Applications/
	@echo "Installed to ~/Applications/PopMac.app"

clean:
	rm -rf .build build
