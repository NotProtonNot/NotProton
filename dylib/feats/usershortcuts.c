// Non-Steam shortcuts
#include "usershortcuts.h"
#include "../core/macho.h"
#include "../resolver/anchor.h"
#include "../util/a64.h"
#include "../util/log.h"
#include "../util/ptr.h"

#include <mach/mach.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>
#include <strings.h>

#define SHORTCUTS_TYPE  "14CUserShortcuts"

#define USER_SCAN_SPAN  0x10000
#define SCAN_CHUNK      0x1000

// CUtlRBTree node links, -1 for none.
#define NODE_LEFT_OFF   0
#define NODE_RIGHT_OFF  4
#define NODE_NONE       (-1)
#define TREE_DEPTH_MAX  64

// Set on every shortcut appid.
#define SHORTCUT_APPID_BIT  0x80000000u

#define SHORTCUT_SPAN  0x100

#define PROBE_SPAN   0x180
#define NOTIFY_SPAN  0x40
#define NO_REG       32
#define MOV_W0_1     0x52800020u

typedef struct {
    uint32_t root;
    uint32_t nodes;
    uint32_t stride;
    uint32_t key;
    uint32_t value;
    uint32_t exe;
    uint32_t remote;
} layout_t;

static layout_t g_layout;
static int g_have_layout;
static uintptr_t g_vptr;
static _Atomic uint32_t g_shortcuts_off;
static _Atomic uintptr_t g_scan_missed;  // CUser the last scan came up empty on

// Whether a shortcut belongs to Steam Remote Play is the first field the
// "shortcut changed" event at the end of SetShortcutExe reads.
static int probe_remote(uintptr_t notify, uint32_t *off) {
    for (uintptr_t pc = notify; pc < notify + NOTIFY_SPAN; pc += 4) {
        uint32_t rn, rt;
        if (a64_ldr_uimm(*(const uint32_t *)pc, 1, &rn, &rt, off) && rn == 1) return 1;
    }
    return 0;
}

static int probe_layout(uintptr_t set_shortcut_exe, uintptr_t text, size_t text_sz) {
    if (!set_shortcut_exe) return 0;

    layout_t l = {0};
    uint32_t nodes_reg = NO_REG, node_reg = NO_REG, value_reg = NO_REG;
    int have_root = 0, have_key = 0, have_exe = 0;
    uintptr_t last_bl = 0, notify = 0;

    for (uintptr_t pc = set_shortcut_exe; pc < set_shortcut_exe + PROBE_SPAN; pc += 4) {
        uint32_t w = *(const uint32_t *)pc, rd, rn, rt, imm;

        if (!have_root && a64_ldr_uimm(w, 0, &rn, &rt, &imm) && rn == 0) {
            l.root = imm;
            have_root = 1;
        } else if (nodes_reg == NO_REG && a64_ldr_uimm(w, 1, &rn, &rt, &imm) && rn == 0) {
            l.nodes = imm;
            nodes_reg = rt;
        } else if (node_reg == NO_REG && nodes_reg != NO_REG &&
                   a64_add_lsl(w, &rd, &rn, &imm) && rn == nodes_reg) {
            l.stride = imm < 32 ? 1u << imm : 0;
            node_reg = rd;
        } else if (node_reg != NO_REG && !have_key &&
                   a64_ldr_uimm(w, 0, &rn, &rt, &imm) && rn == node_reg) {
            l.key = imm;
            have_key = 1;
        } else if (node_reg != NO_REG && value_reg == NO_REG &&
                   a64_ldr_uimm(w, 1, &rn, &rt, &imm) && rn == node_reg) {
            l.value = imm;
            value_reg = rt;
        } else if (value_reg != NO_REG && !have_exe &&
                   a64_add_imm(w, &rd, &rn, &imm) && rd == 0 && rn == value_reg) {
            l.exe = imm;
            have_exe = 1;
        } else if (have_exe && w == MOV_W0_1) {
            notify = last_bl;
            break;
        } else if (have_exe) {
            a64_bl(pc, w, &last_bl);
        }
    }

    if (notify < text || notify + NOTIFY_SPAN > text + text_sz)
        notify = 0;
    if (!have_root || !have_key || !have_exe || !notify || !probe_remote(notify, &l.remote)) {
        NP_WARN("np_usershortcuts_bind: 0x%lx does not read like SetShortcutExe "
                "(root %d key %d exe %d notify 0x%lx)", (unsigned long)set_shortcut_exe,
                have_root, have_key, have_exe, (unsigned long)notify);
        return 0;
    }
    if (l.stride < 16 || l.stride > 64 || l.key + 4 > l.stride || l.value + 8 > l.stride) {
        NP_ERR("np_usershortcuts_bind: node stride %u key 0x%x value 0x%x do not fit "
               "a tree node", l.stride, l.key, l.value);
        return 0;
    }
    if (l.exe + 8 > SHORTCUT_SPAN || l.remote + 8 > SHORTCUT_SPAN) {
        NP_ERR("np_usershortcuts_bind: exe 0x%x remote 0x%x lie past a shortcut",
               l.exe, l.remote);
        return 0;
    }

    g_layout = l;
    g_have_layout = 1;
    NP_LOG("np_usershortcuts_bind: root 0x%x nodes 0x%x stride %u key 0x%x value 0x%x "
           "exe 0x%x remote 0x%x", l.root, l.nodes, l.stride, l.key, l.value, l.exe, l.remote);
    return 1;
}

