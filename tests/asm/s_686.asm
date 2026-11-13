; Self-check for what the i686 answers about itself; rustx86 claims more features, so these cannot
; be compared. Prints "OK" when all pass. Runs on the i686 (--cpu i686).
;   - CPUID leaf 0 names GenuineIntel; leaf 1 is family 6 with TSC, CX8 and CMOV and nothing else
;   - RDTSC goes up
;   - RDMSR is a general protection fault (vector 13): there are no model-specific registers
%define CPU686
%include "common.inc"
start:
    HDR
    xor  eax, eax
    cpuid
    cmp  eax, 1
    jne  .bad
    cmp  ebx, 0x756E6547
    jne  .bad
    cmp  edx, 0x49656E69
    jne  .bad
    cmp  ecx, 0x6C65746E
    jne  .bad
    mov  eax, 1
    cpuid
    cmp  eax, 0x0633
    jne  .bad
    cmp  edx, 0x00008110
    jne  .bad
    rdtsc
    mov  esi, eax
    rdtsc
    cmp  eax, esi
    jbe  .bad
    mov  word [13*4], gp
    mov  word [13*4+2], 0
    xor  bx, bx
    mov  ecx, 0x8B
    rdmsr
    cmp  bx, 1
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
gp:                             ; skip the two-byte instruction that faulted
    inc  bx
    push bp
    mov  bp, sp
    add  word [bp+2], 2
    pop  bp
    iret
    TAIL
