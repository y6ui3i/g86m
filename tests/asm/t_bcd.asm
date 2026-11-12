; DAA / DAS / AAA / AAS を、AL の値と CF・AF の 4 通りの組で。
%include "common.inc"
start:
    HDR
    xor  cx, cx
.next:
    xor  bx, bx
.fl:
    mov  ah, [flags+bx]
    sahf
    mov  al, cl
    daa
    mov  ah, [flags+bx]
    sahf
    mov  al, cl
    das
    mov  ah, [flags+bx]
    sahf
    mov  al, cl
    mov  ah, 0x12
    aaa
    mov  ah, [flags+bx]
    sahf
    mov  al, cl
    mov  ah, 0x12
    aas
    inc  bx
    cmp  bx, 4
    jb   .fl
    add  cl, 5
    jnc  .next
    hlt
flags: db 0x00, 0x01, 0x10, 0x11
    TAIL
