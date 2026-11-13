// Instruction execution: a 386 in real mode. Operands are 16 bits and addresses 16 bits unless the
// 66h and 67h prefixes say otherwise. To software that asks, the machine is a 386 with no FPU and
// no CPUID: FLAGS bits 12-14 can be written and PUSH SP pushes the value from before the decrement.

import state;
import alu;
import bios;
import dev;

// ---- Decode state that lives for one instruction ----

var seg_ovr = -1;            // segment override: -1 none, else ES CS SS DS FS GS
var rep: u8 = 0;             // 0 none, 1 REPNE (F2), 2 REP/REPE (F3)
var osz: u8 = 16;            // operand size of this instruction: 16 or 32
var asz32 = false;           // this instruction addresses memory with 32-bit offsets
var shadow = false;          // the instruction just executed holds interrupts off for one more
var insn_ip: u32 = 0;        // start of the instruction, prefixes included; where a fault returns to
var m_mod: u8 = 0;
var m_reg: u8 = 0;
var m_rm: u8 = 0;
var ea_seg = DS;             // segment register of the effective address
var ea_off: u32 = 0;

// ---- Control registers and descriptor table registers (stored; protected mode is not there yet) ----

var cr: u32[8] = [0; 8];     // CR0 starts at zero: no coprocessor, so the ET bit is clear
var gdtr_base: u32 = 0;
var gdtr_limit: u16 = 0;
var idtr_base: u32 = 0;
var idtr_limit: u16 = 0x3FF;

// ---- Fetch ----

// In real mode the instruction pointer is 16 bits.
fn advance(n: u32) { cpu.ip = (cpu.ip + n) & 0xFFFF; }

fn fetch8() -> u8 {
    let b = seg_read(CS, cpu.ip, 8) as! u8;
    advance(1);
    return b;
}

fn fetch16() -> u32 {
    let lo: u32 = fetch8();
    let hi: u32 = fetch8();
    return lo | hi << 8;
}

fn fetch32() -> u32 {
    let lo = fetch16();
    let hi = fetch16();
    return lo | hi << 16;
}

// An immediate or displacement of the operand size.
fn fetchv() -> u32 {
    if osz == 16 { return fetch16(); }
    return fetch32();
}

fn fetchw(w: u8) -> u32 {
    if w == 8 { return fetch8(); }
    if w == 16 { return fetch16(); }
    return fetch32();
}

// A byte, sign-extended to 32 bits.
fn fetch_s8() -> u32 { return (fetch8() as! i8) as! u32; }

// ---- Operands ----

// The default segment def, replaced by an override prefix when there is one.
fn seg_of(def: i64) -> i64 {
    if seg_ovr >= 0 { return seg_ovr; }
    return def;
}

fn decode_modrm() {
    let m = fetch8();
    m_mod = m >> 6;
    m_reg = m >> 3 & 7;
    m_rm = m & 7;
    if m_mod == 3 { return; }
    var def = DS;
    var off: u32 = 0;
    if !asz32 {
        var o: u16 = 0;
        match m_rm {
            0 => { o = r16(BX) + r16(SI); },
            1 => { o = r16(BX) + r16(DI); },
            2 => { o = r16(BP) + r16(SI); def = SS; },
            3 => { o = r16(BP) + r16(DI); def = SS; },
            4 => { o = r16(SI); },
            5 => { o = r16(DI); },
            6 => { if m_mod == 0 { o = fetch16() as! u16; } else { o = r16(BP); def = SS; } },
            _ => { o = r16(BX); },
        }
        if m_mod == 1 { o += fetch_s8() as! u16; } else if m_mod == 2 { o += fetch16() as! u16; }
        off = o;
    } else {
        if m_rm == 4 {
            let sib = fetch8();
            let scale = sib >> 6;
            let index = sib >> 3 & 7;
            let base = sib & 7;
            if base == 5 && m_mod == 0 { off = fetch32(); }
            else {
                off = r32(base);
                if base == 4 || base == 5 { def = SS; }
            }
            if index != 4 { off += r32(index) << scale; }
        }
        else if m_rm == 5 && m_mod == 0 { off = fetch32(); }
        else {
            off = r32(m_rm);
            if m_rm == 5 { def = SS; }
        }
        if m_mod == 1 { off += fetch_s8(); } else if m_mod == 2 { off += fetch32(); }
    }
    ea_off = off;
    ea_seg = seg_of(def);
}

