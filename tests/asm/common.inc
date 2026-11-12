; Shared opening for every test. Interrupts stay disabled: a timer interrupt would shift the trace.
org 0x7C00
bits 16
cpu 186
; The backward branch of a table loop is over 127 bytes, so invert the condition and go back with a near JMP.
%macro LOOP_BELOW 1
    jnb  %%done
    jmp  %1
%%done:
%endmacro
%macro HDR 0
    cli
    xor  ax, ax
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  sp, 0x7C00
%endmacro
%macro TAIL 0
    times 510-($-$$) db 0
    dw 0xAA55
%endmacro
