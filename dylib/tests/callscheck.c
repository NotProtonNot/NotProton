#include "resolver/anchor.h"
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdio.h>
#include <string.h>

static _Alignas(4096) unsigned char image[0x4000];
static int failures, cases;

static void word(size_t off, uint32_t value) {
    memcpy(image + off, &value, sizeof(value));
}

static void call(size_t off, size_t target) {
    word(off, 0x94000000u | (uint32_t)(((target - off) / 4) & 0x03FFFFFFu));
}

static void branch(size_t off, size_t target) {
    word(off, 0x14000000u | (uint32_t)(((target - off) / 4) & 0x03FFFFFFu));
}

static void starts(const char bytes[7]) {
    memcpy(image + 0x2200, bytes, 7);
}

static void reset(void) {
    memset(image, 0, sizeof(image));
    struct mach_header_64 *mh = (void *)image;
    mh->magic = MH_MAGIC_64;
    mh->ncmds = 5;
    struct segment_command_64 *text = (void *)(mh + 1);
    text->cmd = LC_SEGMENT_64;
    text->cmdsize = sizeof(*text) + 2 * sizeof(struct section_64);
    strcpy(text->segname, "__TEXT");
    text->vmsize = text->filesize = 0x2000;
    text->nsects = 2;
    struct section_64 *sections = (void *)(text + 1);
    strcpy(sections[0].segname, "__TEXT");
    strcpy(sections[0].sectname, "__text");
    sections[0].addr = 0x400;
    sections[0].size = 0x1400;
    strcpy(sections[1].segname, "__TEXT");
    strcpy(sections[1].sectname, "__stubs");
    sections[1].addr = 0x1800;
    sections[1].size = 24;
    sections[1].flags = S_SYMBOL_STUBS;
    sections[1].reserved2 = 12;
    struct segment_command_64 *le = (void *)((unsigned char *)text + text->cmdsize);
    le->cmd = LC_SEGMENT_64;
    le->cmdsize = sizeof(*le);
    strcpy(le->segname, "__LINKEDIT");
    le->vmaddr = le->fileoff = 0x2000;
    le->vmsize = le->filesize = 0x1000;
    struct symtab_command *sym = (void *)(le + 1);
    sym->cmd = LC_SYMTAB;
    sym->cmdsize = sizeof(*sym);
    sym->symoff = 0x2100;
    sym->nsyms = 2;
    sym->stroff = 0x2140;
    sym->strsize = 16;
    struct nlist_64 *symbols = (void *)(image + sym->symoff);
    symbols[0].n_un.n_strx = 1;
    symbols[1].n_un.n_strx = 8;
    memcpy(image + sym->stroff, "\0_first\0_second\0", 16);
    struct dysymtab_command *dys = (void *)(sym + 1);
    dys->cmd = LC_DYSYMTAB;
    dys->cmdsize = sizeof(*dys);
    dys->indirectsymoff = 0x2180;
    dys->nindirectsyms = 2;
    word(0x2180, 0);
    word(0x2184, 1);
    struct linkedit_data_command *fs = (void *)(dys + 1);
    fs->cmd = LC_FUNCTION_STARTS;
    fs->cmdsize = sizeof(*fs);
    fs->dataoff = 0x2200;
    fs->datasize = 7;
    starts("\x80\x08\x80\x09\x80\x07");
    mh->sizeofcmds = (uint32_t)((unsigned char *)(fs + 1) - (unsigned char *)(mh + 1));
    for (size_t off = 0x400; off < 0xc40; off += 4) word(off, 0xD503201F);
    word(0x400, 0xD10043FF);
    call(0x420, 0x1800);
    call(0x424, 0x180C);
    word(0x878, 0x910043FF);
    word(0x87C, 0xD65F03C0);
    word(0x880, 0xD10043FF);
    word(0xBF8, 0x910043FF);
    word(0xBFC, 0xD65F03C0);
}

static void second_match_at(size_t fn) {
    call(fn + 4, 0x1800);
    call(fn + 8, 0x180C);
}

static void split_prologue_at_400(void) {
    word(0x400, 0xA9BF7BFD);
    word(0x404, 0x910003FD);
    word(0x408, 0xD10083FF);
    word(0x874, 0x910083FF);
    word(0x878, 0xA8C17BFD);
}

static void check(const char *label, int exact, uintptr_t expected) {
    np_anchor_t anchor = {.kind = NP_MATCH_CALLS, .call_count = 2,
                          .calls_exact = exact, .no_data_refs = 1};
    strcpy(anchor.calls[0], "_first");
    strcpy(anchor.calls[1], "_second");
    uintptr_t base = (uintptr_t)image;
    uintptr_t got = np_locate_anchor((void *)image, (intptr_t)base, base, 0x2000, &anchor);
    if (got) got -= base;
    cases++;
    if (got == expected) return;
    failures++;
    printf("FAIL %s: expected 0x%lx, got 0x%lx\n", label,
           (unsigned long)expected, (unsigned long)got);
}

static void needle_ref_at(size_t off) {
    word(off, 0xB0000000);
    word(off + 4, 0x91240400);
}

static void four_functions(void) {
    starts("\x80\x08\x80\x09\x80\x01\x7c");
    memcpy(image + 0x1901, "needle", 7);
    word(0x880, 0xD503201F);
    word(0x900, 0xD10043FF);
    word(0x974, 0x910043FF);
    word(0x978, 0xD65F03C0);
}