fn rm_read(w: u8) -> u32 {
    if m_mod == 3 { return regw(m_rm, w); }
    return seg_read(ea_seg, ea_off, w);
}

fn rm_write(w: u8, v: u32) {
    if m_mod == 3 { set_regw(m_rm, w, v); } else { seg_write(ea_seg, ea_off, w, v); }
}

// The width of an instruction whose low opcode bit selects byte or word.
fn width(op: u8) -> u8 { if op & 1 == 0 { return 8; } return osz; }

fn cond(c: u8) -> bool {
    let r = match c >> 1 {
        0 => flag(OF),
        1 => flag(CF),
        2 => flag(ZF),
        3 => flag(CF) || flag(ZF),
        4 => flag(SF),
        5 => flag(PF),
        6 => flag(SF) != flag(OF),
        _ => flag(ZF) || (flag(SF) != flag(OF)),
    };
    if c & 1 != 0 { return !r; }
    return r;
}

// ---- Stack and control transfer, at the operand size ----

fn pushv(v: u32) { if osz == 16 { push16(v as! u16); } else { push32(v); } }
fn popv() -> u32 { if osz == 16 { return pop16(); } return pop32(); }

// A jump target is cut to 16 bits when the operand size is 16.
fn set_ip(v: u32) { cpu.ip = if osz == 16 { v & 0xFFFF } else { v }; }

fn jump_rel8(taken: bool) {
    let d = fetch_s8();
    if taken { set_ip(cpu.ip + d); }
}

// A fault that returns to the start of the instruction: divide error (0), invalid opcode (6).
fn fault(n: u8) {
    cpu.ip = insn_ip;
    interrupt(n);
}

fn far_call(seg: u16, off: u32) {
    pushv(cpu.segs[CS]);
    pushv(cpu.ip);
    set_seg(CS, seg);
    set_ip(off);
}

// ---- Registers used as addresses and counters: 16 or 32 bits by the address size ----

fn addr_reg(i: u8) -> u32 { if asz32 { return r32(i); } return r16(i); }

fn addr_reg_add(i: u8, d: u32) {
    if asz32 { set_r32(i, r32(i) + d); } else { set_r16(i, r16(i) + (d as! u16)); }
}

// ---- String instructions (A4..A7, AA..AF, 6C..6F) ----

fn string_op(op: u8) {
    let w = width(op);
    let n: u32 = (w as u32) / 8;
    let d: u32 = if flag(DF) { 0 - n } else { n };
    let kind = op & 0xFE;
    let src = seg_of(DS);
    loop {
        if rep != 0 && addr_reg(CX) == 0 { break; }
        match kind {
            0xA4 => {
                seg_write(ES, addr_reg(DI), w, seg_read(src, addr_reg(SI), w));
                addr_reg_add(SI, d);
                addr_reg_add(DI, d);
            },
            0xA6 => {
                let a = seg_read(src, addr_reg(SI), w);
                let b = seg_read(ES, addr_reg(DI), w);
                alu(7, a, b, w);
                addr_reg_add(SI, d);
                addr_reg_add(DI, d);
            },
            0xAA => {
                seg_write(ES, addr_reg(DI), w, regw(0, w));
                addr_reg_add(DI, d);
            },
            0xAC => {
                set_regw(0, w, seg_read(src, addr_reg(SI), w));
                addr_reg_add(SI, d);
            },
            0xAE => {
                alu(7, regw(0, w), seg_read(ES, addr_reg(DI), w), w);
                addr_reg_add(DI, d);
            },
            0x6C => {
                seg_write(ES, addr_reg(DI), w, port_read(r16(DX), w));
                addr_reg_add(DI, d);
            },
            _ => {
                port_write(r16(DX), w, seg_read(src, addr_reg(SI), w));
                addr_reg_add(SI, d);
            },
        }
        if rep == 0 { break; }
        addr_reg_add(CX, 0xFFFFFFFF);
        if kind == 0xA6 || kind == 0xAE {
            if rep == 2 && !flag(ZF) { break; }
            if rep == 1 && flag(ZF) { break; }
        }
    }
}

// ---- I/O at a width ----

fn port_read(port: u16, w: u8) -> u32 {
    if w == 8 { return port_in8(port); }
    if w == 16 { return port_in(port); }
    let lo: u32 = port_in(port);
    let hi: u32 = port_in(port + 2);
    return lo | hi << 16;
}

