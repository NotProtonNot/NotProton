/* Caps winebus.sys's queued input reports, aarch64 (ARM64X) builds.
 *
 * The x86_64 note in cap.S applies here too: process_hid_report appends every report to
 * ext->reports without bound, so a slow reader lets input lag grow. The inlined
 * list_add_tail is followed by `bl memcpy` (refreshing last_reports), and that bl is
 * redirected here. With ext->cs still held, drop the oldest queued reports until at most
 * MAX_QUEUED remain, then tail-call memcpy with its arguments untouched.
 *
 * At the hook: x25 = struct device_extension *, x0/x1/x2 = memcpy's args, x30 = the
 * address after the original bl. x18 is the TEB, x19-x28 are callee-saved, so x25 and x18
 * stay valid across the RtlFreeHeap call. GetProcessHeap() is TEB->Peb->ProcessHeap, the
 * same sequence process_hid_report itself uses.
 */
	.text
	.globl cap_reports
cap_reports:
	stp	x0, x1, [sp, #-48]!	/* save memcpy args and the return address */
	stp	x2, x30, [sp, #16]
1:
	add	x9, x25, #REPORTS_OFFSET	/* &ext->reports (list sentinel) */
	ldr	x10, [x9]		/* head->next */
	mov	w11, #0
2:
	cmp	x10, x9
	b.eq	3f
	add	w11, w11, #1
	ldr	x10, [x10]		/* node->next */
	b	2b
3:
	cmp	w11, #MAX_QUEUED
	b.le	4f
	ldr	x12, [x9]		/* oldest = head->next, list_remove it */
	ldr	x13, [x12]		/* oldest->next */
	ldr	x14, [x12, #8]		/* oldest->prev */
	str	x13, [x14]
	str	x14, [x13, #8]
	ldr	x8, [x18, #0x60]	/* TEB->ProcessEnvironmentBlock */
	ldr	x0, [x8, #0x30]		/* Peb->ProcessHeap */
	mov	w1, #0
	mov	x2, x12
	bl	RTLFREEHEAP_THUNK	/* RtlFreeHeap(heap, 0, oldest) */
	b	1b
4:
	ldp	x2, x30, [sp, #16]
	ldp	x0, x1, [sp], #48
	b	MEMCPY_THUNK		/* tail-call, returns to the saved x30 */
