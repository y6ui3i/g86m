; 文字列命令: MOVS CMPS SCAS STOS LODS、REP / REPE / REPNE、DF の両向き。
%include "common.inc"
start:
    HDR
    cld
    mov  si, src
    mov  di, dst
    mov  cx, 8
    rep  movsb
    mov  si, src
    mov  di, dst+16
    mov  cx, 4
    rep  movsw
    std
    mov  si, src+7
    mov  di, dst+40
    mov  cx, 8
    rep  movsb
    cld
    mov  di, dst
    mov  al, 'x'
    mov  cx, 5
    rep  stosb
    mov  ax, 0x1234
    mov  cx, 3
    rep  stosw
    mov  si, dst
    lodsb
    lodsw
    lodsw
    lodsw
    mov  si, src
    mov  di, src2
    mov  cx, 8
    repe cmpsb
    mov  si, src
    mov  di, src2
    mov  cx, 8
    repne cmpsb
    mov  si, src
    mov  di, src2
    mov  cx, 4
    repe cmpsw
    mov  di, src
    mov  al, 'e'
    mov  cx, 8
    repne scasb
    mov  di, same
    mov  al, 'z'
    mov  cx, 6
    repe scasb
    mov  di, src
    mov  ax, 'cd'
    mov  cx, 4
    repne scasw
    xor  cx, cx
    rep  movsb
    repe cmpsb
    repne scasb
    rep  stosw
    rep  lodsb
    mov  si, src
    mov  di, dst
    movsb
    movsw
    cmpsb
    cmpsw
    scasb
    scasw
    stosb
    stosw
    std
    lodsb
    lodsw
    scasw
    cmpsb
    movsw
    cld
    mov  ax, 0x07C0
    mov  es, ax
    mov  si, src - 0x7C00
    es   lodsb
    es   lodsw
    mov  di, dst
    mov  cx, 2
    rep  es movsb
    mov  cx, 3
    mov  si, 0x10
    rep  cs lodsb
    mov  ax, [dst]
    mov  bx, [dst+16]
    mov  cx, [dst+40]
    hlt
src:  db "abcdefgh"
src2: db "abcdeXgh"
same: db "zzzzQzzz"
dst:  times 48 db 0
    TAIL