fn port_write(port: u16, w: u8, v: u32) {
    if w == 8 { port_out8(port, v as! u8); }
    else if w == 16 { port_out(port, v as! u16); }
    else { port_out(port, v as! u16); port_out(port + 2, (v >> 16) as! u16); }
}

// ---- Multiply and divide ----

// Signed multiply of two values of width w; stores nothing. Returns the product and sets CF and OF
// when the product does not fit in w bits.
fn imul(a: u32, b: u32, w: u8) -> i64 {
    let p = sx(a, w) * sx(b, w);
    let low = sx(p as! u32, w);
    set_flag(CF, p != low);
    set_flag(OF, p != low);
    return p;
}

// F6 / F7: TEST NOT NEG MUL IMUL DIV IDIV
fn group3(op: u8) {
    let w = width(op);
    decode_modrm();
    let v = rm_read(w);
    match m_reg {
        0, 1 => { alu(4, v, fetchw(w), w); },
        2 => { rm_write(w, ~v & mask(w)); },
        3 => { rm_write(w, alu(5, 0, v, w)); },
        4 => {
            // Never multiply a call that returns a narrower type by a wider value directly
            // (docs/goose-notes.md, item 1): operands go through typed locals first.
            let a: u64 = regw(0, w);
            let b: u64 = v;
            let p = a * b;
            let high: u64 = if w == 8 { p >> 8 } else if w == 16 { p >> 16 } else { p >> 32 };
            if w == 8 { set_r16(AX, p as! u16); }
            else { set_regw(AX, w, (p & 0xFFFFFFFF) as! u32); set_regw(DX, w, (high & 0xFFFFFFFF) as! u32); }
            let m: u64 = mask(w);
            set_flag(CF, high & m != 0);
            set_flag(OF, high & m != 0);
        },
        5 => {
            let p = imul(regw(0, w), v, w);
            if w == 8 { set_r16(AX, p as! u16); }
            else if w == 16 { set_r16(AX, p as! u16); set_r16(DX, (p >> 16) as! u16); }
            else { set_r32(AX, p as! u32); set_r32(DX, (p >> 32) as! u32); }
        },
        6 => {
            if v == 0 { fault(0); return; }
            let d: u64 = v;
            var n: u64 = 0;
            if w == 8 { n = r16(AX); }
            else if w == 16 { let hi: u64 = r16(DX); let lo: u64 = r16(AX); n = hi << 16 | lo; }
            else { let hi: u64 = r32(DX); let lo: u64 = r32(AX); n = hi << 32 | lo; }
            let q = n / d;
            let limit: u64 = mask(w);
            if q > limit { fault(0); return; }
            let r = n - q * d;
            if w == 8 { set_r8(0, q as! u8); set_r8(4, r as! u8); }
            else { set_regw(AX, w, q as! u32); set_regw(DX, w, r as! u32); }
        },
        _ => {
            if v == 0 { fault(0); return; }
            let d = sx(v, w);
            var n: i64 = 0;
            if w == 8 { n = sx(r16(AX), 16); }
            else if w == 16 { let hi = sx(r16(DX), 16); let lo: i64 = r16(AX); n = hi * 65536 + lo; }
            else {
                let hi: u64 = r32(DX);
                let lo: u64 = r32(AX);
                // The one quotient that does not fit in i64 either.
                if hi == 0x80000000 && lo == 0 && d == -1 { fault(0); return; }
                n = (hi << 32 | lo) as! i64;
            }
            let q = n / d;
            let top: i64 = msb(w);
            if q < 0 - top || q >= top { fault(0); return; }
            let r = n - q * d;
            if w == 8 { set_r8(0, q as! u8); set_r8(4, r as! u8); }
            else { set_regw(AX, w, q as! u32); set_regw(DX, w, r as! u32); }
        },
    }
}

