#include <stddef.h>
#include <stdint.h>

static int32_t g_status;

int32_t NtMapViewOfSection(void *section, void *process, void **addr, uintptr_t zero_bits, size_t commit,
                           const void *offset, size_t *size, int inherit, uint32_t alloc_type, uint32_t protect) {
    (void)process; (void)zero_bits; (void)commit; (void)offset; (void)size; (void)inherit; (void)alloc_type; (void)protect;
    *addr = section;
    return g_status;
}

int32_t NtMapViewOfSectionEx(void *section, void *process, void **addr, const void *offset, size_t *size,
                             uint32_t alloc_type, uint32_t protect, void *params, uint32_t count) {
    (void)process; (void)offset; (void)size; (void)alloc_type; (void)protect; (void)params; (void)count;
    *addr = section;
    return g_status;
}

typedef int32_t (*map_fn)(void *, void *, void **, uintptr_t, size_t, const void *, size_t *, int, uint32_t, uint32_t);
typedef int32_t (*map_ex_fn)(void *, void *, void **, const void *, size_t *, uint32_t, uint32_t, void *, uint32_t);

void *const np_syscalls[2] = { (void *)NtMapViewOfSection, (void *)NtMapViewOfSectionEx };

int32_t np_fake_map(void *base, int ex, int32_t status, void *process) {
    void *addr = NULL, *fn = *(void *const volatile *)&np_syscalls[ex ? 1 : 0];
    size_t size = 0;
    g_status = status;
    if (ex) return ((map_ex_fn)fn)(base, process, &addr, NULL, &size, 0, 0, NULL, 0);
    return ((map_fn)fn)(base, process, &addr, 0, 0, NULL, &size, 0, 0, 0);
}
