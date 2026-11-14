; Every condition code as a conditional jump, taken and not, from five states of the flags, in
; 32-bit protected mode, four passes: the conditional jumps have short executors that test the
; flags in their own way (a mask, or SF against OF), and this is where a wrong one would show.
; What a jump skips or does not skip is an LEA, which leaves the flags alone.
%define CPU386
%include "common.inc"
%macro CONDS 0
%assign cc 0
%rep 16
    db 0x70 + cc, 3
    lea  ebx, [ebx+1]
%assign cc cc+1
%endrep
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
    mov  ebp, 4
.pass:
    mov  edx, 1
    mov  eax, 0x7FFFFFFF
    add  eax, edx               ; overflow, sign
    CONDS
    mov  eax, 0xFFFFFFFF
    add  eax, edx               ; carry, zero, parity, auxiliary carry
    CONDS
    sub  eax, edx               ; borrow, sign
    CONDS
    mov  eax, 0x80000000
    sub  eax, edx               ; overflow without sign
    CONDS
    cmp  edx, 2                 ; less: sign without overflow
    CONDS
    dec  ebp
    jnz  near .pass
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