// FE / FF: INC DEC CALL CALLF JMP JMPF PUSH
fn group45(op: u8) {
    let w = width(op);
    decode_modrm();
    if m_reg == 0 { rm_write(w, inc(rm_read(w), w)); return; }
    if m_reg == 1 { rm_write(w, dec(rm_read(w), w)); return; }
    if w == 8 { fault(6); return; }
    match m_reg {
        2 => { let t = rm_read(osz); pushv(cpu.ip); set_ip(t); },
        3 => {
            if m_mod == 3 { fault(6); return; }
            let off = seg_read(ea_seg, ea_off, osz);
            far_call(seg_read(ea_seg, ea_off + (osz as u32) / 8, 16) as! u16, off);
        },
        4 => { set_ip(rm_read(osz)); },
        5 => {
            if m_mod == 3 { fault(6); return; }
            let off = seg_read(ea_seg, ea_off, osz);
            set_seg(CS, seg_read(ea_seg, ea_off + (osz as u32) / 8, 16) as! u16);
            set_ip(off);
        },
        6 => { pushv(rm_read(osz)); },
        _ => { fault(6); },
    }
}

// ---- BCD adjustment ----

fn daa_das(sub: bool) {
    let old = r8(0);
    let old_cf = flag(CF);
    var al = old;
    var cf = false;
    if old & 0x0F > 9 || flag(AF) {
        if sub { cf = old_cf || al < 6; al -= 6; } else { cf = old_cf || al > 0xF9; al += 6; }
        set_flag(AF, true);
    } else {
        set_flag(AF, false);
    }
    if old > 0x99 || old_cf {
        if sub { al -= 0x60; } else { al += 0x60; }
        cf = true;
    }
    set_r8(0, al);
    set_flag(CF, cf);
    set_szp(al, 8);
}

fn aaa_aas(sub: bool) {
    if r8(0) & 0x0F > 9 || flag(AF) {
        if sub { set_r16(AX, r16(AX) - 6); set_r8(4, r8(4) - 1); }
        else { set_r16(AX, r16(AX) + 6); set_r8(4, r8(4) + 1); }
        set_flag(AF, true);
        set_flag(CF, true);
    } else {
        set_flag(AF, false);
        set_flag(CF, false);
    }
    set_r8(0, r8(0) & 0x0F);
}

// ---- Two-byte instructions (0Fh) ----

// Loads a far pointer from memory into a general register and a segment register (LES LDS LSS LFS LGS).
fn load_far(s: i64) {
    decode_modrm();
    if m_mod == 3 { fault(6); return; }
    let off = seg_read(ea_seg, ea_off, osz);
    let sel = seg_read(ea_seg, ea_off + (osz as u32) / 8, 16) as! u16;
    set_regw(m_reg, osz, off);
    set_seg(s, sel);
    if s == SS { shadow = true; }
}

// BT BTS BTR BTC. action: 0 test only, 1 set, 2 reset, 3 complement.
fn bit_op(action: u8, bit: u32, from_register: bool) {
    let w = osz;
    var index = bit & ((w as u32) - 1);
    if m_mod != 3 && from_register {
        // A bit offset in a register reaches outside the operand: the address moves by whole
        // operands, signed.
        let words = sx(bit, w) >> (if w == 16 { 4 } else { 5 });
        ea_off += (words * ((w as i64) / 8)) as! u32;
        if !asz32 { ea_off &= 0xFFFF; }
    }
    let v = rm_read(w);
    let m: u32 = 1 << index;
    set_flag(CF, v & m != 0);
    if action == 1 { rm_write(w, v | m); }
    else if action == 2 { rm_write(w, v & ~m); }
    else if action == 3 { rm_write(w, v ^ m); }
}

