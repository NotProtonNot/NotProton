/* x86_64 ntdll.dll cave layout, link time only */
SECTIONS {
  . = CAVE_VA;
  .cave CAVE_VA : {
    shim.o(.text)
    *(.text .text.*)
    . = ALIGN(16);
    *(.rdata .rdata.* .rodata .rodata.*)
  }
  /DISCARD/ : { *(.pdata) *(.xdata) *(.bss) *(.data) *(.comment) *(.note.*) }
}
