; The 7 rotates and shifts (SAL shares SHL's encoding, so it is placed with db),
; with a count of 1, CL and an immediate, at 8 and 16 bits, on registers and memory.
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
    lodsw
    mov  bx, ax
    mov  di, counts
.cnt:
    mov  cl, [di]
    mov  ax, bx
    SH   ax, cl
    mov  ax, bx
    stc
    SH   al, cl
    mov  [mem], bx
    SH   word [mem], cl
    mov  dx, [mem]
    inc  di
    cmp  di, countsend
    LOOP_BELOW .cnt
    mov  ax, bx
    SH   ax, 1
    SH   al, 1
    SH   ah, 3
    SH   ax, 4
    SH   byte [mem], 1
    SH   word [mem], 9
    mov  dx, [mem]
    mov  ax, bx
    db   0xD1, 0xF0             ; SAL AX,1 (/6)
    db   0xD0, 0xF0             ; SAL AL,1 (/6)
    cmp  si, tabend
    LOOP_BELOW .next
    hlt
mem: dw 0
counts: db 0, 1, 2, 7, 8, 9, 15, 16, 17, 18, 31, 32, 33, 255
countsend:
tab: dw 0x0001, 0x8000, 0xFFFF, 0x1234, 0x80C1, 0x7F5A
tabend:
    TAIL
