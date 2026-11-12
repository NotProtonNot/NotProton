CC ?= clang
MIN_VER ?= 15.0
OUT ?= ../../out/libfpslimit.dylib

all: $(OUT)

$(OUT): fpslimit.m
	@mkdir -p $(dir $(OUT))
	$(CC) -arch arm64 -arch x86_64 \
		-mmacosx-version-min=$(MIN_VER) \
		-dynamiclib -O2 -Wall -Wextra \
		-framework Metal -framework QuartzCore -framework Foundation \
		-install_name @rpath/libfpslimit.dylib \
		-o $(OUT) fpslimit.m
	codesign -fs - $(OUT)
	@echo "==> Built universal $(OUT)"

clean:
	rm -f $(OUT)

.PHONY: all clean
