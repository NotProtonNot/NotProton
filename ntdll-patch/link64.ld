/* aarch64 ntdll.dll cave layout, link time only */
SECTIONS {
  . = CAVE_VA;
  .cave CAVE_VA : {
    shim64.o(.text)
    *(.text .text.*)
    . = ALIGN(8);
    *(.rodata .rodata.*)
  }
  /DISCARD/ : { *(.comment) *(.note.*) *(.llvm_addrsig) *(.eh_frame) *(.bss) *(.data) }
}
