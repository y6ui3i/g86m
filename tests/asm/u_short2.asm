; More of the short executors in 32-bit protected mode: the ones written for one operation each.
; Arithmetic at the edges of carry, overflow, zero and sign; shifts by 1 and by 31, of values
; with the top bit set and clear. (The condition codes are in u_cond.) Four passes, so that each
; instruction is met by the general path, classified, and then run twice by its own executor.
; The flags are in every trace line.
%define CPU386
%include "common.inc"
%macro SHIFT1 1                 ; a shift of EAX by 1 in its C1 form (the assembler would pick D1)
    db 0xC1, %1, 1
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
    mov  ss, ax
    mov  esp, 0x7000
    mov  ebp, 4
.pass:
    mov  esi, 0x8000
    mov  eax, 0x7FFFFFFF
    mov  edx, 1
    add  eax, edx               ; overflow into the sign
    mov  ecx, 0xFFFFFFFF
    add  ecx, edx               ; carry out, zero
    sub  ecx, edx               ; borrow
    mov  [esi], eax
    sub  [esi], edx             ; 80000000 - 1: overflow the other way
    cmp  [esi], ecx
    or   eax, [esi]
    and  [esi], edx
    xor  edx, edx
    cmp  eax, -1                ; 83 and 81, one operation each
    add  dword [esi], 0x7F
    and  eax, 0x0FF0F00F
    or   dword [esi], 0x80000000
    xor  eax, 0x55AA55AA
    sub  eax, 0x12345678
    cmp  dword [esi], 0x8000007F
    mov  eax, 0x80000001        ; the shifts: by 1 (OF changes) and by 31
    SHIFT1 0xE0                 ; shl
    mov  eax, 0x40000001
    SHIFT1 0xE0
    shl  eax, 31
    mov  eax, 0x80000001
    SHIFT1 0xE8                 ; shr
    mov  eax, 0x40000001
    SHIFT1 0xE8
    shr  eax, 31
    mov  eax, 0x80000001
    SHIFT1 0xF8                 ; sar
    mov  eax, 0x40000001
    SHIFT1 0xF8
    sar  eax, 31
    mov  eax, 0xC0000003
    SHIFT1 0xF0                 ; sal, the other encoding of shl
    mov  dword [esi], 0x00F00F00
    shl  dword [esi], 4
    shr  dword [esi], 9
    sar  dword [esi], 2
    sal  eax, 3
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
