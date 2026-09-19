.PHONY: test build app fixtures run clean

test:
	swift test

build:
	swift build

run: build
	.build/debug/SonosDrop

fixtures:
	scripts/make-fixtures.sh

app:
	scripts/bundle.sh

clean:
	rm -rf .build build
