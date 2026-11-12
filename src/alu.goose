// Arithmetic and flags. Values travel as u32 and are cut to the width w (8 or 16).
// Undefined flags follow rustx86, which matches expected values taken from a real 386.

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

// Sign-extends to i64, for multiply and divide.
fn sx(v: u32, w: u8) -> i64 {
    if v & msb(w) != 0 { return (v as i64) - mask(w) - 1; }
    return v;
}

// op is the 3-bit field from the instruction: 0 ADD 1 OR 2 ADC 3 SBB 4 AND 5 SUB 6 XOR 7 CMP
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

// INC and DEC leave CF alone.
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
// The count uses its low 5 bits only, as on a 386. Plain one-bit-at-a-time implementation.
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
    // On paper OF is defined only for a count of 1. A real 386 updates it with the
    // same formula at every count for left rotates (ROL / RCL) only, and leaves it
    // untouched for right rotates and shifts unless the count is 1 (rustx86 found
    // this from test386's real-hardware expected values).
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
