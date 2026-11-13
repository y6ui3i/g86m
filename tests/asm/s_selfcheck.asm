; Self-check for instructions that cannot be compared with rustx86. Prints "OK" when all pass.
;   - IDIV of -32768 by -1: the quotient does not fit, so it is a divide error (rustx86 panics here)
;   - SALC (D6): AL = CF ? FFh : 00h (rustx86 leaves AL unchanged)
%include "common.inc"
start:
    HDR
    mov  word [0], de
    mov  word [2], 0
    xor  bx, bx
    mov  ax, 0x8000
    mov  cl, 0xFF
    idiv cl
    mov  ax, 0x8000
    mov  dx, 0xFFFF
    mov  cx, 0xFFFF
    idiv cx
    cmp  bx, 2
    jne  .bad
    stc
    db   0xD6
    cmp  al, 0xFF
    jne  .bad
    clc
    db   0xD6
    cmp  al, 0
    jne  .bad
    mov  al, 'O'
    call put
    mov  al, 'K'
    call put
    hlt
.bad:
    mov  al, 'N'
    call put
    hlt
put:
    mov  ah, 0x0E
    int  0x10
    ret
de:
    inc  bx
    push bp
    mov  bp, sp
    add  word [bp+2], 2
    pop  bp
    iret
    TAIL
