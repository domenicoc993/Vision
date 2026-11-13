.PHONY: all app debug run install clean icon

all: app

app:
	@./scripts/build_app.sh --release

debug:
	@./scripts/build_app.sh --debug

run:
	@./scripts/build_app.sh --release --run

install:
	@./scripts/build_app.sh --release --install

icon:
	@swift scripts/generate_icon.swift
	@iconutil -c icns Resources/Vision.iconset -o Resources/AppIcon.icns

clean:
	@rm -rf .build build Vision.app
	@echo "Clean completato."
