; The x87 FPU, part 2: rounding control and the functions, at 53-bit precision. Runs on the i686 (--cpu i686).
%define CPU686
%include "common.inc"
%macro G64 0                    ; pop ST(0) into EDX:EAX as a 64-bit real
    fstp qword [bx]
    mov  eax, [bx]
    mov  edx, [bx+4]
%endmacro
%macro THIRD 0                  ; 1/3 and -1/3 under the current control word, then 2.5 to an integer
    fld1
    fidiv word [si]
    fld  st0
    fchs
    G64
    G64
    fld  dword [si+2]
    frndint
    fistp word [bx]
    mov  ax, [bx]
    fld  dword [si+2]
    fchs
    fistp word [bx]
    mov  ax, [bx]
%endmacro
start:
    HDR
    mov  bx, 0x8000
    mov  si, data
    fninit
    fldcw [si+14]
    THIRD                       ; to nearest
    fldcw [si+6]                ; down
    THIRD
    fldcw [si+8]                ; up
    THIRD
    fldcw [si+10]               ; toward zero
    THIRD
    fldcw [si+12]               ; single precision, to nearest
    fld1
    fidiv word [si]
    G64
    fldcw [si+14]               ; back to nearest at 53 bits
    fld  dword [si+2]           ; functions
    fld  st0
    fsin
    G64
    fld  st0
    fcos
    G64
    fld  st0
    fsincos
    G64
    G64
    fld  st0
    fptan
    G64
    G64
    fld1
    fld  st1
    fpatan
    G64
    fld  st0
    fld1
    fadd st0, st0
    fxch st1
    fprem                       ; 2.5 mod 2
    fnstsw ax
    G64
    fscale                      ; 2 * 2^2
    G64
    fld1
    fldl2t
    fldlg2
    fldln2
    G64
    G64
    hlt
data:
    dw 3                        ; +0
    dd 2.5                      ; +2
    dw 0x067F                   ; +6   round down
    dw 0x0A7F                   ; +8   round up
    dw 0x0E7F                   ; +10  round toward zero
    dw 0x007F                   ; +12  24-bit precision
    dw 0x027F                   ; +14  53-bit precision, to nearest
    TAIL
