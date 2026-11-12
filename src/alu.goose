// 演算とフラグ。値は u32 で運び、幅 w (8 か 16) で切る。
// 未定義フラグの値は rustx86 (386 実機の期待値に一致) に合わせる。

import state;

fn mask(w: u8) -> u32 { if w == 8 { return 0xFF; } return 0xFFFF; }
fn msb(w: u8) -> u32 { if w == 8 { return 0x80; } return 0x8000; }

fn parity8(v: u32) -> bool {
    var x = v & 0xFF;
    x ^= x >> 4;
    x ^= x >> 2;
    x ^= x >> 1;
    return x & 1 == 0;
}

fn set_szp(r: u32, w: u8) {
    set_flag(ZF, r & mask(w) == 0);
    set_flag(SF, r & msb(w) != 0);
    set_flag(PF, parity8(r));
}

// 符号拡張して i64 にする。乗除算用。
fn sx(v: u32, w: u8) -> i64 {
    if v & msb(w) != 0 { return (v as i64) - mask(w) - 1; }
    return v;
}

// op は命令の 3bit そのまま: 0 ADD 1 OR 2 ADC 3 SBB 4 AND 5 SUB 6 XOR 7 CMP
fn alu(op: u8, a: u32, b: u32, w: u8) -> u32 {
    let m = mask(w);
    let s = msb(w);
    var r: u32 = 0;
    match op {
        0, 2 => {
            let c: u32 = if op == 2 && flag(CF) { 1 } else { 0 };
            let full = a + b + c;
            r = full & m;
            set_flag(CF, full > m);
            set_flag(OF, (a ^ r) & (b ^ r) & s != 0);
            set_flag(AF, (a ^ b ^ r) & 0x10 != 0);
        },
        3, 5, 7 => {
            let c: u32 = if op == 3 && flag(CF) { 1 } else { 0 };
            r = (a - b - c) & m;
            set_flag(CF, a < b + c);
            set_flag(OF, (a ^ b) & (a ^ r) & s != 0);
            set_flag(AF, (a ^ b ^ r) & 0x10 != 0);
        },
        _ => {
            if op == 1 { r = a | b; } else if op == 4 { r = a & b; } else { r = a ^ b; }
            set_flag(CF, false);
            set_flag(OF, false);
            set_flag(AF, false);
        },
    }
    set_szp(r, w);
    return r;
}

// INC / DEC は CF を変えない。
fn inc(a: u32, w: u8) -> u32 {
    let carry = flag(CF);
    let r = alu(0, a, 1, w);
    set_flag(CF, carry);
    return r;
}

fn dec(a: u32, w: u8) -> u32 {
    let carry = flag(CF);
    let r = alu(5, a, 1, w);
    set_flag(CF, carry);
    return r;
}

// kind: 0 ROL 1 ROR 2 RCL 3 RCR 4 SHL 5 SHR 6 SAL 7 SAR
// 回数は 386 と同じく下位 5bit だけ見る。1bit ずつ回す素直な実装。
fn shift(kind: u8, v0: u32, count: u8, w: u8) -> u32 {
    let m = mask(w);
    let s = msb(w);
    var n: i64 = count & 0x1F;
    if n == 0 { return v0; }
    var v = v0 & m;
    var cf = flag(CF);
    if kind == 2 || kind == 3 { n = n % ((w as i64) + 1); }
    for i in n {
        match kind {
            0 => { cf = v & s != 0; v = (v << 1 | (if cf { 1 } else { 0 })) & m; },
            1 => { cf = v & 1 != 0; v = v >> 1 | (if cf { s } else { 0 }); },
            2 => { let out = v & s != 0; v = (v << 1 | (if cf { 1 } else { 0 })) & m; cf = out; },
            3 => { let out = v & 1 != 0; v = v >> 1 | (if cf { s } else { 0 }); cf = out; },
            4, 6 => { cf = v & s != 0; v = v << 1 & m; },
            5 => { cf = v & 1 != 0; v = v >> 1; },
            _ => { cf = v & 1 != 0; v = v >> 1 | v & s; },
        }
    }
    set_flag(CF, cf);
    // OF は紙の上では回数 1 のときだけ定義。実 386 は左回転 (ROL / RCL) だけ
    // 全回数で同じ式のまま更新し、右回転とシフトは回数 1 以外では触らない
    // (rustx86 が test386 の実機期待値から突き止めた挙動)。
    if count & 0x1F == 1 || kind == 0 || kind == 2 {
        match kind {
            0, 2, 4, 6 => { set_flag(OF, (v & s != 0) != cf); },
            1, 3 => { set_flag(OF, (v ^ v << 1) & s != 0); },
            5 => { set_flag(OF, v0 & s != 0); },
            _ => { set_flag(OF, false); },
        }
    }
    if kind >= 4 { set_szp(v, w); }
    return v;
}
