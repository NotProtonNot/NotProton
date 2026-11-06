/* x86_64 winebus.sys cave layout, link time only */
SECTIONS {
  . = CAVE_VA;
  .cave : { *(.text .text.*) }
  /DISCARD/ : { *(.pdata) *(.xdata) *(.bss) *(.data) *(.rdata) *(.comment) *(.note.*) }
}
