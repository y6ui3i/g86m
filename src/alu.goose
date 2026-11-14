// Arithmetic and flags. Values travel as u32 and are cut to the width w (8, 16 or 32).
// Undefined flags follow rustx86, which matches expected values taken from a real 386.

import state;

inline fn mask(w: u8) -> u32 {
    if w == 8 { return 0xFF; }
    if w == 16 { return 0xFFFF; }
    return 0xFFFFFFFF;
}

inline fn msb(w: u8) -> u32 {
    if w == 8 { return 0x80; }
    if w == 16 { return 0x8000; }
    return 0x80000000;
}

inline fn parity8(v: u32) -> bool {
    var x = v & 0xFF;
    x ^= x >> 4;
    x ^= x >> 2;
    x ^= x >> 1;
    return x & 1 == 0;
}

// The parity flag for each value of a result's low byte: PF where the byte has an even number of
// one bits.
let PARITY: u8[256] = [
    4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0,
    0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4,
    0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4,
    4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0,
    0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4,
    4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0,
    4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0,
    0, 4, 4, 0, 4, 0, 0, 4, 4, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 4, 0, 4, 4, 0, 0, 4, 4, 0, 4, 0, 0, 4,
];

// The zero, sign and parity bits for a result, as they sit in EFLAGS.
inline fn szp(r: u32, w: u8) -> u32 {
    var f: u32 = PARITY[r & 0xFF];
    if r & mask(w) == 0 { f |= ZF; }
    if r & msb(w) != 0 { f |= SF; }
    return f;
}

inline fn set_szp(r: u32, w: u8) {
    cpu.flags = cpu.flags & 0xFFFFFF3B | szp(r, w);
}

// Sign-extends to i64, for multiply and divide.
inline fn sx(v: u32, w: u8) -> i64 {
    let wide: i64 = v & mask(w);
    let top: i64 = msb(w);
    if wide >= top { return wide - top - top; }
    return wide;
}

// op is the 3-bit field from the instruction: 0 ADD 1 OR 2 ADC 3 SBB 4 AND 5 SUB 6 XOR 7 CMP
inline fn alu(op: u8, a: u32, b: u32, w: u8) -> u32 {
    let m = mask(w);
    let s = msb(w);
    // The carry out of a 32-bit add does not fit in u32, so carries are worked out in u64.
    let a64: u64 = a;
    let b64: u64 = b;
    let m64: u64 = m;
    var r: u32 = 0;
    // The six arithmetic flags are gathered here and written to EFLAGS once.
    var f: u32 = 0;
    match op {
        0, 2 => {
            let c: u64 = if op == 2 && flag(CF) { 1 } else { 0 };
            let full = a64 + b64 + c;
            r = (full & m64) as! u32;
            if full > m64 { f |= CF; }
            if (a ^ r) & (b ^ r) & s != 0 { f |= OF; }
            f |= (a ^ b ^ r) & AF;
        },
        3, 5, 7 => {
            let c: u64 = if op == 3 && flag(CF) { 1 } else { 0 };
            r = ((a64 - b64 - c) & m64) as! u32;
            if a64 < b64 + c { f |= CF; }
            if (a ^ b) & (a ^ r) & s != 0 { f |= OF; }
            f |= (a ^ b ^ r) & AF;
        },
        _ => {
            if op == 1 { r = a | b; } else if op == 4 { r = a & b; } else { r = a ^ b; }
        },
    }
    cpu.flags = cpu.flags & 0xFFFFF72A | f | szp(r, w);
    return r;
}

// INC and DEC leave CF alone.
inline fn inc(a: u32, w: u8) -> u32 {
    let carry = flag(CF);
    let r = alu(0, a, 1, w);
    set_flag(CF, carry);
    return r;
}

inline fn dec(a: u32, w: u8) -> u32 {
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
    let bits: i64 = w;
    if kind >= 4 {
        // The shifts, in one step. What the loop below would leave: the last bit shifted out in
        // CF, and for an arithmetic right shift the sign bit copied into every place vacated.
        if kind == 5 {
            cf = n <= bits && v >> (n - 1) & 1 != 0;
            v = v >> n;
        } else if kind == 7 {
            let neg = v & s != 0;
            if n >= bits { cf = neg; v = if neg { m } else { 0 }; }
            else {
                cf = v >> (n - 1) & 1 != 0;
                v = v >> n;
                if neg { v |= m << (bits - n) & m; }
            }
        } else {
            cf = n <= bits && v >> (bits - n) & 1 != 0;
            v = v << n & m;
        }
        n = 0;
    }
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

// SHLD (left = true) and SHRD: shifts dst by count bits, filling from src.
fn shift_double(left: bool, dst0: u32, src0: u32, count: u8, w: u8) -> u32 {
    let m = mask(w);
    let s = msb(w);
    let n: i64 = count & 0x1F;
    if n == 0 { return dst0; }
    var dst = dst0 & m;
    var src = src0 & m;
    var cf = false;
    for i in n {
        if left {
            cf = dst & s != 0;
            dst = (dst << 1 | (if src & s != 0 { 1 } else { 0 })) & m;
            src = src << 1 & m;
        } else {
            cf = dst & 1 != 0;
            dst = dst >> 1 | (if src & 1 != 0 { s } else { 0 });
            src = src >> 1;
        }
    }
    // OF and AF are left as they were, which is what a real 386 does (rustx86, from test386).
    set_flag(CF, cf);
    set_szp(dst, w);
    return dst;
}

// ---- 32-bit shifts by a known count from 1 to 31, for the short executors ----
//
// The same results and flags as shift() gives: the last bit shifted out in CF, the result's zero,
// sign and parity, and OF only when the count is 1.

inline fn shl32(v: u32, n: u32) -> u32 {
    let r = v << n;
    let cf = v >> (32 - n) & 1;
    var f = cpu.flags & 0xFFFFFF3A | cf | szp(r, 32);
    if n == 1 { f = f & 0xFFFFF7FF | (if r >> 31 != cf { OF } else { 0 }); }
    cpu.flags = f;
    return r;
}

inline fn shr32(v: u32, n: u32) -> u32 {
    let r = v >> n;
    var f = cpu.flags & 0xFFFFFF3A | (v >> (n - 1) & 1) | szp(r, 32);
    if n == 1 { f = f & 0xFFFFF7FF | (v >> 20 & OF); }
    cpu.flags = f;
    return r;
}

inline fn sar32(v: u32, n: u32) -> u32 {
    var r = v >> n;
    if v >> 31 != 0 { r |= 0xFFFFFFFF << (32 - n); }
    var f = cpu.flags & 0xFFFFFF3A | (v >> (n - 1) & 1) | szp(r, 32);
    if n == 1 { f &= 0xFFFFF7FF; }
    cpu.flags = f;
    return r;
}
