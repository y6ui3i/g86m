; Self-check for the parts of the x87 FPU that rustx86 cannot judge. Prints "OK" when all pass.
; Runs on the i686 (--cpu i686).
;   - CR0 has the ET bit set
;   - FNSTENV in 16-bit code writes the 14-byte environment (rustx86 always writes 28 bytes)
;   - an 80-bit value copied between registers keeps all 64 mantissa bits (rustx86 keeps 53)
;   - F2XM1, FYL2X, FYL2XP1, FPREM1 and FXTRACT (rustx86 computes these another way, and the last
;     bit can differ)
;   - with TS set in CR0 an FPU instruction traps to vector 7 and runs once TS is cleared; so
;     does FWAIT when MP is set too
%define CPU686
%include "common.inc"
%macro CHECK 1                  ; ST(0), rounded to an integer and popped, must be %1
    fistp dword [bx]
    cmp  dword [bx], %1
    jne  bad
%endmacro
start:
    HDR
    mov  bx, 0x8000
    mov  si, data
    mov  eax, cr0
    test al, 0x10
    jz   bad
    fninit
    fld1
    mov  word [bx+14], 0x5A5A
    fnstenv [bx]
    cmp  dword [bx], 0x3800037F
    jne  bad
    cmp  word [bx+4], 0x3FFF
    jne  bad
    cmp  word [bx+14], 0x5A5A
    jne  bad
    fldcw [si+10]
    fld  tword [si]
    fld  st0
    fxch st1
    fstp st2
    fstp tword [bx]
    mov  eax, [bx]
    cmp  eax, [si]
    jne  bad
    mov  eax, [bx+4]
    cmp  eax, [si+4]
    jne  bad
    fstp st0
    fld  dword [si+12]          ; 2^0.5 - 1, times a million
    f2xm1
    fimul dword [si+16]
    CHECK 414214
    fld  dword [si+20]          ; 3 * log2(8)
    fld  dword [si+24]
    fyl2x
    CHECK 9
    fld  dword [si+20]          ; 3 * log2(1 + 1)
    fld1
    fyl2xp1
    CHECK 3
    fld  dword [si+20]          ; 8 is nearer to 9 than to 6: the IEEE remainder is -1
    fld  dword [si+24]
    fprem1
    CHECK -1
    fstp st0
    fld  dword [si+28]          ; 12 is 1.5 * 2^3
    fxtract
    fadd st0, st0
    CHECK 3
    CHECK 3
    mov  word [7*4], nm
    mov  word [7*4+2], 0
    xor  di, di
    mov  eax, cr0
    or   al, 0x08               ; TS
    mov  cr0, eax
    fld1
    cmp  di, 1
    jne  bad
    mov  eax, cr0
    or   al, 0x0A               ; MP and TS
    mov  cr0, eax
    fwait
    cmp  di, 2
    jne  bad
    CHECK 1
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
nm:                             ; device not available: clear TS and let the instruction run again
    inc  di
    clts
    iret
data:
    dt 1.2345678901234567890    ; +0
    dw 0x037F                   ; +10
    dd 0.5                      ; +12
    dd 1000000                  ; +16
    dd 3.0                      ; +20
    dd 8.0                      ; +24
    dd 12.0                     ; +28
    TAIL
