#if defined(__x86_64__)
__attribute__((naked)) unsigned np_fixture_value(void) {
    __asm__(".byte 0xb8, 0x34, 0x12, 0x5a, 0x5a, 0xc3");
}
__attribute__((naked)) unsigned np_fixture_patched(void) {
    __asm__(".byte 0xb8, 0x78, 0x56, 0x5a, 0x5a, 0xc3");
}
#else
unsigned np_fixture_value(void) { return 0x5a5a1234; }
unsigned np_fixture_patched(void) { return 0x5a5a5678; }
#endif

__attribute__((used, noinline)) static unsigned fixture_hidden(void) { return 0x77; }

unsigned (*const np_fixture_ro[1])(void) = { np_fixture_value };
unsigned (*np_fixture_rw[1])(void) = { fixture_hidden };

unsigned np_fixture_call(int rw) {
    if (rw) return np_fixture_rw[0]();
    return (*(unsigned (*const volatile *)(void))&np_fixture_ro[0])();
}
