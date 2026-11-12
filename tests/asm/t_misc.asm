; Stack, flag instructions, addressing modes, segment overrides, XCHG / XLAT / LEA / LES / LDS.
%include "common.inc"
start:
    HDR
    mov  ax, 0x1000
    mov  es, ax
    mov  word [0x500], 0x1111
    mov  word [es:0x500], 0x2222
    mov  word [0x502], 0x3333
    mov  word [es:0x502], 0x4444
    mov  bx, 0x400
    mov  si, 0x100
    mov  di, 0x0FE
    mov  bp, 0x3F0
    lea  ax, [bx+si]
    lea  ax, [bx+di]
    lea  ax, [bp+si]
    lea  ax, [bp+di]
    lea  ax, [si]
    lea  ax, [di]
    lea  ax, [0x1234]
    lea  ax, [bx]
    lea  ax, [bx+si+5]
    lea  ax, [bx+di-5]
    lea  ax, [bp+si+0x7F]
    lea  ax, [bp+di-0x80]
    lea  ax, [si+1]
    lea  ax, [di-1]
    lea  ax, [bp+2]
    lea  ax, [bx-2]
    lea  ax, [bx+si+0x1234]
    lea  ax, [bx+di+0xF000]
    lea  ax, [bp+si+0x8000]
    lea  ax, [bp+di+0x0101]
    lea  ax, [si+0x7FFF]
    lea  ax, [di-1+0]
    lea  ax, [bp+0x1000]
    lea  ax, [bx+0xC000]
    mov  ax, 0x1000
    mov  ss, ax
    mov  sp, 0x7000
    mov  bp, 0x500
    mov  bx, 0x500
    mov  ax, [bp]
    mov  ax, [ds:bp]
    mov  ax, [bx]
    mov  ax, [ss:bx]
    mov  ax, [es:bx+2]
    mov  ax, [bp+2]
    mov  si, 2
    mov  ax, [bp+si]
    mov  ax, [bx+si]
    mov  ax, [cs:0x7C00]
    mov  ax, [es:0x500]
    mov  al, [es:0x501]
    mov  [es:0x504], ax
    mov  [es:0x506], al
    mov  cx, [es:0x504]
    les  di, [0x500]
    lds  si, [es:0x500]
    mov  dx, ds
    xor  ax, ax
    mov  ds, ax
    mov  es, ax
    mov  [0x510], ss
    mov  ax, [0x510]
    mov  es, [0x510]
    mov  cx, es
    push sp
    pop  ax
    push 0x1234
    push -2
    pop  bx
    pop  cx
    push cs
    push ds
    push es
    push ss
    pop  ax
    pop  es
    pop  ds
    pop  dx
    push word [0x500]
    pop  word [0x520]
    mov  ax, [0x520]
    mov  ax, 0x0101
    mov  bx, 0x0202
    mov  cx, 0x0303
    mov  dx, 0x0404
    mov  si, 0x0505
    mov  di, 0x0606
    mov  bp, 0x0707
    pusha
    xor  ax, ax
    xor  bx, bx
    mov  si, ax
    mov  bp, ax
    popa
    enter 8, 0
    leave
    enter 4, 1
    leave
    enter 2, 3
    leave
    xchg ax, bx
    xchg ax, cx
    xchg ax, sp
    xchg ax, sp
    xchg bx, dx
    xchg bl, dh
    xchg [0x520], bx
    xchg [0x521], cl
    mov  bx, xtab
    mov  al, 3
    xlatb
    mov  al, 0
    cs   xlatb
    stc
    cmc
    cmc
    std
    cld
    mov  ah, 0xD7
    sahf
    lahf
    mov  ah, 0x2A
    sahf
    lahf
    pushf
    pop  ax
    mov  ax, 0x0CD5
    push ax
    popf
    pushf
    pop  bx
    xor  ax, ax
    push ax
    popf
    pushf
    pop  bx
    wait
    fninit
    fld1
    hlt
xtab: db 10, 20, 30, 40
    TAIL
