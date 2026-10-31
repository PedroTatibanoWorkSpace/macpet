.PHONY: build app install run clean

build:
	swift build

app:
	./scripts/build-app.sh

# Instala em /Applications e abre.
install: app
	-pkill -f "MacPet.app/Contents/MacOS/MacPet$$"
	-sleep 1
	rm -rf /Applications/MacPet.app
	cp -R dist/MacPet.app /Applications/
	open /Applications/MacPet.app

run: app
	-pkill -f "MacPet.app/Contents/MacOS/MacPet$$"
	-sleep 1
	open dist/MacPet.app

clean:
	rm -rf .build dist
