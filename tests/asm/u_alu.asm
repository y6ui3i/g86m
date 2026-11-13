; 32-bit operands in real mode (66h prefix): the 8 operations plus TEST on registers, memory and
; immediates, then INC / DEC / NEG / NOT.
%define CPU386
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
    lodsd
    mov  ebx, eax
    lodsd
    mov  edx, eax
    mov  ecx, ebx
    OPS  ecx, edx
    mov  [mem], ebx
    OPS  [mem], edx
    OPS  edx, [mem]
    mov  eax, ebx
    OPS  eax, 0x12345678
    OPS  ecx, 0x80000001
    OPS  ecx, -3
    OPS  dword [mem], 0x7FFFFFFF
    inc  ecx
    dec  ecx
    inc  dword [mem]
    dec  dword [mem]
    neg  ecx
    not  ecx
    neg  dword [mem]
    not  dword [mem]
    inc  esp
    dec  esp
    cmp  si, tabend
    LOOP_BELOW .next
    mov  eax, [mem]
    hlt
mem: dd 0
tab:
    dd 0x00000000, 0x00000000,  0xFFFFFFFF, 0x00000001,  0x7FFFFFFF, 0x00000001
    dd 0x80000000, 0x80000000,  0x0000FFFF, 0x00000001,  0x12345678, 0xEDCBA988
    dd 0x80007FFF, 0x7FFF8000
tabend:
    TAIL
