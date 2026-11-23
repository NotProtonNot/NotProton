// Entry shim for the i386 build_module steamclient detour.

    .intel_syntax noprefix
    .text
    .globl shim_entry32

shim_entry32:
    pushad                              // eax ecx edx ebx esp ebp esi edi 
    call    delta_ref                   // pushes delta_ref, the next instruction 
delta_ref:
    pop     ecx
    sub     ecx, offset delta_ref       // ecx = load base, preferred base
    mov     ebx, ebp                    // fp; ebx/esi survive the cdecl call 
    mov     esi, WM_REG                 // wm 
    mov     edi, esp                    // pre-align esp, for an exact restore 
    and     esp, -16
    sub     esp, 0x30                   // [esp+0x00..0x0B] args, [esp+0x0C..0x27] ctx 
    // ctx table: {get_dll_handle, load_dll, protect, open_file, read_file, close, delta} 
    lea     eax, [ecx + LDR_GETDLLHANDLE]
    mov     [esp+0x0C], eax
    lea     eax, [ecx + LDR_LOADDLL]
    mov     [esp+0x10], eax
    lea     eax, [ecx + NT_PROTECT]
    mov     [esp+0x14], eax
    lea     eax, [ecx + NT_OPENFILE]
    mov     [esp+0x18], eax
    lea     eax, [ecx + NT_READFILE]
    mov     [esp+0x1C], eax
    lea     eax, [ecx + NT_CLOSE]
    mov     [esp+0x20], eax
    mov     [esp+0x24], ecx
#ifdef NP_PLUGINS
    lea     eax, [ecx + NT_QUERY]
    mov     [esp+0x28], eax
#endif
    // detour_build_module32(ctx, wm, fp), cdecl 
    lea     eax, [esp+0x0C]
    mov     [esp+0x00], eax
    mov     [esp+0x04], esi
    mov     [esp+0x08], ebx
    call    _detour_build_module32
    mov     esp, edi
    popad
    .byte   STOLEN_HEAD_BYTES
#if STOLE_BRANCH
    jnz     BM_SKIP
#endif
    jmp     BM_RESUME
