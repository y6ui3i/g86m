; A loop of one instruction (or a few) in 32-bit protected mode, to count what the interpreter
; spends on it. Assemble with the body given on the command line:
;   nasm -f bin -DBODY="mov eax, [ebx+8]" -o build/bench32.bin probe/bench32.asm
; and run it under /usr/bin/time -l, which reports the host instructions retired. The loop is
; ITER times: BODY, DEC ECX, JNZ. An empty BODY gives the cost of the loop itself.
%ifndef ITER
%define ITER 20000000
%endif
org 0x7C00
bits 16
    cli
    xor  ax, ax
    mov  ds, ax
    lgdt [gdtr]
    mov  eax, cr0
    or   al, 1
    mov  cr0, eax
    jmp  0x08:start32
bits 32
start32:
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  esp, 0x7000
    mov  ebx, 0x8000
    mov  esi, 0x9000
    mov  edi, 0xA000
    mov  ecx, ITER
    align 16
.loop:
%ifdef BODY
    BODY
%endif
    dec  ecx
    jnz  .loop
    hlt
fn:
    ret
align 8
gdt:
    dq 0
    dq 0x00CF9A000000FFFF
    dq 0x00CF92000000FFFF
gdtr:
    dw 23
    dd gdt
    times 510-($-$$) db 0
    dw 0xAA55
