; The x87 FPU, part 1: loads and stores in every format, arithmetic with memory and register
; operands, comparison. The trace has no FPU state, so each result is stored to memory and loaded
; into EDX:EAX. The precision control is set to 53 bits, where rustx86's f64 arithmetic is exact;
; results with 64 bits of mantissa are checked in s_fpu80. Runs on the i686 (--cpu i686).
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
    fnstcw [bx]
    mov  cx, [bx]
    fnstsw ax
    fldcw [si+38]
    fld  dword [si]             ; 1.5
    fld  qword [si+4]           ; 0.1
    fild word [si+12]           ; -7
    fild dword [si+14]          ; 100000
    fild qword [si+18]          ; 0x0123456789ABCDEF, more bits than an f64 holds
    fnstsw ax
    G64
    G64
    G64
    G64
    G64
    fnstsw ax
    fld  qword [si+4]           ; arithmetic with memory operands, every form
    fadd dword [si]
    fmul qword [si+26]
    fsub dword [si]
    fsubr qword [si+26]
    fdiv dword [si]
    fdivr qword [si+26]
    fiadd word [si+12]
    fimul dword [si+14]
    fisub word [si+12]
    fisubr dword [si+14]
    fidiv word [si+12]
    fidivr dword [si+14]
    fst  dword [bx]
    mov  ecx, [bx]
    fst  qword [bx]
    mov  ecx, [bx+4]
    G64
    fld1                        ; arithmetic between registers
    fld  qword [si+26]
    fld  qword [si+4]
    fadd st0, st1
    fmul st0, st2
    fsub st1, st0
    fsubr st2, st0
    fdiv st0, st1
    fdivr st1, st0
    fxch st2
    fld  st1
    faddp st2, st0
    fld  st0
    fsubp st2, st0
    fld  st1
    fsubrp st1, st0
    fld  st2
    fmulp st1, st0
    fld  st1
    fdivp st3, st0
    fld  st1
    fdivrp st2, st0
    G64
    G64
    G64
    fld  dword [si]             ; integer stores: -2.5 rounds to even, truncates toward zero
    fchs
    fsub dword [si+34]
    fist word [bx]
    mov  ax, [bx]
    fist dword [bx]
    mov  eax, [bx]
    fld  st0
    fistp qword [bx]
    mov  eax, [bx]
    mov  edx, [bx+4]
    fld  st0
    db   0xDB, 0x0F             ; fisttp dword [bx], which NASM keeps for SSE3 CPUs
    mov  eax, [bx]
    fabs
    fsqrt
    fld  st0
    fistp word [bx]
    mov  ax, [bx]
    G64
    fild qword [si+18]          ; too big for 16 and 32 bits: the integer indefinite
    fist word [bx]
    mov  ax, [bx]
    fistp dword [bx]
    mov  eax, [bx]
    fld  dword [si]             ; comparison: 1.5 against 0.1, itself, and a NaN
    fld  qword [si+4]
    fcom st1
    fnstsw ax
    fxch st1
    fcom qword [si+4]
    fnstsw ax
    fcom st0
    fnstsw ax
    fucomi st0, st1
    fcomi st0, st0
    fxch st1
    fcomi st0, st1
    ftst
    fnstsw ax
    fxam
    fnstsw ax
    fldz
    fxam
    fnstsw ax
    fdiv st0, st0               ; 0/0: a NaN
    fxam
    fnstsw ax
    fucomi st0, st1
    fucom st1
    fnstsw ax
    fcompp
    fnstsw ax
    fcmovnbe st0, st0
    fnstsw ax
    hlt
data:
    dd 1.5                      ; +0
    dq 0.1                      ; +4
    dw -7                       ; +12
    dd 100000                   ; +14
    dq 0x0123456789ABCDEF       ; +18
    dq 3.25                     ; +26
    dd 1.0                      ; +34
    dw 0x027F                   ; +38  53-bit precision
    TAIL
