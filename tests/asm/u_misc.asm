; The 386's new instructions: MOVZX / MOVSX, SETcc, near Jcc, the bit instructions, BSF / BSR,
; FS and GS, far pointer loads, and the 32-bit forms of the stack and flag instructions.
%define CPU386
%include "common.inc"
%macro SETS 0
    seto  al
    setno ah
    setb  bl
    setae bh
    sete  cl
    setne ch
    setbe dl
    seta  dh
    sets  al
    setns ah
    setp  bl
    setnp bh
    setl  cl
    setge ch
    setle dl
    setg  byte [mem]
%endmacro
start:
    HDR
    mov  eax, 0x8001FF80
    movzx ebx, al
    movzx ecx, ax
    movzx dx, ah
    movsx ebx, al
    movsx ecx, ax
    movsx dx, al
    mov  [mem], eax
    movzx esi, byte [mem]
    movsx edi, word [mem]
    movsx bp, byte [mem+1]
    mov  si, tab
.next:
    cld
    lodsw
    push ax
    popf
    SETS
    jo   near .a
    nop
.a: jnz  near .b
    nop
.b: jl   near .c
    nop
.c: jbe  near .d
    nop
.d: cmp  si, tabend
    LOOP_BELOW .next
    mov  eax, 0x80000001
    bt   eax, 0
    bt   eax, 31
    bt   ax, 15
    mov  ecx, 37
    bt   eax, ecx
    bts  eax, 5
    btr  eax, 31
    btc  eax, 0
    btc  ax, 4
    mov  dword [mem], 0
    mov  dword [mem+4], 0
    mov  ecx, 35
    bts  [mem], ecx
    mov  cx, 17
    bts  [mem], cx
    mov  ecx, -1
    mov  dword [mem-4], 0
    btc  [mem], ecx
    mov  edx, [mem-4]
    mov  edx, [mem]
    mov  edx, [mem+4]
    bts  dword [mem], 8
    btr  word [mem+2], 1
    bt   dword [mem], 8
    mov  edx, [mem]
    mov  eax, 0x00F00100
    bsf  ecx, eax
    bsr  ecx, eax
    bsf  cx, ax
    bsr  cx, ax
    xor  eax, eax
    bsf  ecx, eax
    bsr  ecx, eax
    mov  ax, 0x1234
    mov  fs, ax
    mov  gs, ax
    push fs
    push gs
    pop  ax
    pop  bx
    mov  cx, fs
    mov  edx, gs
    mov  word [mem], 0x0500
    mov  word [mem+2], 0x0040
    lfs  bx, [mem]
    lgs  cx, [mem]
    mov  dword [mem], 0x00007000
    mov  word [mem+4], 0x0000
    lss  esp, [mem]
    mov  byte [fs:0x10], 0x5A
    mov  al, [gs:0x10]
    mov  al, [0x910]
    hlt
mem0: dd 0
mem: dd 0, 0
tab: dw 0x0000, 0x0001, 0x0040, 0x0041, 0x0080, 0x0800, 0x0880, 0x08C0, 0x0004, 0x0CD5
tabend:
    TAIL
