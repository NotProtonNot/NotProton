// arm64 instruction decoders
#ifndef NOTPROTON_UTIL_A64_H
#define NOTPROTON_UTIL_A64_H

#include <stdint.h>

#define A64_SP  31u

// LDR Wt/Xt,[Xn,#imm], unsigned offset, scaled to bytes.
static inline int a64_ldr_uimm(uint32_t w, int wide, uint32_t *rn, uint32_t *rt,
                               uint32_t *off) {
    uint32_t op = wide ? 0xF9400000u : 0xB9400000u;
    if ((w & 0xFFC00000u) != op) return 0;
    *rt  = w & 0x1Fu;
    *rn  = (w >> 5) & 0x1Fu;
    *off = ((w >> 10) & 0xFFFu) * (wide ? 8u : 4u);
    return 1;
}

// ADD Xd,Xn,#imm without the 12-bit shift.
static inline int a64_add_imm(uint32_t w, uint32_t *rd, uint32_t *rn, uint32_t *imm) {
    if ((w & 0xFFC00000u) != 0x91000000u) return 0;
    *rd  = w & 0x1Fu;
    *rn  = (w >> 5) & 0x1Fu;
    *imm = (w >> 10) & 0xFFFu;
    return 1;
}

// ADD Xd,Xn,Xm,LSL #imm.
static inline int a64_add_lsl(uint32_t w, uint32_t *rd, uint32_t *rn, uint32_t *shift) {
    if ((w & 0xFFE00000u) != 0x8B000000u) return 0;
    *rd    = w & 0x1Fu;
    *rn    = (w >> 5) & 0x1Fu;
    *shift = (w >> 10) & 0x3Fu;
    return 1;
}

static inline int a64_bl(uintptr_t pc, uint32_t w, uintptr_t *target) {
    if ((w & 0xFC000000u) != 0x94000000u) return 0;
    // Sign-extend 26 bits without signed left-shift overflow.
    int64_t imm = (int64_t)((w & 0x03FFFFFFu) ^ 0x2000000u) - 0x2000000;
    *target = pc + (uintptr_t)(imm * 4);
    return 1;
}

#endif // NOTPROTON_UTIL_A64_H