int np_usershortcuts_bind(const struct mach_header_64 *mh, intptr_t slide,
                          uintptr_t set_shortcut_exe) {
    uintptr_t text = 0;
    size_t text_sz = 0;
    if (mh && set_shortcut_exe &&
        np_get_section_containing(mh, slide, set_shortcut_exe, &text, &text_sz) == 0)
        g_vptr = np_rtti_vptr(mh, slide, text, text_sz, SHORTCUTS_TYPE);
    if (!g_vptr)
        NP_WARN("np_usershortcuts_bind: no %s vtable", SHORTCUTS_TYPE);

    return probe_layout(set_shortcut_exe, text, text_sz) && g_vptr;
}

// The scan runs past the end of CUser, so a plain load could crash.
static uint32_t find_shortcuts_off(uintptr_t user) {
    uint8_t chunk[SCAN_CHUNK];
    for (uint32_t base = 0; base < USER_SCAN_SPAN; base += SCAN_CHUNK) {
        vm_size_t got = 0;
        if (vm_read_overwrite(mach_task_self(), (vm_address_t)(user + base), SCAN_CHUNK,
                              (vm_address_t)chunk, &got) != KERN_SUCCESS)
            return 0;
        for (uint32_t i = 0; i + sizeof(uintptr_t) <= got; i += sizeof(uintptr_t)) {
            uintptr_t v;
            memcpy(&v, chunk + i, sizeof(v));
            if (v == g_vptr) return base + i;
        }
    }
    return 0;
}

static const uint8_t *user_shortcuts(const void *user) {
    if (!np_plausible_ptr((uint64_t)(uintptr_t)user)) return NULL;

    uint32_t off = atomic_load(&g_shortcuts_off);
    if (!off) {
        if (atomic_load(&g_scan_missed) == (uintptr_t)user) return NULL;
        off = find_shortcuts_off((uintptr_t)user);
        if (!off) {
            atomic_store(&g_scan_missed, (uintptr_t)user);
            NP_ERR("np_usershortcuts_runs_exe: no CUserShortcuts within 0x%x of CUser %p; "
                   "Windows shortcuts keep no default tool", USER_SCAN_SPAN, user);
            return NULL;
        }
        atomic_store(&g_shortcuts_off, off);
        NP_LOG("np_usershortcuts_runs_exe: CUserShortcuts at CUser+0x%x", off);
    }

    const uint8_t *shortcuts = (const uint8_t *)user + off;
    if (*(const uintptr_t *)shortcuts != g_vptr) return NULL;
    return shortcuts;
}

static void bad_table(const char *what, uint64_t v) {
    static const char once = 0;
    if (np_log_first_hit(&once, 0))
        NP_ERR("np_usershortcuts_runs_exe: %s 0x%llx is not one this reads; "
               "Windows shortcuts keep no default tool", what, (unsigned long long)v);
}

static const uint8_t *find_shortcut(const uint8_t *shortcuts, uint32_t appid) {
    const uint8_t *nodes = *(const uint8_t *const *)(shortcuts + g_layout.nodes);
    if (!np_plausible_ptr((uint64_t)(uintptr_t)nodes)) {
        bad_table("node array", (uint64_t)(uintptr_t)nodes);
        return NULL;
    }

    int32_t i = *(const int32_t *)(shortcuts + g_layout.root);
    for (int depth = 0; i != NODE_NONE; depth++) {
        if (i < 0 || depth == TREE_DEPTH_MAX) {
            bad_table("node index", (uint32_t)i);
            return NULL;
        }
        const uint8_t *node = nodes + (size_t)i * g_layout.stride;
        uint32_t key = *(const uint32_t *)(node + g_layout.key);
        if (key == appid) {
            uint64_t shortcut = *(const uint64_t *)(node + g_layout.value);
            if (np_plausible_ptr(shortcut)) return (const uint8_t *)(uintptr_t)shortcut;
            bad_table("shortcut", shortcut);
            return NULL;
        }
        i = *(const int32_t *)(node + (key > appid ? NODE_LEFT_OFF : NODE_RIGHT_OFF));
    }
    return NULL;
}

bool np_usershortcuts_runs_exe(const void *user, uint32_t appid) {
    if (!(appid & SHORTCUT_APPID_BIT) || !g_have_layout || !g_vptr)
        return false;

    const uint8_t *shortcuts = user_shortcuts(user);
    if (!shortcuts) return false;

    const uint8_t *shortcut = find_shortcut(shortcuts, appid);
    if (!shortcut) return false;

    if (*(const uint64_t *)(shortcut + g_layout.remote) != 0) return false;

    const char *exe = *(const char *const *)(shortcut + g_layout.exe);
    if (!exe) return false;
    if (!np_plausible_addr((uint64_t)(uintptr_t)exe)) {
        bad_table("exe string", (uint64_t)(uintptr_t)exe);
        return false;
    }
    if (!*exe) return false;

    // Steam quotes a path picked with Browse.
    const char *dot = strrchr(exe, '.');
    return dot && (strcasecmp(dot + 1, "exe") == 0 || strcasecmp(dot + 1, "exe\"") == 0);
}
