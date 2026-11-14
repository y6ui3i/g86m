; 32-bit protected-mode code, run four times over, so that every instruction with a short
; executor in the decode cache is met first by the general path, then classified, then run by
; its executor twice. The trace must be the same on every pass and the same as rustx86's.
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
    mov  ebp, 4
.pass:
    mov  ebx, 0x8000
    mov  ecx, 2
    mov  eax, 0x89ABCDEF
    mov  [ebx+8], eax               ; 89, memory
    mov  edx, [ebx+8]               ; 8B, memory
    mov  esi, edx                   ; 89 or 8B, registers
    mov  [ebx+ecx*4+8], esi         ; a SIB byte
    mov  edi, [ebx+ecx*4+8]
    mov  [0x8020], edi              ; a 32-bit displacement and no base
    add  eax, edx                   ; the arithmetic grid, both directions
    adc  [ebx+8], eax
    sub  edx, [ebx+8]
    sbb  esi, edx
    and  edi, eax
    or   [ebx+12], edi
    xor  eax, [ebx+12]
    cmp  eax, edx
    cmp  [ebx+8], esi
    add  eax, -5                    ; 83
    sub  dword [ebx+8], 0x7F
    cmp  eax, 0x12345678            ; 81
    xor  dword [ebx+8], 0x0F0F0F0F
    lea  esi, [ebx+ecx*8-4]
    lea  edi, [esi+eax]
    test eax, edx
    test [ebx+8], eax
    shl  eax, 3                     ; C1
    shr  dword [ebx+8], 5
    sar  edx, 31
    rol  esi, 9
    mov  cl, 7
    shl  edi, cl                    ; D3
    sar  eax, cl
    ror  dword [ebx+8], cl
    cmp  eax, 0
    jl   .neg                       ; a short conditional jump, taken or not
    inc  eax
.neg:
    jmp  short .over
    hlt
.over:
    test edx, edx
    jz   near .zero                 ; a near conditional jump
    dec  edx
.zero:
    jmp  near .far
    hlt
.far:
    call fn
    nop
    push eax
    push edx
    pop  esi
    pop  edi
    inc  ecx
    dec  ebx
    mov  eax, 0x00C0FFEE            ; B8
    mov  [ebx+9], eax
    movzx edx, byte [ebx+9]         ; 0F B6
    movzx esi, al
    movzx edi, word [ebx+10]        ; 0F B7
    movzx eax, dx
    mov  al, [ebx+9]                ; the byte forms
    mov  [ebx+12], dl
    add  al, dl
    sub  [ebx+9], cl
    cmp  dl, [ebx+9]
    and  byte [ebx+9], 0x3C         ; 80
    cmp  bl, 5
    test al, dl                     ; 84
    test byte [ebx+9], 0x81         ; F6
    test edx, 0x8000                ; F7
    imul eax, edx                   ; 0F AF
    imul esi, [ebx+9]
    setz dl                         ; 0F 94
    setl byte [ebx+9]
    dec  ebp
    jnz  near .pass
    hlt
fn:
    add  eax, 1
    ret
align 8
gdt:
    dq 0
    dq 0x00CF9A000000FFFF
    dq 0x00CF92000000FFFF
gdtr:
    dw 23
    dd gdt
    TAIL
