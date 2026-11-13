; 32-bit addressing (67h prefix): every ModR/M and SIB shape through LEA, then real loads to check
; which segment each form uses by default.
%define CPU386
%include "common.inc"
start:
    HDR
    mov  eax, 0x00001000
    mov  ebx, 0x00000400
    mov  ecx, 0x00000030
    mov  edx, 0x00000007
    mov  esi, 0x00000100
    mov  edi, 0x000000FE
    mov  ebp, 0x000003F0
    lea  eax, [ebx]
    lea  eax, [ecx]
    lea  eax, [edx]
    lea  eax, [esi]
    lea  eax, [edi]
    lea  eax, [ebp]
    lea  eax, [esp]
    lea  eax, [dword 0x12345678]
    lea  eax, [ebx+5]
    lea  eax, [ebp-5]
    lea  eax, [esp+0x7F]
    lea  eax, [esi-0x80]
    lea  eax, [ebx+0x12345678]
    lea  eax, [ebp+0xF0000000]
    lea  eax, [esp+0x00010000]
    lea  eax, [ebx+ecx]
    lea  eax, [ebx+ecx*2]
    lea  eax, [ebx+ecx*4]
    lea  eax, [ebx+ecx*8]
    lea  eax, [ebp+edx*4]
    lea  eax, [esp+esi*2]
    lea  eax, [ecx*4+0x100]
    lea  eax, [ebp*2]
    lea  eax, [ebx+edi*8+0x55]
    lea  eax, [ebp+esi*4-0x12]
    lea  eax, [esp+ebx*2+0x12345678]
    lea  eax, [edx+ebp*8+0x80000000]
    lea  ax, [ebx+ecx*4+0x12345678]
    lea  eax, [bx+si+0x1234]
    lea  eax, [bp+di-2]
    mov  ax, 0x1000
    mov  es, ax
    mov  ss, ax
    mov  sp, 0x7000
    mov  dword [0x500], 0x11112222
    mov  dword [es:0x500], 0x33334444
    mov  ebx, 0x500
    mov  ebp, 0x500
    mov  ecx, 2
    mov  eax, [ebx]
    mov  eax, [ebp]
    mov  eax, [ds:ebp]
    mov  eax, [ss:ebx]
    mov  ax, [ebx+ecx]
    mov  ax, [ebp+ecx]
    mov  ax, [ecx+ebp]
    mov  esp, 0x500
    mov  eax, [esp]
    mov  eax, [esp+ecx*1-2]
    mov  al, [ebx+ecx*2-1]
    mov  [ebx+ecx*4], eax
    mov  edx, [0x508]
    mov  esp, 0x7000
    mov  [dword 0x520], esp
    mov  eax, [dword 0x520]
    mov  eax, [dword es:0x500]
    a32 mov eax, [0x500]
    xor  ax, ax
    mov  ss, ax
    mov  es, ax
    hlt
    TAIL
