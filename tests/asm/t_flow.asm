; Branches, calls and interrupts. Each flags word in the table is loaded with POPF and all 16 conditions are tried.
%include "common.inc"
%macro JCC 1
    j%1  %%t
    nop
%%t:
%endmacro
start:
    HDR
    mov  si, tab
.next:
    cld                         ; a table value may set DF, so clear it before reading
    lodsw
    push ax
    popf
    pushf
    pop  bx
    JCC o
    JCC no
    JCC b
    JCC ae
    JCC e
    JCC ne
    JCC be
    JCC a
    JCC s
    JCC ns
    JCC p
    JCC np
    JCC l
    JCC ge
    JCC le
    JCC g
    cmp  si, tabend
    LOOP_BELOW .next
    cld

    mov  cx, 3
.l1:
    loop .l1
    mov  cx, 3
    xor  ax, ax
.l2:
    inc  ax
    cmp  ax, 2
    loopne .l2
    mov  cx, 3
.l3:
    cmp  ax, ax
    loope .l3
    jcxz .z
    nop
.z:
    inc  cx
    jcxz .z2
    nop
.z2:
    call near_fn
    push ax
    push ax
    call near_fn2               ; RET 4 discards the two argument words
    call 0x0000:far_fn
    push ax
    call 0x0000:far_fn2         ; RETF 2 discards the one argument word
    mov  bx, near_fn
    call bx
    call [ptr_near]
    call far [ptr_far]
    jmp  word [ptr_j]
j_back:
    jmp  far [ptr_jf]
jf_back:
    jmp  0x0000:.far2
.far2:
    jmp  near .n2
    nop
.n2:
    mov  word [0x80*4], h80
    mov  word [0x80*4+2], 0
    mov  word [4*4], h80
    mov  word [4*4+2], 0
    mov  word [3*4], h80
    mov  word [3*4+2], 0
    int  0x80
    int3
    mov  al, 0x7F
    add  al, 1
    into
    xor  ax, ax
    into
    hlt
near_fn:
    ret
near_fn2:
    ret  4
far_fn:
    retf
far_fn2:
    retf 2
h80:
    pushf
    pop  dx
    iret
ptr_near: dw near_fn
ptr_far:  dw far_fn, 0
ptr_j:    dw j_back
ptr_jf:   dw jf_back, 0
tab:
    dw 0x0000, 0x0001, 0x0040, 0x0041, 0x0080, 0x0800, 0x0880, 0x08C0
    dw 0x0004, 0x0CD5, 0x0481, 0x0844, 0xF02A, 0x0010
tabend:
    TAIL
