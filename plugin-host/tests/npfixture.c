#if defined(__x86_64__)
__attribute__((naked)) unsigned np_fixture_value(void) {
    __asm__(".byte 0xb8, 0x34, 0x12, 0x5a, 0x5a, 0xc3");
}
#else
unsigned np_fixture_value(void) { return 0x5a5a1234; }
#endif
