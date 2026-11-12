; rustx86 と比べられない命令の自己判定。全部通れば "OK" を出す。
;   - IDIV で -32768 / -1: 商が収まらないので除算例外 (rustx86 はここで panic する)
;   - SALC (D6): AL = CF ? FFh : 00h (rustx86 は AL を変えない)
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
