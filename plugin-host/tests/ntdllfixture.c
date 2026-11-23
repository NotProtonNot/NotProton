#include <stddef.h>
#include <stdint.h>

static int32_t g_status;
uint32_t np_alloc_type, np_protect;

int32_t NtMapViewOfSection(void *section, void *process, void **addr, uintptr_t zero_bits, size_t commit,
                           const void *offset, size_t *size, int inherit, uint32_t alloc_type, uint32_t protect) {
    (void)process; (void)zero_bits; (void)commit; (void)offset; (void)size; (void)inherit;
    np_alloc_type = alloc_type;
    np_protect = protect;
    *addr = section;
    return g_status;
}

int32_t NtMapViewOfSectionEx(void *section, void *process, void **addr, const void *offset, size_t *size,
                             uint32_t alloc_type, uint32_t protect, void *params, uint32_t count) {
    (void)process; (void)offset; (void)size; (void)params; (void)count;
    np_alloc_type = alloc_type;
    np_protect = protect;
    *addr = section;
    return g_status;
}

#if defined(__arm64__)
int32_t wrap_NtMapViewOfSection(void);
__asm__(".private_extern _wrap_NtMapViewOfSection\n"
        ".p2align 2\n"
        "_wrap_NtMapViewOfSection:\n\t"
        "ldr w8, [sp, #8]\n\t"
        "str w8, [sp, #4]\n\t"
        "b _NtMapViewOfSection\n");
#define NP_MAP wrap_NtMapViewOfSection
#else
#define NP_MAP NtMapViewOfSection
#endif

typedef int32_t (*map_fn)(void *, void *, void **, uintptr_t, size_t, const void *, size_t *, int, uint64_t, uint64_t);
typedef int32_t (*map_ex_fn)(void *, void *, void **, const void *, size_t *, uint32_t, uint32_t, void *, uint32_t);

void *const np_syscalls[2] = { (void *)NP_MAP, (void *)NtMapViewOfSectionEx };

int32_t np_fake_map(void *base, int ex, int32_t status, void *process) {
    void *addr = NULL, *fn = *(void *const volatile *)&np_syscalls[ex ? 1 : 0];
    size_t size = 0;
    g_status = status;
    np_alloc_type = np_protect = 0;
    if (ex) return ((map_ex_fn)fn)(base, process, &addr, NULL, &size, 0x2000, 0x40, NULL, 0);
    return ((map_fn)fn)(base, process, &addr, 0, 0, NULL, &size, 0, 0x2000, 0x40);
}