fn two_byte() {
    let op = fetch8();
    match op {
        0x00 => { fault(6); },                               // SLDT STR LLDT LTR VERR VERW: not in real mode
        0x01 => {
            decode_modrm();
            match m_reg {
                0, 1 => {                                    // SGDT, SIDT
                    if m_mod == 3 { fault(6); return; }
                    seg_write(ea_seg, ea_off, 16, if m_reg == 0 { gdtr_limit } else { idtr_limit });
                    seg_write(ea_seg, ea_off + 2, 32, if m_reg == 0 { gdtr_base } else { idtr_base });
                },
                2, 3 => {                                    // LGDT, LIDT
                    if m_mod == 3 { fault(6); return; }
                    let limit = seg_read(ea_seg, ea_off, 16) as! u16;
                    var base = seg_read(ea_seg, ea_off + 2, 32);
                    if osz == 16 { base &= 0x00FFFFFF; }
                    if m_reg == 2 { gdtr_limit = limit; gdtr_base = base; }
                    else { idtr_limit = limit; idtr_base = base; }
                },
                4 => { rm_write(if m_mod == 3 { osz } else { 16 }, cr[0] & (if m_mod == 3 && osz == 32 { 0xFFFFFFFF } else { 0xFFFF })); },
                6 => {                                       // LMSW: can set PE, cannot clear it
                    let v = rm_read(16);
                    if v & 1 != 0 { cpu.ip = insn_ip; stop("protected mode (LMSW) is not implemented", 1); return; }
                    cr[0] = cr[0] & 0xFFFFFFF1 | v & 0x0E;
                },
                _ => { fault(6); },
            }
        },
        0x02, 0x03 => { fault(6); },                         // LAR, LSL: not in real mode
        0x06 => { cr[0] &= 0xFFFFFFF7; },                    // CLTS
        0x0B => { fault(6); },                               // UD2
        0x20 => { decode_modrm(); set_r32(m_rm, cr[m_reg]); },
        0x22 => {
            decode_modrm();
            let v = r32(m_rm);
            if m_reg == 0 && v & 0x80000001 != 0 {
                cpu.ip = insn_ip;
                stop("protected mode or paging (MOV CR0) is not implemented", 0);
                return;
            }
            cr[m_reg] = v;
        },
        0x21, 0x23 => { decode_modrm(); if op == 0x21 { set_r32(m_rm, 0); } },     // debug registers
        0x80..0x90 => {
            let d = if osz == 16 { ((fetch16() as! u16) as! i16) as! u32 } else { fetch32() };
            if cond(op & 0x0F) { set_ip(cpu.ip + d); }
        },
        0x90..0xA0 => { decode_modrm(); rm_write(8, if cond(op & 0x0F) { 1 } else { 0 }); },
        0xA0 => { pushv(cpu.segs[FS]); },
        0xA1 => { set_seg(FS, popv() as! u16); },
        0xA8 => { pushv(cpu.segs[GS]); },
        0xA9 => { set_seg(GS, popv() as! u16); },
        0xA3 => { decode_modrm(); bit_op(0, regw(m_reg, osz), true); },
        0xAB => { decode_modrm(); bit_op(1, regw(m_reg, osz), true); },
        0xB3 => { decode_modrm(); bit_op(2, regw(m_reg, osz), true); },
        0xBB => { decode_modrm(); bit_op(3, regw(m_reg, osz), true); },
        0xBA => {
            decode_modrm();
            let bit: u32 = fetch8();
            if m_reg < 4 { fault(6); return; }
            bit_op(m_reg - 4, bit, false);
        },
        0xA4, 0xAC => {
            decode_modrm();
            let n = fetch8();
            rm_write(osz, shift_double(op == 0xA4, rm_read(osz), regw(m_reg, osz), n, osz));
        },
        0xA5, 0xAD => {
            decode_modrm();
            rm_write(osz, shift_double(op == 0xA5, rm_read(osz), regw(m_reg, osz), r8(1), osz));
        },
        0xAF => {
            decode_modrm();
            let p = imul(regw(m_reg, osz), rm_read(osz), osz);
            set_regw(m_reg, osz, p as! u32);
        },
        0xB2 => { load_far(SS); },
        0xB4 => { load_far(FS); },
        0xB5 => { load_far(GS); },
        0xB6 => { decode_modrm(); set_regw(m_reg, osz, rm_read(8)); },
        0xB7 => { decode_modrm(); set_regw(m_reg, osz, rm_read(16)); },
        0xBE => { decode_modrm(); set_regw(m_reg, osz, sx(rm_read(8), 8) as! u32); },
        0xBF => { decode_modrm(); set_regw(m_reg, osz, sx(rm_read(16), 16) as! u32); },
        0xBC, 0xBD => {                                      // BSF, BSR
            decode_modrm();
            let v = rm_read(osz);
            set_flag(ZF, v == 0);
            if v != 0 {
                var i: u32 = if op == 0xBC { 0 } else { (osz as u32) - 1 };
                loop {
                    if v >> i & 1 != 0 { break; }
                    if op == 0xBC { i += 1; } else { i -= 1; }
                }
                set_regw(m_reg, osz, i);
            }
        },
        // Instructions from the 486 on (CPUID, CMPXCHG, XADD, BSWAP, RDTSC ...) are invalid here.
        0xA2, 0xB0, 0xB1, 0xC0, 0xC1, 0xC8..0xD0, 0x31 => { fault(6); },
        _ => { cpu.ip = insn_ip; stop("unimplemented opcode 0F", op); },
    }
}

