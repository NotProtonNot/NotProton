#include "machine.h"
#include "../util/log.h"

#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>

static int sysctl_num(const char *name, int64_t *out) {
    int64_t v = 0;
    size_t len = sizeof v;
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return 0;
    // hw.* answers in whichever width the kernel keeps, so a 4-byte reply has to be read
    // as one rather than as the low half of an 8-byte value.
    if (len == sizeof(int32_t)) v = (int64_t)*(const int32_t *)&v;
    else if (len != sizeof v) return 0;
    *out = v;
    return 1;
}

static int sysctl_text(const char *name, char *buf, size_t size) {
    size_t len = size;
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0 || !len) return 0;
    buf[len < size ? len : size - 1] = '\0';
    return buf[0] != '\0';
}

// The Steam client is x86_64 and runs under Rosetta on Apple silicon, where the CPU brand
// string reads "VirtualApple" and the AVX flags are masked. The I/O registry is not
// translated, so the GPU node is what both the chip name and the core count come from.
static void gpu_from_registry(char *chip, size_t chip_size, int *cores) {
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it)
        != KERN_SUCCESS)
        return;
    for (io_object_t svc; (svc = IOIteratorNext(it)); IOObjectRelease(svc)) {
        CFTypeRef n = IORegistryEntrySearchCFProperty(
            svc, kIOServicePlane, CFSTR("gpu-core-count"), NULL,
            kIORegistryIterateRecursively | kIORegistryIterateParents);
        if (n) {
            int32_t v = 0;
            if (CFGetTypeID(n) == CFNumberGetTypeID() && CFNumberGetValue(n, kCFNumberSInt32Type, &v)
                && v > *cores)
                *cores = v;
            CFRelease(n);
        }
        if (chip[0]) continue;
        CFTypeRef m = IORegistryEntrySearchCFProperty(
            svc, kIOServicePlane, CFSTR("model"), NULL,
            kIORegistryIterateRecursively | kIORegistryIterateParents);
        if (!m) continue;
        // The property is a string on some releases and a NUL-terminated blob on others.
        if (CFGetTypeID(m) == CFStringGetTypeID()) {
            CFStringGetCString(m, chip, (CFIndex)chip_size, kCFStringEncodingUTF8);
        } else if (CFGetTypeID(m) == CFDataGetTypeID()) {
            CFIndex len = CFDataGetLength(m);
            if (len > 0) {
                if ((size_t)len > chip_size - 1) len = (CFIndex)chip_size - 1;
                CFDataGetBytes(m, CFRangeMake(0, len), (UInt8 *)chip);
                chip[len] = '\0';
            }
        }
        for (size_t i = 0; i < chip_size && chip[i]; i++)
            if ((unsigned char)chip[i] < 0x20) { chip[i] = '\0'; break; }
        CFRelease(m);
    }
    IOObjectRelease(it);
}

static void main_display(np_machine_t *m) {
    CGDirectDisplayID id = CGMainDisplayID();
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(id);
    if (!mode) return;
    m->display_w = (int)CGDisplayModeGetPixelWidth(mode);
    m->display_h = (int)CGDisplayModeGetPixelHeight(mode);
    double hz = CGDisplayModeGetRefreshRate(mode);
    // Built-in panels reported 0 before ProMotion, and a mode that says nothing is left
    // unknown rather than guessed at here.
    m->refresh_hz = hz > 0 ? (int)(hz + 0.5) : 0;
    CGDisplayModeRelease(mode);
}

static np_machine_t g_machine;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void probe(void) {
    np_machine_t m = { 0 };
    int64_t v = 0;
    // A translated process is on Apple silicon whatever the CPU it is shown.
    if ((sysctl_num("hw.optional.arm64", &v) && v == 1)
        || (sysctl_num("sysctl.proc_translated", &v) && v == 1))
        m.apple_silicon = 1;
    gpu_from_registry(m.chip, sizeof m.chip, &m.gpu_cores);
    if (!m.chip[0]) sysctl_text("machdep.cpu.brand_string", m.chip, sizeof m.chip);
    if (sysctl_num("hw.physicalcpu", &v) && v > 0) m.cpu_cores = (int)v;
    if (sysctl_num("hw.memsize", &v) && v > 0) m.ram_gb = (unsigned)(v / (1024 * 1024 * 1024));
    char release[32];
    if (sysctl_text("kern.osproductversion", release, sizeof release)) {
        int major = 0;
        if (sscanf(release, "%d", &major) == 1 && major > 0) m.macos_major = major;
    }
    main_display(&m);
    g_machine = m;
    NP_LOG("machine: %s%s, %d GPU cores, %u GB, macOS %d, %dx%d at %d Hz",
           m.chip[0] ? m.chip : "unknown",
           m.apple_silicon ? "" : " (Intel)", m.gpu_cores, m.ram_gb, m.macos_major,
           m.display_w, m.display_h, m.refresh_hz);
}

const np_machine_t *np_machine(void) {
    pthread_once(&g_once, probe);
    return &g_machine;
}

void np_machine_summary(const np_machine_t *m, char *out, size_t size) {
    if (!out || !size) return;
    out[0] = '\0';
    if (!m) return;
    char cores[32] = "", ram[32] = "", panel[64] = "";
    if (m->gpu_cores > 0) snprintf(cores, sizeof cores, ", %d GPU cores", m->gpu_cores);
    if (m->ram_gb > 0) snprintf(ram, sizeof ram, ", %u GB", m->ram_gb);
    if (m->display_w > 0 && m->display_h > 0) {
        if (m->refresh_hz > 0)
            snprintf(panel, sizeof panel, ", %dx%d at %d Hz", m->display_w, m->display_h, m->refresh_hz);
        else
            snprintf(panel, sizeof panel, ", %dx%d", m->display_w, m->display_h);
    }
    snprintf(out, size, "%s%s%s%s", m->chip[0] ? m->chip : "This Mac", cores, ram, panel);
}
