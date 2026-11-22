VERSION := 1.0.0

.PHONY: build install test icon release clean help

help:
	@echo "make build    编译出 ClipShelf.app"
	@echo "make install  装到 ~/Applications 并启动"
	@echo "make test     跑自检（12 项）"
	@echo "make icon     重新生成 AppIcon.icns"
	@echo "make release  打包 dist/ClipShelf-$(VERSION).zip"
	@echo "make clean    清掉构建产物"

build:
	./build.sh

install:
	./install.sh

test: build
	./ClipShelf.app/Contents/MacOS/ClipShelf --selftest

icon:
	python3 design/icon.py icns

release: build
	@mkdir -p dist
	@rm -f "dist/ClipShelf-$(VERSION).zip"
	ditto -c -k --sequesterRsrc --keepParent ClipShelf.app "dist/ClipShelf-$(VERSION).zip"
	@echo "产物：dist/ClipShelf-$(VERSION).zip"

clean:
	rm -rf ClipShelf.app build
