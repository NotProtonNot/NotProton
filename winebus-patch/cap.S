/* Caps the input reports winebus.sys queues for a HID device.
 *
 * process_hid_report, inlined into bus_main_thread, appends every input report to
 * ext->reports and nothing ever drops one, so a reader slower than the device queues
 * them without bound. Steam's virtual gamepad sends a report for every stick jitter,
 * about 830 a second, and under Rosetta winedevice.exe falls behind it within minutes,
 * which shows up as input lag that keeps growing until Steam stops sending.
 *
 * Right after the append, process_hid_report calls memcpy to refresh last_reports. That
 * call is pointed here instead. With ext->cs still held, drop the oldest reports until
 * MAX_QUEUED remain, like the native HID class ring buffer, then carry on into memcpy
 * with its arguments untouched.
 *
 * At the hook: EXT_REG = struct device_extension *, a callee-saved register that
 * differs between builds, and rcx/rdx/r8 = memcpy's arguments.
 */
	.intel_syntax noprefix
	.text
	.globl cap_reports
cap_reports:
	push	rcx
	push	rdx
	push	r8
	sub	rsp, 0x20		/* shadow space, leaves rsp 16 byte aligned */
1:
	lea	r10, [EXT_REG + REPORTS_OFFSET]	/* &ext->reports */
	mov	r11, [r10]
	xor	eax, eax
2:
	cmp	r11, r10
	je	3f
	inc	eax
	mov	r11, [r11]
	jmp	2b
3:
	cmp	eax, MAX_QUEUED
	jbe	4f
	mov	r8, [r10]		/* list_remove the oldest report */
	mov	rax, [r8]
	mov	rdx, [r8 + 8]
	mov	[rdx], rax
	mov	[rax + 8], rdx
	mov	rax, gs:[0x30]		/* RtlFreeHeap(GetProcessHeap(), 0, oldest) */
	mov	rax, [rax + 0x60]
	mov	rcx, [rax + 0x30]
	xor	edx, edx
	call	[rip + RTLFREEHEAP_IAT]
	jmp	1b
4:
	add	rsp, 0x20
	pop	r8
	pop	rdx
	pop	rcx
	jmp	MEMCPY
