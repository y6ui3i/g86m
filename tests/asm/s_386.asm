; Self-check for 386 instructions where g86m follows the Intel manual and rustx86 does otherwise.
; Prints "OK" when all pass.
;   - BTS with an immediate bit offset and a memory operand: the offset is taken modulo the
;     operand size (40 means bit 8 of the dword). rustx86 reaches past the operand instead
;   - BTS with a 16-bit register bit offset: the offset is signed (-1 is bit 15 of the word
;     before the operand). rustx86 treats it as unsigned
;   - IRETD in real mode pops three 32-bit values. rustx86 ignores the operand-size prefix there
;     and pops three 16-bit ones
%define CPU386
%include "common.inc"
start:
    HDR
    mov  dword [mem], 0
    mov  dword [mem+4], 0
    bts  dword [mem], 40
    jc   .bad
    cmp  dword [mem], 0x00000100
    jne  .bad
    cmp  dword [mem+4], 0
    jne  .bad
    mov  dword [mem-4], 0
    mov  dword [mem], 0
    mov  cx, -1
    bts  [mem], cx
    jc   .bad
    cmp  dword [mem-4], 0x80000000
    jne  .bad
    cmp  dword [mem], 0
    jne  .bad
    pushfd
    push dword 0
    push dword .back
    iretd
.back:
    cmp  sp, 0x7C00
    jne  .bad
    mov  al, 'O'
    call put
    mov  al, 'K'
    call put
    hlt
.bad:
    mov  al, 'N'
    call put
    hlt
put:
    mov  ah, 0x0E
    int  0x10
    ret
pad: dd 0
mem: dd 0, 0
    TAIL
