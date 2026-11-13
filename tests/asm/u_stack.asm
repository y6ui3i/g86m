; 32-bit forms of stack, flag, string and control-transfer instructions in real mode.
%define CPU386
%include "common.inc"
start:
    HDR
    mov  eax, 0x11112222
    mov  ebx, 0x33334444
    mov  ecx, 0x55556666
    mov  edx, 0x77778888
    mov  esi, 0x9999AAAA
    mov  edi, 0xBBBBCCCC
    mov  ebp, 0xDDDDEEEE
    push eax
    push dword 0x12345678
    push dword -2
    pop  ebx
    pop  ecx
    pop  edx
    push esp
    pop  eax
    push sp
    pop  ax
    pushad
    xor  eax, eax
    mov  ebx, eax
    mov  esi, eax
    mov  ebp, eax
    popad
    pushfd
    pop  eax
    mov  eax, 0x00000CD5
    push eax
    popfd
    pushfd
    pop  ebx
    mov  eax, 0x00007002
    push eax
    popfd
    pushf
    pop  bx
    xor  eax, eax
    push eax
    popfd
    o32 push ds
    pop  eax
    o32 push es
    o32 pop es
    enter 8, 0
    leave
    o32 enter 12, 0
    o32 leave
    o32 enter 4, 2
    o32 leave
    mov  ebp, 0xDDDDEEEE
    xchg eax, ebx
    xchg eax, esp
    xchg eax, esp
    xchg ecx, [mem]
    mov  [mem], edi
    mov  eax, [mem]
    cld
    mov  si, src
    mov  di, dst
    movsd
    mov  si, src
    mov  di, dst
    cmpsd
    mov  eax, 0xCAFEF00D
    mov  di, dst
    mov  cx, 3
    rep  stosd
    mov  si, dst
    lodsd
    mov  di, dst
    scasd
    mov  esi, src
    mov  edi, dst
    mov  ecx, 0x00000003         ; a count above FFFFh would run past the 64 KB segment and fault
    a32 rep movsw
    mov  ecx, 0x00020002
    rep  movsb
    mov  ecx, 0x00010000
    jcxz .z1
    nop
.z1:
    jecxz .z2
    nop
.z2:
    mov  ecx, 0x00010002
.l1:
    loop .l1
    mov  ecx, 0x00000002
.l2:
    a32 loop .l2
    call dword near32
    call near16
    call dword 0x0000:far32
    push word 0x0002
    push cs
    push word .back
    iret
.back:
    mov  bx, tblx
    mov  al, 2
    xlatb
    mov  ebx, tblx
    mov  al, 1
    a32 xlatb
    smsw ax
    mov  eax, cr0
    sidt [mem]
    mov  eax, [mem+2]           ; the base only: rustx86 starts the IDT limit at 0, a 386 at 3FFh
    hlt
near32:
    retd
near16:
    ret
far32:
    retfd
mem: dd 0, 0
src: db "abcdefgh"
dst: times 16 db 0
tblx: db 10, 20, 30, 40
    TAIL
