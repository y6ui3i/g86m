; 32-bit multiply and divide, the two- and three-operand IMUL forms, CWDE and CDQ.
; On a divide error the INT 0 handler skips the instruction (all are 3 bytes here) and returns.
%define CPU386
%include "common.inc"
start:
    HDR
    mov  word [0], de_handler
    mov  word [2], 0
    mov  si, tab
.next:
    lodsd
    mov  ebx, eax
    lodsd
    mov  ebp, eax
    lodsd
    mov  edi, eax
    mov  eax, ebx
    mul  edi
    mov  eax, ebx
    imul edi
    mov  ecx, ebx
    imul ecx, edi
    imul ecx, edi, 0x12345678
    imul ecx, ebx, -7
    mov  cx, bx
    imul cx, di
    imul edx, [val], 300
    mov  eax, ebx
    mov  edx, ebp
    mov  ecx, edi
    div  ecx
    mov  eax, ebx
    mov  edx, ebp
    idiv ecx
    mov  eax, ebx
    cwde
    cdq
    mov  ax, bx
    cwd
    cmp  si, tabend
    LOOP_BELOW .next
    hlt
de_handler:
    push bp
    mov  bp, sp
    add  word [bp+2], 3
    pop  bp
    iret
val: dd 0xFFFFFF85
tab:
    dd 0x00000000, 0x00000000, 0x00000000
    dd 0x00000064, 0x00000000, 0x00000007
    dd 0xFFFFFFFF, 0x00000000, 0xFFFFFFFF
    dd 0x80000001, 0xFFFFFFFF, 0x000000FF
    dd 0x7FFFFFFF, 0x00000001, 0x00020003
    dd 0x12345678, 0x00000056, 0x80000001
    dd 0xFFFFFF80, 0xFFFFFFFF, 0xFFFFFFFE
    dd 0x000000FF, 0x7FFFFFFF, 0xFFFFFFFF
    dd 0x00038000, 0x00000002, 0x00050003
tabend:
    TAIL
