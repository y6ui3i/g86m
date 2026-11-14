; Self-check for FPU results that need the 64-bit mantissa of the 80-bit format. rustx86 keeps 53
; bits, so none of this can be compared with it. Prints "OK" when all pass. Runs on the i686.
;   - 1/3 has 64 mantissa bits, rounded to nearest; rounded down, its last bit is different;
;     at 53-bit precision it has 53
;   - (1/3) * 3 rounds back to exactly 1
;   - 1 + 2^-63 is not 1, and its mantissa ends in a one
;   - 2^64 + 1.5 is not 2^64 (the question musl's printf asks before it rounds a digit up);
;     at 53-bit precision it is
;   - a 64-bit integer goes on the stack and comes back with every bit
%define CPU686
%include "common.inc"
%macro T80 3                    ; pop ST(0); it must be mantissa %1:%2 with sign and exponent %3
    fstp tword [bx]
    cmp  dword [bx+4], %1
    jne  bad
    cmp  dword [bx], %2
    jne  bad
    cmp  word [bx+8], %3
    jne  bad
%endmacro
start:
    HDR
    mov  bx, 0x8000
    mov  si, data
    fninit
    fld1
    fidiv word [si]
    T80  0xAAAAAAAA, 0xAAAAAAAB, 0x3FFD
    fldcw [si+2]                ; round down
    fld1
    fidiv word [si]
    T80  0xAAAAAAAA, 0xAAAAAAAA, 0x3FFD
    fldcw [si+4]                ; 53 bits, to nearest
    fld1
    fidiv word [si]
    T80  0xAAAAAAAA, 0xAAAAA800, 0x3FFD
    fninit
    fld1
    fidiv word [si]
    fimul word [si]
    fld1
    fucomip st0, st1
    jne  bad
    jp   bad
    fstp st0
    fld1
    fld  tword [si+6]           ; 2^-63
    faddp st1, st0
    fld1
    fucomip st0, st1
    je   bad
    T80  0x80000000, 0x00000001, 0x3FFF
    fld  tword [si+16]          ; 2^64
    fld  st0
    fadd dword [si+26]
    fucomi st0, st1
    je   bad
    T80  0x80000000, 0x00000001, 0x403F
    fldcw [si+4]
    fld  st0
    fadd dword [si+26]
    fucomip st0, st1
    jne  bad
    fstp st0
    fninit
    fild qword [si+30]
    fld  st0
    fchs
    fistp qword [bx]
    mov  eax, [bx]
    add  eax, [si+30]
    jnz  bad
    fistp qword [bx]
    mov  eax, [bx]
    cmp  eax, [si+30]
    jne  bad
    mov  eax, [bx+4]
    cmp  eax, [si+34]
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
data:
    dw 3                        ; +0
    dw 0x077F                   ; +2   64 bits, round down
    dw 0x027F                   ; +4   53 bits, to nearest
    dq 0x8000000000000000       ; +6   2^-63
    dw 0x3FC0
    dq 0x8000000000000000       ; +16  2^64
    dw 0x403F
    dd 1.5                      ; +26
    dq 0x0123456789ABCDEF       ; +30
    TAIL
