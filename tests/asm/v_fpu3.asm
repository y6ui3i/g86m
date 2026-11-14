; The x87 FPU, part 3: the stack pointer, the environment, conditional moves, the 80-bit format,
; and saving and restoring the whole unit. Runs on the i686 (--cpu i686).
%define CPU686
%include "common.inc"
%macro G64 0                    ; pop ST(0) into EDX:EAX as a 64-bit real
    fstp qword [bx]
    mov  eax, [bx]
    mov  edx, [bx+4]
%endmacro
start:
    HDR
    mov  bx, 0x8000
    mov  si, data
    fninit
    fld1
    fldpi
    fldz
    fincstp
    fnstsw ax
    fdecstp
    ffree st0
    fnstsw ax
    o32 fnstenv [bx]            ; the 28-byte form; the 14-byte one is in s_fpu, rustx86 has only this
    mov  eax, [bx]
    mov  ecx, [bx+4]
    mov  edx, [bx+8]
    fldcw [si+14]
    fincstp
    xor  ax, ax                 ; conditional moves
    cmp  ax, 1
    fld1
    fldz
    fcmovb st0, st1
    fcmove st0, st1
    fcmovnb st0, st1
    fcmovne st0, st1
    fcmovbe st0, st1
    fcmovu st0, st1
    fcmovnu st0, st1
    G64
    G64
    fld  tword [si+16]          ; an 80-bit value goes through unchanged, and narrows correctly
    fstp tword [bx]
    mov  eax, [bx]
    mov  edx, [bx+4]
    mov  cx, [bx+8]
    fld  tword [si+16]
    G64
    fldpi                       ; save, which also initialises; restore brings it back
    fld1
    o32 fnsave [bx]
    fnstsw ax
    mov  eax, [bx+4]
    mov  eax, [bx+8]
    mov  eax, [bx+28]
    mov  eax, [bx+32]
    mov  cx, [bx+36]
    mov  eax, [bx+38]
    mov  edx, [bx+42]
    o32 frstor [bx]
    fnstsw ax
    faddp st1, st0
    G64
    fnstsw [bx]
    mov  ax, [bx]
    hlt
data:
    dw 3                        ; +0
    dd 2.5                      ; +2
    dw 0x077F                   ; +6   round down
    dw 0x0B7F                   ; +8   round up
    dw 0x0F7F                   ; +10  round toward zero
    dw 0x007F                   ; +12  24-bit precision
    dw 0x037F                   ; +14
    dt 1.2345678901234567890    ; +16
    TAIL
