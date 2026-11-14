; REP MOVS and REP STOS in 32-bit protected mode, where g86m copies a page-sized run at a time.
; What must come out the same as copying one element at a time: regions that overlap, in both
; orders; a run that crosses the end of a 4 KB page, aligned and not; every width. After each
; copy the registers are in the trace, and a few values are read back from memory.
%define CPU386
%include "common.inc"
%macro PEEK 1                   ; three dwords around an address, into EAX, EBX, EDX
    mov  eax, [%1]
    mov  ebx, [%1+4]
    mov  edx, [%1+13]
%endmacro
start:
    cli
    xor  ax, ax
    mov  ds, ax
    lgdt [gdtr]
    mov  eax, cr0
    or   al, 1
    mov  cr0, eax
    jmp  0x08:pm
bits 32
pm:
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  esp, 0x7000
    cld
    mov  edi, 0x8FF0            ; a pattern across the page end at 9000h: 32 dwords counting up
    mov  eax, 0x01020304
    mov  ecx, 32
.fill:
    stosd
    add  eax, 0x01010101
    loop .fill
    mov  esi, 0x8FF0            ; a plain copy across a page end
    mov  edi, 0xAFF8
    mov  ecx, 20
    rep  movsd
    PEEK 0xB000
    mov  esi, 0x8FF3            ; unaligned, bytes
    mov  edi, 0xBFFD
    mov  ecx, 37
    rep  movsb
    PEEK 0xBFFC
    mov  esi, 0x8FF1            ; words, unaligned, so that one straddles the page end
    mov  edi, 0xCFF9
    mov  ecx, 15
    rep  movsw
    PEEK 0xCFF8
    mov  esi, 0x8FF0            ; destination one dword above the source: the first dword repeats.
    mov  edi, 0x8FF4            ; (Closer than one element is in s_strovl: rustx86 gets that wrong.)
    mov  ecx, 12
    rep  movsd
    PEEK 0x8FF8
    mov  esi, 0x9004            ; destination 3 bytes below the source
    mov  edi, 0x9001
    mov  ecx, 9
    rep  movsd
    PEEK 0x9000
    mov  esi, 0x9010            ; bytes with the destination 1 above: the first byte repeats
    mov  edi, 0x9011
    mov  ecx, 24
    rep  movsb
    PEEK 0x9010
    mov  eax, 0xA1B2C3D4        ; fills, across a page end
    mov  edi, 0xDFFA
    mov  ecx, 9
    rep  stosd
    PEEK 0xDFF8
    mov  edi, 0xEFFF
    mov  ecx, 5
    rep  stosw
    PEEK 0xEFFC
    mov  edi, 0xFFFE
    mov  ecx, 7
    rep  stosb
    PEEK 0xFFFC
    xor  ecx, ecx               ; a count of zero does nothing
    rep  movsd
    rep  stosb
    std                         ; downward: not done in bulk, but must still be right
    mov  esi, 0x900C
    mov  edi, 0x9010
    mov  ecx, 4
    rep  movsd
    cld
    PEEK 0x9000
    hlt
align 8
gdt:
    dq 0
    dq 0x00CF9A000000FFFF
    dq 0x00CF92000000FFFF
gdtr:
    dw 23
    dd gdt
    TAIL
