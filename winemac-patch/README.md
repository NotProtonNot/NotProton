# winemac-patch

Upstream Wine builds hide the macdrv functions DXMT's `winemetal.so` looks up with
`dlsym`, so DXMT can create a D3D11 device but no swapchain. `dxmt_export.c` exports
them as the `macdrv_functions` table DXMT checks first, translating `struct macdrv_win_data`
to the older layout DXMT expects and creating the window's client view on demand.

To rebuild `app/Sources/NotProtonApp/Resources/winemac-winehq-11.15.so`:

    tar xf wine-11.15.tar.xz && cd wine-11.15
    cp ../winemac-patch/dxmt_export.c dlls/winemac.drv/
    # add "dxmt_export.c \" to SOURCES in dlls/winemac.drv/Makefile.in
    PATH="$(brew --prefix bison)/bin:$PATH" arch -x86_64 ./configure --enable-win64 \
        --enable-archs=x86_64 --without-x --without-freetype CC="clang -arch x86_64" \
        OBJC="clang -arch x86_64"
    arch -x86_64 make dlls/winemac.drv/winemac.so
    codesign -fs - dlls/winemac.drv/winemac.so

Then update `macDriver` in `FreeEngine.swift` with its sha256.
