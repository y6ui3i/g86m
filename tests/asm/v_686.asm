; Instructions the 486, the Pentium and the P6 added: CMPXCHG, XADD, BSWAP, CMPXCHG8B, CMOVcc, the
; long NOP, and the AC and ID bits of EFLAGS. Runs on the i686 (--cpu i686).
%define CPU686
%include "common.inc"
%macro CMOVS 0
    cmovo  eax, ebx
    cmovno ecx, ebx
    cmovb  edx, ebx
    cmovae esi, ebx
    cmove  edi, ebx
    cmovne ebp, ebx
    cmovbe ax, bx
    cmova  cx, bx
    cmovs  edx, [mem]
    cmovns esi, [mem]
    cmovp  edi, ebx
    cmovnp ebp, ebx
    cmovl  eax, ebx
    cmovge ecx, ebx
    cmovle edx, ebx
    cmovg  esi, ebx
%endmacro
start:
    HDR
    mov  eax, 5
    mov  ebx, 5
    mov  ecx, 9
    cmpxchg ebx, ecx
    cmpxchg ebx, ecx
    mov  dword [mem], 0x11223344
    mov  eax, 0x11223344
    mov  edx, 0xAABBCCDD
    lock cmpxchg [mem], edx
    mov  esi, [mem]
    cmpxchg [mem], cx
    mov  esi, [mem]
    mov  al, [mem]
    cmpxchg [mem], cl
    cmpxchg [mem], ch
    mov  esi, [mem]
    mov  eax, 0x7FFFFFFF
    mov  ebx, 1
    xadd eax, ebx
    xadd [mem], ecx
    lock xadd [mem], dx
    xadd al, bl
    mov  esi, [mem]
    mov  eax, 0x12345678
    bswap eax
    bswap ebx
    bswap edi
    mov  si, tab
.next:
    cld
    lodsw
    push ax
    popf
    mov  ebx, 0xB0B0B0B0
    mov  dword [mem], 0xC1C1C1C1
    xor  eax, eax
    mov  ecx, eax
    mov  edx, eax
    mov  edi, eax
    mov  ebp, eax
    push si
    mov  esi, eax
    CMOVS
    pop  si
    cmp  si, tabend
    LOOP_BELOW .next
    mov  dword [m8], 1
    mov  dword [m8+4], 2
    mov  eax, 1
    mov  edx, 2
    mov  ebx, 0xAAAA5555
    mov  ecx, 0x12345678
    lock cmpxchg8b [m8]
    mov  esi, [m8]
    mov  edi, [m8+4]
    cmpxchg8b [m8]
    nop  dword [eax]
    nop  word [bx+si+0x1234]
    mov  eax, 0x00240000
    push eax
    popfd
    pushfd
    pop  ebx
    push dword 0
    popfd
    pushfd
    pop  ebx
    hlt
mem: dd 0
m8:  dd 0, 0
tab: dw 0x0000, 0x0001, 0x0040, 0x0041, 0x0080, 0x0800, 0x0880, 0x08C0, 0x0004, 0x0CD5
tabend:
    TAIL