// ---- One instruction ----

fn step() {
    // At a BIOS entry: perform the service instead of fetching an instruction, then IRET.
    if cpu.segs[CS] == BIOS_SEG && cpu.ip < 256 {
        bios_call(cpu.ip as! u8);
        iret();
        if bios_idle {
            // The service is waiting for an interrupt. A real BIOS waits with interrupts on,
            // whatever the caller's IF was.
            bios_idle = false;
            set_flag(IF, true);
            cpu.halted = true;
        }
        return;
    }

    insn_ip = cpu.ip;
    shadow = false;
    seg_ovr = -1;
    rep = 0;
    osz = 16;
    asz32 = false;
    var op = fetch8();
    loop {
        match op {
            0x26 => { seg_ovr = ES; },
            0x2E => { seg_ovr = CS; },
            0x36 => { seg_ovr = SS; },
            0x3E => { seg_ovr = DS; },
            0x64 => { seg_ovr = FS; },
            0x65 => { seg_ovr = GS; },
            0x66 => { osz = 32; },
            0x67 => { asz32 = true; },
            0xF2 => { rep = 1; },
            0xF3 => { rep = 2; },
            0xF0 => {},
            _ => { break; },
        }
        op = fetch8();
    }

    // In 00..3F, opcodes whose low 3 bits are 0..5 are the 8 operations in 6 forms.
    if op < 0x40 && op & 7 < 6 {
        let aop = op >> 3;
        let w = width(op);
        match op & 7 {
            0, 1 => {
                decode_modrm();
                let r = alu(aop, rm_read(w), regw(m_reg, w), w);
                if aop != 7 { rm_write(w, r); }
            },
            2, 3 => {
                decode_modrm();
                let r = alu(aop, regw(m_reg, w), rm_read(w), w);
                if aop != 7 { set_regw(m_reg, w, r); }
            },
            _ => {
                let r = alu(aop, regw(0, w), fetchw(w), w);
                if aop != 7 { set_regw(0, w, r); }
            },
        }
        return;
    }

    match op {
        0x06 => { pushv(cpu.segs[ES]); },
        0x07 => { set_seg(ES, popv() as! u16); },
        0x0E => { pushv(cpu.segs[CS]); },
        0x0F => { two_byte(); },
        0x16 => { pushv(cpu.segs[SS]); },
        0x17 => { set_seg(SS, popv() as! u16); shadow = true; },
        0x1E => { pushv(cpu.segs[DS]); },
        0x1F => { set_seg(DS, popv() as! u16); },
        0x27 => { daa_das(false); },
        0x2F => { daa_das(true); },
        0x37 => { aaa_aas(false); },
        0x3F => { aaa_aas(true); },

        0x40..0x48 => { set_regw(op, osz, inc(regw(op, osz), osz)); },
        0x48..0x50 => { set_regw(op, osz, dec(regw(op, osz), osz)); },
        0x50..0x58 => { pushv(regw(op, osz)); },
        0x58..0x60 => { let v = popv(); set_regw(op, osz, v); },

        0x60 => {
            let sp0 = regw(SP, osz);
            for i: u8 in 0..8 { if i == 4 { pushv(sp0); } else { pushv(regw(i, osz)); } }
        },
        0x61 => {
            for k: u8 in 0..8 {
                let i = 7 - k;
                let v = popv();
                if i != 4 { set_regw(i, osz, v); }
            }
        },
        0x62, 0x63 => { fault(6); },                         // BOUND is not implemented; ARPL is not in real mode
        0x68 => { pushv(fetchv()); },
        0x6A => { pushv(fetch_s8()); },
        0x69, 0x6B => {
            decode_modrm();
            let a = rm_read(osz);
            let b = if op == 0x69 { fetchv() } else { fetch_s8() };
            let p = imul(a, b, osz);
            set_regw(m_reg, osz, p as! u32);
        },
        0x6C..0x70 => { string_op(op); },

        0x70..0x80 => { jump_rel8(cond(op & 0x0F)); },

        0x80..0x84 => {
            let w = width(op);
            decode_modrm();
            let a = rm_read(w);
            var b: u32 = 0;
            if op == 0x81 { b = fetchv(); } else if op == 0x83 { b = fetch_s8() & mask(w); } else { b = fetch8(); }
            let r = alu(m_reg, a, b, w);
            if m_reg != 7 { rm_write(w, r); }
        },
        0x84, 0x85 => {
            let w = width(op);
            decode_modrm();
            alu(4, rm_read(w), regw(m_reg, w), w);
        },
        0x86, 0x87 => {
            let w = width(op);
            decode_modrm();
            let a = rm_read(w);
            rm_write(w, regw(m_reg, w));
            set_regw(m_reg, w, a);
        },
        0x88, 0x89 => { let w = width(op); decode_modrm(); rm_write(w, regw(m_reg, w)); },
        0x8A, 0x8B => { let w = width(op); decode_modrm(); set_regw(m_reg, w, rm_read(w)); },
        0x8C => {
            decode_modrm();
            if m_reg > 5 { fault(6); return; }
            // To a register the selector is zero-extended to the operand size; to memory it is 16 bits.
            rm_write(if m_mod == 3 { osz } else { 16 }, cpu.segs[m_reg]);
        },
        0x8D => { decode_modrm(); set_regw(m_reg, osz, ea_off); },
        0x8E => {
            decode_modrm();
            if m_reg > 5 || m_reg == CS { fault(6); return; }
            set_seg(m_reg, rm_read(16) as! u16);
            if m_reg == SS { shadow = true; }
        },
        0x8F => { let v = popv(); decode_modrm(); rm_write(osz, v); },

        0x90..0x98 => { let t = regw(AX, osz); set_regw(AX, osz, regw(op, osz)); set_regw(op, osz, t); },
        0x98 => {
            if osz == 16 { set_r16(AX, (r8(0) as! i8) as! u16); }
            else { set_r32(AX, (r16(AX) as! i16) as! u32); }
        },
        0x99 => {
            if osz == 16 { set_r16(DX, if r16(AX) & 0x8000 != 0 { 0xFFFF } else { 0 }); }
            else { set_r32(DX, if r32(AX) & 0x80000000 != 0 { 0xFFFFFFFF } else { 0 }); }
        },
        0x9A => { let off = fetchv(); let seg = fetch16() as! u16; far_call(seg, off); },
        0x9B => {},
        0x9C => { pushv(cpu.flags & 0x7FD5 | 2); },
        0x9D => { write_flags(popv()); },
        0x9E => { cpu.flags = cpu.flags & 0xFFFFFF00 | (r8(4) & 0xD5) | 2; },
        0x9F => { set_r8(4, cpu.flags as! u8); },

        0xA0 => { let off = if asz32 { fetch32() } else { fetch16() }; set_r8(0, seg_read(seg_of(DS), off, 8) as! u8); },
        0xA1 => { let off = if asz32 { fetch32() } else { fetch16() }; set_regw(AX, osz, seg_read(seg_of(DS), off, osz)); },
        0xA2 => { let off = if asz32 { fetch32() } else { fetch16() }; seg_write(seg_of(DS), off, 8, r8(0)); },
        0xA3 => { let off = if asz32 { fetch32() } else { fetch16() }; seg_write(seg_of(DS), off, osz, regw(AX, osz)); },
        0xA4..0xA8 => { string_op(op); },
        0xA8, 0xA9 => { let w = width(op); alu(4, regw(0, w), fetchw(w), w); },
        0xAA..0xB0 => { string_op(op); },

        0xB0..0xB8 => { let v = fetch8(); set_r8(op, v); },
        0xB8..0xC0 => { let v = fetchv(); set_regw(op, osz, v); },

        0xC0, 0xC1 => {
            let w = width(op);
            decode_modrm();
            let n = fetch8();
            rm_write(w, shift(m_reg, rm_read(w), n, w));
        },
        0xC2 => { let n = fetch16() as! u16; set_ip(popv()); set_r16(SP, r16(SP) + n); },
        0xC3 => { set_ip(popv()); },
        0xC4 => { load_far(ES); },
        0xC5 => { load_far(DS); },
        0xC6, 0xC7 => { let w = width(op); decode_modrm(); rm_write(w, fetchw(w)); },
        0xC8 => {
            let size = fetch16() as! u16;
            let level = fetch8() & 0x1F;
            pushv(regw(BP, osz));
            let frame = r16(SP);
            if level > 0 {
                for i in 1..level {
                    set_r16(BP, r16(BP) - (osz as u16) / 8);
                    pushv(seg_read(SS, r16(BP), osz));
                }
                pushv(frame);
            }
            // The frame pointer is as wide as the stack pointer: 16 bits in real mode, even when
            // a 32-bit EBP was pushed.
            set_r16(BP, frame);
            set_r16(SP, r16(SP) - size);
        },
        0xC9 => { set_r16(SP, r16(BP)); let v = popv(); set_regw(BP, osz, v); },
        0xCA => {
            let n = fetch16() as! u16;
            let ip = popv();
            set_seg(CS, popv() as! u16);
            set_ip(ip);
            set_r16(SP, r16(SP) + n);
        },
        0xCB => { let ip = popv(); set_seg(CS, popv() as! u16); set_ip(ip); },
        0xCC => { interrupt(3); },
        0xCD => { let n = fetch8(); interrupt(n); },
        0xCE => { if flag(OF) { interrupt(4); } },
        0xCF => {
            if osz == 16 { iret(); }
            else { let ip = pop32(); set_seg(CS, pop32() as! u16); cpu.ip = ip; write_flags(pop32()); }
        },

        0xD0..0xD4 => {
            let w = width(op);
            decode_modrm();
            let n: u8 = if op < 0xD2 { 1 } else { r8(1) };
            rm_write(w, shift(m_reg, rm_read(w), n, w));
        },
        0xD4 => {
            let base = fetch8();
            if base == 0 { fault(0); return; }
            let al = r8(0);
            set_r8(4, al / base);
            set_r8(0, al % base);
            set_szp(r8(0), 8);
        },
        0xD5 => {
            let base = fetch8();
            let lo = r8(0);
            let hi = r8(4);
            let al = lo + hi * base;
            set_r16(AX, al);
            set_szp(al, 8);
        },
        0xD6 => { set_r8(0, if flag(CF) { 0xFF } else { 0 }); },
        0xD7 => { let index: u32 = r8(0); set_r8(0, seg_read(seg_of(DS), (addr_reg(BX) + index) & (if asz32 { 0xFFFFFFFF } else { 0xFFFF }), 8) as! u8); },
        0xD8..0xE0 => { decode_modrm(); },      // no FPU: skip the operand

        0xE0 => { addr_reg_add(CX, 0xFFFFFFFF); jump_rel8(addr_reg(CX) != 0 && !flag(ZF)); },
        0xE1 => { addr_reg_add(CX, 0xFFFFFFFF); jump_rel8(addr_reg(CX) != 0 && flag(ZF)); },
        0xE2 => { addr_reg_add(CX, 0xFFFFFFFF); jump_rel8(addr_reg(CX) != 0); },
        0xE3 => { jump_rel8(addr_reg(CX) == 0); },
        0xE4 => { let port = fetch8(); set_r8(0, port_in8(port)); },
        0xE5 => { let port = fetch8(); set_regw(AX, osz, port_read(port, osz)); },
        0xE6 => { let port = fetch8(); port_out8(port, r8(0)); },
        0xE7 => { let port = fetch8(); port_write(port, osz, regw(AX, osz)); },
        0xE8 => { let d = fetchv(); pushv(cpu.ip); set_ip(cpu.ip + d); },
        0xE9 => { let d = fetchv(); set_ip(cpu.ip + d); },
        0xEA => { let off = fetchv(); let seg = fetch16() as! u16; set_seg(CS, seg); set_ip(off); },
        0xEB => { jump_rel8(true); },
        0xEC => { set_r8(0, port_in8(r16(DX))); },
        0xED => { set_regw(AX, osz, port_read(r16(DX), osz)); },
        0xEE => { port_out8(r16(DX), r8(0)); },
        0xEF => { port_write(r16(DX), osz, regw(AX, osz)); },

        0xF4 => { cpu.halted = true; },
        0xF5 => { set_flag(CF, !flag(CF)); },
        0xF6, 0xF7 => { group3(op); },
        0xF8 => { set_flag(CF, false); },
        0xF9 => { set_flag(CF, true); },
        0xFA => { set_flag(IF, false); },
        0xFB => { if !flag(IF) { shadow = true; } set_flag(IF, true); },
        0xFC => { set_flag(DF, false); },
        0xFD => { set_flag(DF, true); },
        0xFE, 0xFF => { group45(op); },

        _ => { cpu.ip = insn_ip; stop("unimplemented opcode", op); },
    }
}
