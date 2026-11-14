; Self-check for code that changes itself, which the decode cache must notice. Each case runs an
; instruction twice (so that it is decoded, then taken from the cache), overwrites part of it,
; and runs it again; the new bytes must be what executes. Prints "OK" when all pass.
;   - the opcode byte:          INC AX becomes DEC AX
;   - the ModRM byte:           MOV AX, BX becomes MOV AX, CX
;   - a displacement:           MOV AX, [SI+2] becomes MOV AX, [SI+4]
;   - a prefix:                 an ES override becomes a DS override
;   - a SIB byte after two prefixes: the scale goes from 2 to 4
;   - an immediate (never cached, but the instruction before and after it is)
%define CPU386
%include "common.inc"
%macro CASE 4                   ; routine, expected AX before, address to patch, new byte
    call %1
    call %1
    cmp  ax, %2
    jne  bad
    mov  byte [%3], %4
    call %1
%endmacro
start:
    HDR
    mov  ax, 0x1000
    mov  es, ax
    mov  word [es:data], 0x7777
    mov  si, data
    mov  bx, 0x1111
    mov  cx, 0x2222
    CASE t_op, 1, t_op.p, 0x48
    cmp  ax, 0xFFFF
    jne  bad
    CASE t_modrm, 0x1111, t_modrm.p + 1, 0xC8
    cmp  ax, 0x2222
    jne  bad
    CASE t_disp, 0xAAAA, t_disp.p + 2, 4
    cmp  ax, 0xBBBB
    jne  bad
    CASE t_prefix, 0x7777, t_prefix.p, 0x3E
    cmp  ax, 0x5555
    jne  bad
    mov  ebx, data
    mov  ecx, 1
    CASE t_sib, 0xAAAA, t_sib.p + 4, 0x8B
    cmp  ax, 0xBBBB
    jne  bad
    CASE t_imm, 0x1234, t_imm.p + 1, 0x35
    cmp  ax, 0x1235
    jne  bad
    mov  al, 'O'
    call put
    mov  al, 'K'
    call put
    hlt
bad:
    mov  al, 'N'
    call put
    hlt
put:
    mov  ah, 0x0E
    int  0x10
    ret
t_op:
    xor  ax, ax
.p: inc  ax
    ret
t_modrm:
.p: mov  ax, bx
    ret
t_disp:
.p: mov  ax, [si+2]
    ret
t_prefix:
.p: mov  ax, [es:si]
    ret
t_sib:
.p: mov  eax, [ebx+ecx*2+0]
    ret
t_imm:
.p: mov  ax, 0x1234
    add  ax, 0
    ret
data:
    dw 0x5555, 0xAAAA, 0xBBBB
    TAIL
