#ifndef STEAM_HELPER_DLFCN_SHIM_H
#define STEAM_HELPER_DLFCN_SHIM_H

/* mingw has no dlfcn.h. These stubs always fail, so the OpenVR and Vulkan code in
   steam.cpp that needs them does nothing. */

#ifdef __cplusplus
extern "C" {
#endif

#define RTLD_LAZY   0x0001
#define RTLD_NOW    0x0002
#define RTLD_GLOBAL 0x0100
#define RTLD_LOCAL  0x0000

typedef struct {
    const char *dli_fname;
    void *dli_fbase;
    const char *dli_sname;
    void *dli_saddr;
} Dl_info;

static inline void *dlopen(const char *file, int mode) { (void)file; (void)mode; return 0; }
static inline int dlclose(void *handle) { (void)handle; return 0; }
static inline void *dlsym(void *handle, const char *name) { (void)handle; (void)name; return 0; }
static inline char *dlerror(void) { return 0; }
static inline int dladdr(const void *addr, Dl_info *info) { (void)addr; (void)info; return 0; }

#ifdef __cplusplus
}
#endif

#endif
