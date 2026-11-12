; グループ 1 (80/81/83) のメモリ即値形と、INC/DEC/NEG/NOT の残り。
%include "common.inc"
%macro OPS 2
    add  %1, %2
    adc  %1, %2
    sub  %1, %2
    sbb  %1, %2
    and  %1, %2
    or   %1, %2
    xor  %1, %2
    cmp  %1, %2
    test %1, %2
%endmacro
start:
    HDR
    mov  si, tab
.next:
    lodsw
    mov  [mem], ax
    OPS  byte [mem], 0x7F
    OPS  word [mem], 0x7FFF
    OPS  word [mem], -2
    mov  bx, [mem]
    inc  word [mem]
    dec  byte [mem+1]
    neg  word [mem]
    not  byte [mem]
    not  word [mem]
    mov  cx, [mem]
    inc  ch
    dec  cl
    neg  ch
    not  cl
    inc  ax
    inc  bx
    inc  sp
    dec  sp
    dec  di
    inc  bp
    cmp  si, tabend
    LOOP_BELOW .next
    hlt
mem: dw 0
tab: dw 0x0000, 0xFFFF, 0x7FFF, 0x8000, 0x00FF, 0x0100, 0x1234, 0x8001
tabend:
    TAIL
