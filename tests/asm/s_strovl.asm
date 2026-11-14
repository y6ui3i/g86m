; Self-check for REP MOVS where the destination is closer above the source than one element.
; Each element is read whole and then written, in order, so a later read sees part of what an
; earlier write stored. rustx86 copies such a run byte by byte and gets a different answer, so
; this cannot be a trace test. The expected values are worked out by hand below. In 32-bit
; protected mode, where g86m copies in bulk. Prints "OK" when all pass.
;
;   dwords, destination 1 above:  11 22 33 44 55 66 77 88 99
;     after the first:            11 11 22 33 44 66 77 88 99
;     after the second:           11 11 22 33 44 44 66 77 88
;   words, destination 1 above:   A1 B2 C3 D4 E5 F6 07
;     after three:                A1 A1 B2 B2 D4 D4 F6
%define CPU386
%include "common.inc"
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
    mov  esi, d1
    mov  edi, d1 + 1
    mov  ecx, 2
    rep  movsd
    cmp  dword [d1 + 1], 0x44332211
    jne  bad
    cmp  dword [d1 + 5], 0x88776644
    jne  bad
    cmp  byte [d1], 0x11
    jne  bad
    mov  esi, d2
    mov  edi, d2 + 1
    mov  ecx, 3
    rep  movsw
    cmp  dword [d2 + 1], 0xD4B2B2A1
    jne  bad
    cmp  word [d2 + 5], 0xF6D4
    jne  bad
    mov  esi, d3                    ; the same dwords again, placed so that the run crosses a page end
    mov  edi, 0x8FFA
    mov  ecx, 9
    rep  movsb
    mov  esi, 0x8FFA
    mov  edi, 0x8FFB
    mov  ecx, 2
    rep  movsd
    cmp  dword [0x8FFB], 0x44332211
    jne  bad
    cmp  dword [0x8FFF], 0x88776644
    jne  bad
    mov  bl, 1
    jmp  0x18:leave
bad:
    mov  bl, 0
    jmp  0x18:leave
bits 16
leave:                              ; back to real mode, where the BIOS can print
    mov  eax, cr0
    and  al, 0xFE
    mov  cr0, eax
    jmp  0:real
real:
    xor  ax, ax
    mov  ds, ax
    mov  ss, ax
    test bl, bl
    jz   .no
    mov  al, 'O'
    call put
    mov  al, 'K'
    call put
    hlt
.no:
    mov  al, 'N'
    call put
    hlt
put:
    mov  ah, 0x0E
    int  0x10
    ret
d1: db 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99
d2: db 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07
d3: db 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99
align 8
gdt:
    dq 0
    dq 0x00CF9A000000FFFF
    dq 0x00CF92000000FFFF
    dq 0x00009A000000FFFF           ; 16-bit code, for the way back to real mode
gdtr:
    dw 31
    dd gdt
    TAIL
