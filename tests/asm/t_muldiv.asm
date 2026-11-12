; Multiply and divide. On a divide error the INT 0 handler skips the instruction (all are 2 bytes) and returns.
; IDIV of AX=8000h by -1 is left out: rustx86 panics there, so no expected trace
; can be made (docs/goose-notes.md, "Found in rustx86").
%include "common.inc"
start:
    HDR
    mov  word [0], de_handler
    mov  word [2], 0
    mov  si, tab
.next:
    lodsw
    mov  bx, ax
    lodsw
    mov  bp, ax
    lodsw
    mov  di, ax
    mov  ax, bx
    mul  bl
    mov  ax, bx
    mul  di
    mov  ax, bx
    imul bh
    mov  ax, bx
    imul di
    imul cx, di, 0x1234
    imul cx, bx, -7
    imul dx, [val], 300
    mov  ax, bx
    mov  dx, bp
    mov  cx, di
    div  cl
    mov  ax, bx
    div  ch
    mov  ax, bx
    mov  dx, bp
    div  cx
    mov  ax, bx
    idiv cl
    mov  ax, bx
    idiv ch
    mov  ax, bx
    mov  dx, bp
    idiv cx
    mov  ax, bx
    cbw
    cwd
    mov  ax, bx
    aam
    mov  ax, bx
    aam  7
    mov  ax, bx
    aad
    mov  ax, bx
    aad  0x21
    cmp  si, tabend
    LOOP_BELOW .next
    hlt
de_handler:
    push bp
    mov  bp, sp
    add  word [bp+2], 2
    pop  bp
    iret
val: dw 0xFF85
tab:
    dw 0x0000, 0x0000, 0x0000
    dw 0x0064, 0x0000, 0x0007
    dw 0xFFFF, 0x0000, 0xFFFF
    dw 0x8001, 0xFFFF, 0x00FF
    dw 0x7FFF, 0x0001, 0x0203
    dw 0x1234, 0x0056, 0x8001
    dw 0xFF80, 0xFFFF, 0xFFFE
    dw 0x00FF, 0x7FFF, 0xFFFF
    dw 0x8001, 0xFFFF, 0xFFFF
    dw 0x0380, 0x0002, 0x0503
tabend:
    TAIL
