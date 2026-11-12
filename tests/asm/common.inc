; 全テスト共通の出だし。割り込みは禁止のまま (タイマ割り込みが入るとトレースがずれる)。
org 0x7C00
bits 16
cpu 186
; 表を回すループの戻りは 127 バイトを超えるので、条件を裏返して near JMP で戻る。
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