static void check_string(const char *label, int hops, int tail, uintptr_t expected) {
    np_anchor_t anchor = {.kind = NP_MATCH_STRING, .caller_hops = hops, .caller_tail = tail};
    strcpy(anchor.str, "needle");
    uintptr_t base = (uintptr_t)image;
    uintptr_t got = np_locate_anchor((void *)image, (intptr_t)base, base, 0x2000, &anchor);
    if (got) got -= base;
    cases++;
    if (got == expected) return;
    failures++;
    printf("FAIL %s: expected 0x%lx, got 0x%lx\n", label,
           (unsigned long)expected, (unsigned long)got);
}

int main(void) {
    reset();
    check("exact match spanning more than 0x400 bytes", 1, 0x400);

    reset();
    word(0x804, 0x90000003);
    check("ADRP past 0x400 bytes", 1, 0);

    reset();
    call(0x804, 0x1800);
    check("extra BL past 0x400 bytes", 1, 0);

    reset();
    word(0x420, 0xD503201F);
    word(0x424, 0xD503201F);
    call(0x820, 0x1800);
    call(0x824, 0x180C);
    check("required calls past 0x400 bytes", 1, 0x400);

    reset();
    word(0x830, 0xD65F03C0);
    word(0x834, 0x90000003);
    check("ADRP after RET inside the span", 1, 0);

    reset();
    word(0x884, 0x90000003);
    check("ADRP in the next function", 1, 0x400);

    static const uint32_t indirect[] = {
        0xD63F0100, 0xD73F0909, 0xD73F0D09, 0xD63F091F, 0xD63F0D1F,
    };
    char label[64];
    for (size_t i = 0; i < sizeof(indirect) / sizeof(indirect[0]); i++) {
        reset();
        word(0x430, indirect[i]);
        snprintf(label, sizeof(label), "indirect call %08X in exact mode", indirect[i]);
        check(label, 1, 0);
        snprintf(label, sizeof(label), "indirect call %08X in subsequence mode", indirect[i]);
        check(label, 0, 0x400);
    }

    static const uint32_t not_calls[] = {
        0xD61F0100, 0xD71F0909, 0xD71F0D09, 0xD61F091F, 0xD61F0D1F,
        0xD65F0BFF, 0xD65F0FFF,
    };
    for (size_t i = 0; i < sizeof(not_calls) / sizeof(not_calls[0]); i++) {
        reset();
        word(0x430, not_calls[i]);
        snprintf(label, sizeof(label), "branch or return %08X in exact mode", not_calls[i]);
        check(label, 1, 0x400);
    }

    reset();
    call(0x430, 0x1800);
    check("repeated seed call in subsequence mode", 0, 0x400);

    reset();
    second_match_at(0x880);
    check("large match then small match", 1, 0);

    reset();
    starts("\x80\x08\x80\x01\x80\x0f");
    word(0x478, 0x910043FF);
    word(0x47C, 0xD65F03C0);
    check("small match alone", 1, 0x400);
    word(0x480, 0xD10043FF);
    second_match_at(0x480);
    check("small match then large match", 1, 0);

    reset();
    split_prologue_at_400();
    check("split prologue alone", 1, 0x400);
    second_match_at(0x880);
    check("split prologue then another match", 1, 0);

    reset();
    call(0xC10, 0x1800);
    check("caller in the unbounded last function", 1, 0);

    reset();
    starts("\x80\x08\x82\x09\x80\x07");
    check("misaligned function bounds", 1, 0);

    reset(); four_functions();
    needle_ref_at(0x888);
    check_string("string in a frameless function after a framed one", 0, 0, 0x880);

    reset(); four_functions();
    needle_ref_at(0x910);
    check_string("string in a framed function", 0, 0, 0x900);

    reset(); four_functions();
    split_prologue_at_400();
    needle_ref_at(0x500);
    check_string("string past a split prologue", 0, 0, 0x400);

    reset(); four_functions();
    needle_ref_at(0x990);
    check_string("string in the unbounded last function", 0, 0, 0);

    reset(); four_functions();
    needle_ref_at(0x910);
    call(0x88C, 0x900);
    check_string("frameless caller after a framed function", 1, 0, 0x880);

    reset(); four_functions();
    needle_ref_at(0x910);
    branch(0x88C, 0x900);
    branch(0x920, 0x900);
    check_string("frameless tail caller and a branch back to the callee entry", 1, 1, 0x880);

    reset(); four_functions();
    needle_ref_at(0x910);
    branch(0x88C, 0x900);
    branch(0x908, 0x910);
    check_string("a branch inside the function to the string load is not its tail caller", 1, 1, 0x880);

    reset(); four_functions();
    needle_ref_at(0x910);
    call(0x88C, 0x900);
    call(0x40C, 0x900);
    check_string("two callers", 1, 0, 0);

    reset(); four_functions();
    needle_ref_at(0x910);
    call(0x990, 0x900);
    check_string("caller in the unbounded last function", 1, 0, 0);

    if (failures) {
        printf("%d of %d anchor cases failed\n", failures, cases);
        return 1;
    }
    printf("==> %d anchor cases resolve as expected\n", cases);
    return 0;
}
