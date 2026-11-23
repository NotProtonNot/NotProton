// Entry shim for the aarch64/FEX build_module steamclient detour

    .text
    .globl shim_entry64

    .set S_X18,  0x90
    .set S_NZCV, 0x98
    .set S_X30,  0xa0
    .set S_CTX,  0xb0
    .set FRAME,  0xd0

// This was unpleasant
shim_entry64:
    sub     sp, sp, #FRAME
    stp     x0, x1, [sp, #0x00]
    stp     x2, x3, [sp, #0x10]
    stp     x4, x5, [sp, #0x20]
    stp     x6, x7, [sp, #0x30]
    stp     x8, x9, [sp, #0x40]
    stp     x10, x11, [sp, #0x50]
    stp     x12, x13, [sp, #0x60]
    stp     x14, x15, [sp, #0x70]
    stp     x16, x17, [sp, #0x80]
    mrs     x1, nzcv
    stp     x18, x1, [sp, #S_X18]
    str     x30, [sp, #S_X30]

    /* ctx table {get_dll_handle, load_dll, protect, query} */
    adrp    x8, LDR_GETDLLHANDLE
    add     x8, x8, :lo12:LDR_GETDLLHANDLE
    adrp    x9, LDR_LOADDLL
    add     x9, x9, :lo12:LDR_LOADDLL
    stp     x8, x9, [sp, #S_CTX]
    adrp    x8, NT_PROTECT
    add     x8, x8, :lo12:NT_PROTECT
    adrp    x9, NT_QUERY
    add     x9, x9, :lo12:NT_QUERY
    stp     x8, x9, [sp, #(S_CTX + 16)]

    add     x0, sp, #S_CTX
    ldr     x1, [sp, #0x00]
    adrp    x9, BM_RESUME_1
    add     x9, x9, :lo12:BM_RESUME_1
    cmp     x30, x9
    b.ne    1f
    ldur    x2, [x29, #LOAD_PATH_1]
    mov     w3, #1
    b       2f
1:  ldur    x2, [x29, #LOAD_PATH_2]
    mov     w3, #2
2:  bl      detour_build_module

    ldr     x30, [sp, #S_X30]
    ldp     x18, x1, [sp, #S_X18]
    msr     nzcv, x1
    ldp     x16, x17, [sp, #0x80]
    ldp     x14, x15, [sp, #0x70]
    ldp     x12, x13, [sp, #0x60]
    ldp     x10, x11, [sp, #0x50]
    ldp     x8, x9, [sp, #0x40]
    ldp     x6, x7, [sp, #0x30]
    ldp     x4, x5, [sp, #0x20]
    ldp     x2, x3, [sp, #0x10]
    ldp     x0, x1, [sp, #0x00]
    add     sp, sp, #FRAME
    ret
