; The 8 operations plus TEST, in register, memory and immediate forms. Operand pairs come from a table.
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
    mov  bx, ax
    lodsw
    mov  dx, ax
    mov  cx, bx
    OPS  cx, dx
    mov  cx, bx
    OPS  cl, dl
    OPS  ch, dh
    mov  [mem], bx
    OPS  [mem], dx
    OPS  dx, [mem]
    OPS  byte [mem], dl
    OPS  dl, [mem+1]
    mov  ax, bx
    OPS  ax, 0x1234
    OPS  al, 0x9C
    OPS  cx, 0x8001
    OPS  cx, -3
    inc  cx
    dec  cx
    inc  byte [mem]
    dec  word [mem]
    neg  cx
    not  cx
    neg  byte [mem]
    cmp  si, tabend
    LOOP_BELOW .next
    mov  ax, [mem]
    hlt
mem: dw 0
tab:
    dw 0x0000, 0x0000,  0xFFFF, 0x0001,  0x7FFF, 0x0001,  0x8000, 0x8000
    dw 0x00FF, 0x0001,  0x1234, 0xEDCC,  0x0F0F, 0x00F1,  0x807F, 0x7F80
tabend:
    TAIL
