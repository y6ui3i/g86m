; 32-bit rotates and shifts, and the double shifts SHLD / SHRD at 16 and 32 bits.
%define CPU386
%include "common.inc"
%macro SH 2
    rol  %1, %2
    ror  %1, %2
    rcl  %1, %2
    rcr  %1, %2
    shl  %1, %2
    shr  %1, %2
    sar  %1, %2
%endmacro
start:
    HDR
    mov  si, tab
.next:
    lodsd
    mov  ebx, eax
    lodsd
    mov  ebp, eax
    mov  di, counts
.cnt:
    mov  cl, [di]
    mov  eax, ebx
    SH   eax, cl
    mov  eax, ebx
    mov  edx, ebp
    shld eax, edx, cl
    mov  eax, ebx
    shrd eax, edx, cl
    mov  ax, bx
    shld ax, dx, cl
    mov  ax, bx
    shrd ax, dx, cl
    inc  di
    cmp  di, countsend
    LOOP_BELOW .cnt
    mov  eax, ebx
    SH   eax, 1
    SH   eax, 13
    mov  [mem], ebx
    SH   dword [mem], 1
    shld dword [mem], edx, 5
    shrd dword [mem], edx, 31
    shld word [mem], dx, 3
    shrd word [mem], dx, 1
    mov  edx, [mem]
    cmp  si, tabend
    LOOP_BELOW .next
    hlt
mem: dd 0
counts: db 0, 1, 2, 7, 15, 16, 17, 31, 32, 33, 255
countsend:
tab: dd 0x00000001, 0x80000000,  0x80000000, 0x00000001,  0xFFFFFFFF, 0x00000000
     dd 0x12345678, 0x9ABCDEF0,  0x80C10F5A, 0x7F5A0181
tabend:
    TAIL
