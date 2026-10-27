.PHONY: build test e2e lint format app run install prod clean

build:
	swift build

test:
	swift test

# Runs Pop Mac against real windows. Quit Pop Mac first.
e2e:
	swift build --build-tests
	POP_MAC_E2E=1 swift test --skip-build --filter PopE2ETests

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

prod:
	./scripts/install-prod.sh

clean:
	rm -rf .build build
