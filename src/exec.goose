// Instruction execution: a 386, in real mode, protected mode and virtual-8086 mode. The default
// operand and address size come from the code segment (16 bits in real mode); the 66h and 67h
// prefixes switch to the other. To software that asks, the machine is a 386 with no FPU and no
// CPUID: FLAGS bits 12-14 can be written and PUSH SP pushes the value from before the decrement.
//
// exec_one runs one instruction and returns false when a fault cut it short (see raise in
// state.goose). step wraps it: it restores the state the instruction started from and delivers
// the fault.

import std;
import os;
import state;
import alu;
import prot;
import bios;
import dev;

// ---- Decode state that lives for one instruction ----

var seg_ovr = -1;            // segment override: -1 none, else ES CS SS DS FS GS
var rep: u8 = 0;             // 0 none, 1 REPNE (F2), 2 REP/REPE (F3)
var osz: u8 = 16;            // operand size of this instruction: 16 or 32
var asz32 = false;           // this instruction addresses memory with 32-bit offsets
var lock = false;            // the instruction has a LOCK prefix
var shadow = false;          // the instruction just executed holds interrupts off for one more
var m_mod: u8 = 0;
var m_reg: u8 = 0;
var m_rm: u8 = 0;
var ea_seg = 3;              // segment register of the effective address (starts as DS)
var ea_off: u32 = 0;

// ---- Fetch ----

// The code segment decides the default operand and address size, and the width of EIP.
fn code32() -> bool { return cpu.attr[CS] & A_BIG != 0; }

fn fetch8() -> u8 {
    if cpu.ip > cpu.limit[CS] { raise_gp(0); }
    let a = cpu.base[CS] + cpu.ip;
    // Translate once per page of code, not once per byte.
    if a >> 12 != code_page {
        code_phys = translate(a, false, cpu.cpl == 3) & 0xFFFFF000;
        code_page = a >> 12;
    }
    let b = mem8(code_phys | a & 0xFFF);
    cpu.ip += 1;
    if !code32() { cpu.ip &= 0xFFFF; }
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

fn pushv(v: u32) { push_w(v, osz); }
fn popv() -> u32 { return pop_w(osz); }

// A jump target is cut to 16 bits when the operand size is 16.
fn set_ip(v: u32) { cpu.ip = if osz == 16 { v & 0xFFFF } else { v }; }

fn jump_rel8(taken: bool) {
    let d = fetch_s8();
    if taken { set_ip(cpu.ip + d); }
}

// A fault with no error code: divide error (0), bound range (5), invalid opcode (6).
fn fault(n: u8) { raise(n, false, 0); }

// Instructions only the most privileged level may execute.
fn need_ring0() { if protected() && cpu.cpl != 0 { raise_gp(0); } }

// Instructions that need the I/O privilege level: CLI, STI, and in virtual-8086 mode also
// PUSHF, POPF, INT n and IRET.
fn io_sensitive() {
    if !protected() { return; }
    if v86() { if iopl() < 3 { raise_gp(0); } }
    else if cpu.cpl > iopl() { raise_gp(0); }
}

// ---- Registers used as addresses and counters: 16 or 32 bits by the address size ----

fn addr_reg(i: u8) -> u32 { if asz32 { return r32(i); } return r16(i); }

fn addr_reg_add(i: u8, d: u32) {
    if asz32 { set_r32(i, r32(i) + d); } else { set_r16(i, r16(i) + (d as! u16)); }
}

// ---- String instructions (A4..A7, AA..AF, 6C..6F) ----

fn string_op(op: u8) {
    let w = width(op);
    let n: u32 = ((w as u32) >> 3);
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
                io_check(r16(DX), w);
                seg_write(ES, addr_reg(DI), w, port_read(r16(DX), w));
                addr_reg_add(DI, d);
            },
            _ => {
                io_check(r16(DX), w);
                port_write(r16(DX), w, seg_read(src, addr_reg(SI), w));
                addr_reg_add(SI, d);
            },
        }
        if rep == 0 { break; }
        addr_reg_add(CX, 0xFFFFFFFF);
        // A repeated instruction that faults part-way resumes from where it got to.
        saved.regs = cpu.regs;
        saved.flags = cpu.flags;
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
            far_call(seg_read(ea_seg, ea_off + ((osz as u32) >> 3), 16) as! u16, off, osz);
        },
        4 => { set_ip(rm_read(osz)); },
        5 => {
            if m_mod == 3 { fault(6); return; }
            let off = seg_read(ea_seg, ea_off, osz);
            far_jump(seg_read(ea_seg, ea_off + ((osz as u32) >> 3), 16) as! u16, off);
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
    let sel = seg_read(ea_seg, ea_off + ((osz as u32) >> 3), 16) as! u16;
    load_seg(s, sel);
    set_regw(m_reg, osz, off);
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
    match op >> 4 {
        0x0 => {
            match op {
                0x00 => {
                    decode_modrm();
                    if !protected() || v86() { fault(6); }
                    match m_reg {
                        0 => { rm_write(if m_mod == 3 { osz } else { 16 }, ldtr_sel); },         // SLDT
                        1 => { rm_write(if m_mod == 3 { osz } else { 16 }, tr_sel); },           // STR
                        2 => {                                                                    // LLDT
                            need_ring0();
                            let sel = rm_read(16) as! u16;
                            if sel & 0xFFFC == 0 { ldtr_sel = sel; ldtr_base = 0; ldtr_limit = 0; return; }
                            if sel & 4 != 0 { raise_gp(sel & 0xFFFC); }
                            let at, lo, hi = read_desc(sel, 0);
                            if hi >> 8 & 0x1F != 2 { raise_gp(sel & 0xFFFC); }
                            if hi & 0x8000 == 0 { raise_np(sel & 0xFFFC); }
                            ldtr_sel = sel;
                            ldtr_base = d_base(lo, hi);
                            ldtr_limit = d_limit(lo, hi);
                        },
                        3 => {                                                                    // LTR
                            need_ring0();
                            let sel = rm_read(16) as! u16;
                            if sel & 0xFFFC == 0 { raise_gp(0); }
                            if sel & 4 != 0 { raise_gp(sel & 0xFFFC); }
                            let at, lo, hi = read_desc(sel, 0);
                            let kind = hi >> 8 & 0x1F;
                            if kind != 1 && kind != 9 { raise_gp(sel & 0xFFFC); }
                            if hi & 0x8000 == 0 { raise_np(sel & 0xFFFC); }
                            tr_sel = sel;
                            tr_base = d_base(lo, hi);
                            tr_limit = d_limit(lo, hi);
                            tr_32 = kind == 9;
                            sys_write(at + 5, 8, hi >> 8 & 0xFF | 2);                             // now busy
                        },
                        4, 5 => {                                                                 // VERR, VERW
                            let sel = rm_read(16) as! u16;
                            let at, ok = desc_at(sel);
                            var good = ok && sel & 0xFFFC != 0;
                            if good {
                                let hi = sys_read(at + 4, 32);
                                let acc = hi >> 8;
                                let rpl: u8 = (sel & 3) as! u8;
                                if acc & A_S == 0 { good = false; }
                                else if m_reg == 4 && acc & A_CODE != 0 && acc & A_RW == 0 { good = false; }
                                else if m_reg == 5 && (acc & A_CODE != 0 || acc & A_RW == 0) { good = false; }
                                else if (acc & A_CODE == 0 || acc & A_DOWN_CONF == 0) && (d_dpl(hi) < cpu.cpl || d_dpl(hi) < rpl) { good = false; }
                            }
                            set_flag(ZF, good);
                        },
                        _ => { fault(6); },
                    }
                },
                0x01 => {
                    decode_modrm();
                    match m_reg {
                        0, 1 => {                                    // SGDT, SIDT
                            if m_mod == 3 { fault(6); }
                            seg_write(ea_seg, ea_off, 16, if m_reg == 0 { gdtr_limit } else { idtr_limit });
                            seg_write(ea_seg, ea_off + 2, 32, if m_reg == 0 { gdtr_base } else { idtr_base });
                        },
                        2, 3 => {                                    // LGDT, LIDT
                            if m_mod == 3 { fault(6); }
                            need_ring0();
                            let limit = seg_read(ea_seg, ea_off, 16);
                            var base = seg_read(ea_seg, ea_off + 2, 32);
                            if osz == 16 { base &= 0x00FFFFFF; }
                            if m_reg == 2 { gdtr_limit = limit; gdtr_base = base; }
                            else { idtr_limit = limit; idtr_base = base; }
                        },
                        4 => { rm_write(if m_mod == 3 { osz } else { 16 }, if m_mod == 3 && osz == 32 { cr[0] } else { cr[0] & 0xFFFF }); },
                        6 => {                                       // LMSW: can set PE, cannot clear it
                            need_ring0();
                            cr[0] = cr[0] & 0xFFFFFFF1 | rm_read(16) & 0x0F;
                            flush_tlb();
                        },
                        7 => {                                       // INVLPG
                            if !i686 || m_mod == 3 { fault(6); }
                            need_ring0();
                            flush_tlb();
                        },
                        _ => { fault(6); },
                    }
                },
                0x02, 0x03 => {                                      // LAR, LSL
                    decode_modrm();
                    if !protected() || v86() { fault(6); }
                    let sel = rm_read(16) as! u16;
                    let at, ok = desc_at(sel);
                    var good = ok && sel & 0xFFFC != 0;
                    var lo: u32 = 0;
                    var hi: u32 = 0;
                    if good {
                        lo = sys_read(at, 32);
                        hi = sys_read(at + 4, 32);
                        let acc = hi >> 8;
                        let rpl: u8 = (sel & 3) as! u8;
                        let kind = acc & 0x0F;
                        if acc & A_S == 0 {
                            // System segments: LAR takes task segments, LDTs and gates; LSL only those with a limit.
                            let with_limit = kind == 1 || kind == 2 || kind == 3 || kind == 9 || kind == 11;
                            let gate = kind == 4 || kind == 5 || kind == 12;
                            if !(with_limit || (op == 0x02 && gate)) { good = false; }
                            else if d_dpl(hi) < cpu.cpl || d_dpl(hi) < rpl { good = false; }
                        }
                        else if (acc & A_CODE == 0 || acc & A_DOWN_CONF == 0) && (d_dpl(hi) < cpu.cpl || d_dpl(hi) < rpl) { good = false; }
                    }
                    set_flag(ZF, good);
                    if good {
                        if op == 0x02 { set_regw(m_reg, osz, if osz == 32 { hi & 0x00F0FF00 } else { hi & 0xFF00 }); }
                        else { set_regw(m_reg, osz, d_limit(lo, hi)); }
                    }
                },
                0x06 => { need_ring0(); cr[0] &= 0xFFFFFFF7; },      // CLTS
                0x08, 0x09 => { if !i686 { fault(6); } need_ring0(); },                  // INVD, WBINVD: no cache
                0x0B => { fault(6); },                               // UD2
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode 0F", op); },
            }
        },
        0x1 => {
            match op {
                // The long NOP (0F 1F) and the prefetch hints (0F 18): an operand, and no effect.
                0x18, 0x1F => { if !i686 { fault(6); } decode_modrm(); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode 0F", op); },
            }
        },
        0x2 => {
            match op {
                0x20 => { decode_modrm(); need_ring0(); set_r32(m_rm, cr[m_reg]); },
                0x22 => {
                    decode_modrm();
                    need_ring0();
                    cr[m_reg] = r32(m_rm);
                    flush_tlb();
                    if !protected() { set_cpl(0); }
                },
                0x21, 0x23 => { decode_modrm(); need_ring0(); if op == 0x21 { set_r32(m_rm, 0); } },     // debug registers
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode 0F", op); },
            }
        },
        0x3 => {
            match op {
                // Instructions from the 486 on (CPUID, CMPXCHG, XADD, BSWAP, RDTSC ...) are invalid here.
                0x30, 0x32 => {                                      // WRMSR, RDMSR: no model-specific registers
                    if !i686 { fault(6); }
                    raise_gp(0);
                },
                0x31 => {                                            // RDTSC: the instruction count
                    if !i686 { fault(6); }
                    set_r32(AX, vtime as! u32);
                    set_r32(DX, (vtime >> 32) as! u32);
                },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode 0F", op); },
            }
        },
        0x4 => {
            // CMOVcc: a move that happens only if the condition holds. The source is read either way.
            if !i686 { fault(6); }
            decode_modrm();
            let v = rm_read(osz);
            if cond(op & 0x0F) { set_regw(m_reg, osz, v); }
        },
        0x8 => {
            match op {
                0x80..0x90 => {
                    let d = if osz == 16 { ((fetch16() as! u16) as! i16) as! u32 } else { fetch32() };
                    if cond(op & 0x0F) { set_ip(cpu.ip + d); }
                },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode 0F", op); },
            }
        },
        0x9 => {
            match op {
                0x90..0xA0 => { decode_modrm(); rm_write(8, if cond(op & 0x0F) { 1 } else { 0 }); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode 0F", op); },
            }
        },
        0xA => {
            match op {
                0xA0 => { pushv(cpu.segs[FS]); },
                0xA1 => { load_seg(FS, popv() as! u16); },
                0xA8 => { pushv(cpu.segs[GS]); },
                0xA9 => { load_seg(GS, popv() as! u16); },
                0xA3 => { decode_modrm(); bit_op(0, regw(m_reg, osz), true); },
                0xAB => { decode_modrm(); bit_op(1, regw(m_reg, osz), true); },
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
                0xA2 => {                                            // CPUID
                    if !i686 { fault(6); }
                    let leaf = r32(AX);
                    set_r32(AX, 0);
                    set_r32(BX, 0);
                    set_r32(CX, 0);
                    set_r32(DX, 0);
                    if leaf == 0 {
                        set_r32(AX, 1);                              // the highest leaf
                        set_r32(BX, 0x756E6547);                     // "GenuineIntel"
                        set_r32(DX, 0x49656E69);
                        set_r32(CX, 0x6C65746E);
                    } else if leaf == 1 {
                        // Family 6, the P6. Only what is implemented is claimed: the timestamp
                        // counter, CMPXCHG8B and CMOV. No FPU yet.
                        set_r32(AX, 0x0633);
                        set_r32(DX, 1 << 4 | 1 << 8 | 1 << 15);
                    }
                },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode 0F", op); },
            }
        },
        0xB => {
            match op {
                0xB3 => { decode_modrm(); bit_op(2, regw(m_reg, osz), true); },
                0xBB => { decode_modrm(); bit_op(3, regw(m_reg, osz), true); },
                0xBA => {
                    decode_modrm();
                    let bit: u32 = fetch8();
                    if m_reg < 4 { fault(6); return; }
                    bit_op(m_reg - 4, bit, false);
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
                0xB0, 0xB1 => {                                      // CMPXCHG
                    if !i686 { fault(6); }
                    let w = width(op);
                    decode_modrm();
                    let dst = rm_read(w);
                    let acc = regw(AX, w);
                    alu(7, acc, dst, w);
                    if acc == dst { rm_write(w, regw(m_reg, w)); } else { set_regw(AX, w, dst); }
                },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode 0F", op); },
            }
        },
        0xC => {
            match op {
                0xC0, 0xC1 => {                                      // XADD
                    if !i686 { fault(6); }
                    let w = width(op);
                    decode_modrm();
                    let dst = rm_read(w);
                    let src = regw(m_reg, w);
                    let sum = alu(0, dst, src, w);
                    set_regw(m_reg, w, dst);
                    rm_write(w, sum);
                },
                0xC7 => {                                            // CMPXCHG8B
                    if !i686 { fault(6); }
                    decode_modrm();
                    if m_mod == 3 || m_reg != 1 { fault(6); }
                    let lo = seg_read(ea_seg, ea_off, 32);
                    let hi = seg_read(ea_seg, ea_off + 4, 32);
                    if lo == r32(AX) && hi == r32(DX) {
                        seg_write(ea_seg, ea_off, 32, r32(BX));
                        seg_write(ea_seg, ea_off + 4, 32, r32(CX));
                        set_flag(ZF, true);
                    } else {
                        set_r32(AX, lo);
                        set_r32(DX, hi);
                        set_flag(ZF, false);
                    }
                },
                0xC8..0xD0 => {                                      // BSWAP
                    if !i686 { fault(6); }
                    let v = r32(op);
                    set_r32(op, v >> 24 | v >> 8 & 0xFF00 | (v & 0xFF00) << 8 | v << 24);
                },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode 0F", op); },
            }
        },
        _ => { cpu.ip = saved.ip; stop("unimplemented opcode 0F", op); },
    }
}

// May the instruction with opcode op carry a LOCK prefix? Only a short list may, and only with a
// memory destination: the ALU operations that write, NOT, NEG, INC, DEC, XCHG, and the bit
// instructions that write. Anything else with LOCK is an invalid opcode. This looks at the bytes
// after the opcode without consuming them.
fn lockable(op: u8) -> bool {
    var at = cpu.base[CS] + cpu.ip;
    var two = false;
    var code = op;
    if op == 0x0F {
        code = lin_read(at, 8, cpu.cpl == 3) as! u8;
        at += 1;
        two = true;
    }
    let m = lin_read(at, 8, cpu.cpl == 3) as! u8;
    if m >> 6 == 3 { return false; }
    let r = m >> 3 & 7;
    if two {
        if code == 0xAB || code == 0xB3 || code == 0xBB { return true; }
        if i686 && (code == 0xB0 || code == 0xB1 || code == 0xC0 || code == 0xC1) { return true; }      // CMPXCHG, XADD
        if i686 && code == 0xC7 { return r == 1; }                                                      // CMPXCHG8B
        return code == 0xBA && r >= 5;
    }
    if code < 0x38 && code & 7 < 2 { return true; }
    match code {
        0x80, 0x81, 0x83 => { return r != 7; },
        0x86, 0x87 => { return true; },
        0xF6, 0xF7 => { return r == 2 || r == 3; },
        0xFE, 0xFF => { return r < 2; },
        _ => { return false; },
    }
}

// ---- One instruction ----

// A fault waiting to be delivered: exec_one delivers it instead of executing an instruction.
var pending = false;
var pending_vec: u8 = 0;
var pending_has_err = false;
var pending_err: u32 = 0;

// One instruction, or the delivery of a pending fault. False when a fault cut it short.
fn exec_one() -> bool {
    if pending {
        pending = false;
        deliver(pending_vec, false, pending_has_err, pending_err);
        return true;
    }
    // A hardware interrupt is taken between instructions, then its handler's first one runs.
    if irq_line && flag(IF) && !shadow { deliver(pic_ack(), false, false, 0); }

    // At a BIOS entry: perform the service instead of fetching an instruction, then IRET.
    if cpu.ip < 256 && bios_on && cpu.segs[CS] == BIOS_SEG {
        bios_call(cpu.ip as! u8);
        do_iret(16);
        if bios_idle {
            // The service is waiting for an interrupt. A real BIOS waits with interrupts on,
            // whatever the caller's IF was.
            bios_idle = false;
            set_flag(IF, true);
            cpu.halted = true;
        }
        return true;
    }

    shadow = false;
    lock = false;
    seg_ovr = -1;
    rep = 0;
    osz = if code32() { 32 } else { 16 };
    asz32 = code32();
    var op = fetch8();
    // Most instructions have no prefix: three tests rule that out before the prefix loop.
    // (26 2E 36 3E are segment overrides, 64-67 FS GS and the size prefixes, F0 F2 F3 LOCK and REP.)
    if op & 0xE7 == 0x26 || op & 0xFC == 0x64 || op & 0xFC == 0xF0 {
        loop {
            match op {
                0x26 => { seg_ovr = ES; },
                0x2E => { seg_ovr = CS; },
                0x36 => { seg_ovr = SS; },
                0x3E => { seg_ovr = DS; },
                0x64 => { seg_ovr = FS; },
                0x65 => { seg_ovr = GS; },
                0x66 => { osz = if code32() { 16 } else { 32 }; },
                0x67 => { asz32 = !code32(); },
                0xF2 => { rep = 1; },
                0xF3 => { rep = 2; },
                0xF0 => { lock = true; },
                _ => { break; },
            }
            op = fetch8();
        }
    }

    if lock && !lockable(op) { fault(6); }

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
        return true;
    }

    // Dispatch in two steps: first on the opcode's high four bits, then within that row of the
    // opcode map. Goose compiles an integer match to a chain of comparisons, and the C compiler
    // turns such a chain into a jump table only when the arms are plain values with no ranges.
    // One match over all the opcodes cost a hundred-odd comparisons for those near its end.
    match op >> 4 {
        0x0 => {
            match op {
                0x06 => { pushv(cpu.segs[ES]); },
                0x07 => { load_seg(ES, popv() as! u16); },
                0x0E => { pushv(cpu.segs[CS]); },
                0x0F => { two_byte(); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0x1 => {
            match op {
                0x16 => { pushv(cpu.segs[SS]); },
                0x17 => { load_seg(SS, popv() as! u16); shadow = true; },
                0x1E => { pushv(cpu.segs[DS]); },
                0x1F => { load_seg(DS, popv() as! u16); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0x2 => {
            match op {
                0x27 => { daa_das(false); },
                0x2F => { daa_das(true); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0x3 => {
            match op {
                0x37 => { aaa_aas(false); },
                0x3F => { aaa_aas(true); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0x4 => {
            match op {
                0x40..0x48 => { set_regw(op, osz, inc(regw(op, osz), osz)); },
                0x48..0x50 => { set_regw(op, osz, dec(regw(op, osz), osz)); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0x5 => {
            match op {
                0x50..0x58 => { pushv(regw(op, osz)); },
                0x58..0x60 => { let v = popv(); set_regw(op, osz, v); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0x6 => {
            match op {
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
                0x62 => {                                            // BOUND
                    decode_modrm();
                    if m_mod == 3 { fault(6); }
                    let index = sx(regw(m_reg, osz), osz);
                    let lower = sx(seg_read(ea_seg, ea_off, osz), osz);
                    let upper = sx(seg_read(ea_seg, ea_off + ((osz as u32) >> 3), osz), osz);
                    if index < lower || index > upper { fault(5); }
                },
                0x63 => {                                            // ARPL
                    if !protected() || v86() { fault(6); }
                    decode_modrm();
                    let dst = rm_read(16);
                    let src: u32 = r16(m_reg);
                    if dst & 3 < src & 3 { rm_write(16, dst & 0xFFFC | src & 3); set_flag(ZF, true); }
                    else { set_flag(ZF, false); }
                },
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
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0x7 => {
            match op {
                0x70..0x80 => { jump_rel8(cond(op & 0x0F)); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0x8 => {
            match op {
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
                    if m_reg > 5 { fault(6); }
                    // To a register the selector is zero-extended to the operand size; to memory it is 16 bits.
                    rm_write(if m_mod == 3 { osz } else { 16 }, cpu.segs[m_reg]);
                },
                0x8D => { decode_modrm(); set_regw(m_reg, osz, ea_off); },
                0x8E => {
                    decode_modrm();
                    if m_reg > 5 || m_reg == CS { fault(6); }
                    load_seg(m_reg, rm_read(16) as! u16);
                    if m_reg == SS { shadow = true; }
                },
                0x8F => { let v = popv(); decode_modrm(); rm_write(osz, v); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0x9 => {
            match op {
                0x90..0x98 => { let t = regw(AX, osz); set_regw(AX, osz, regw(op, osz)); set_regw(op, osz, t); },
                0x98 => {
                    if osz == 16 { set_r16(AX, (r8(0) as! i8) as! u16); }
                    else { set_r32(AX, (r16(AX) as! i16) as! u32); }
                },
                0x99 => {
                    if osz == 16 { set_r16(DX, if r16(AX) & 0x8000 != 0 { 0xFFFF } else { 0 }); }
                    else { set_r32(DX, if r32(AX) & 0x80000000 != 0 { 0xFFFFFFFF } else { 0 }); }
                },
                0x9A => { let off = fetchv(); let seg = fetch16() as! u16; far_call(seg, off, osz); },
                0x9B => {},
                0x9C => { if v86() { io_sensitive(); } pushv(cpu.flags & 0x00FCFFFF); },
                0x9D => {
                    if v86() { io_sensitive(); }
                    // IF changes only if the level may do I/O; IOPL only at level 0 (always, in real mode).
                    var m: u32 = 0x4DD5;
                    if osz == 32 { m |= AC | ID; }
                    if !protected() || cpu.cpl == 0 { m |= IOPL; }
                    if !protected() || (if v86() { iopl() == 3 } else { cpu.cpl <= iopl() }) { m |= IF; }
                    write_flags(popv(), m);
                },
                0x9E => { cpu.flags = cpu.flags & 0xFFFFFF00 | (r8(4) & 0xD5) | 2; },
                0x9F => { set_r8(4, cpu.flags as! u8); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0xA => {
            match op {
                0xA0 => { let off = if asz32 { fetch32() } else { fetch16() }; set_r8(0, seg_read(seg_of(DS), off, 8) as! u8); },
                0xA1 => { let off = if asz32 { fetch32() } else { fetch16() }; set_regw(AX, osz, seg_read(seg_of(DS), off, osz)); },
                0xA2 => { let off = if asz32 { fetch32() } else { fetch16() }; seg_write(seg_of(DS), off, 8, r8(0)); },
                0xA3 => { let off = if asz32 { fetch32() } else { fetch16() }; seg_write(seg_of(DS), off, osz, regw(AX, osz)); },
                0xA4..0xA8 => { string_op(op); },
                0xA8, 0xA9 => { let w = width(op); alu(4, regw(0, w), fetchw(w), w); },
                0xAA..0xB0 => { string_op(op); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0xB => {
            match op {
                0xB0..0xB8 => { let v = fetch8(); set_r8(op, v); },
                0xB8..0xC0 => { let v = fetchv(); set_regw(op, osz, v); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0xC => {
            match op {
                0xC0, 0xC1 => {
                    let w = width(op);
                    decode_modrm();
                    let n = fetch8();
                    rm_write(w, shift(m_reg, rm_read(w), n, w));
                },
                0xC2 => { let n = fetch16(); set_ip(popv()); sp_set(sp_get() + n); },
                0xC3 => { set_ip(popv()); },
                0xC4 => { load_far(ES); },
                0xC5 => { load_far(DS); },
                0xC6, 0xC7 => { let w = width(op); decode_modrm(); rm_write(w, fetchw(w)); },
                0xC8 => {
                    // Two widths are in play: what is pushed is as wide as the operand size, while BP and
                    // SP move at the width of the stack segment. The frame pointer is the raw ESP, so
                    // with a 16-bit stack and a 32-bit operand its upper half shows whatever ESP had.
                    // The last step probes the new top of the stack for writing without writing it.
                    // (rustx86 worked these out against test386, stage 1A.)
                    let size = fetch16();
                    let level = fetch8() & 0x1F;
                    let big = stack32();
                    pushv(regw(BP, osz));
                    let frame = r32(SP);
                    if level > 0 {
                        for i in 1..level {
                            if big { set_r32(BP, r32(BP) - ((osz as u32) >> 3)); } else { set_r16(BP, r16(BP) - (osz as u16) / 8); }
                            pushv(seg_read(SS, if big { r32(BP) } else { r16(BP) }, osz));
                        }
                        pushv(frame);
                    }
                    if big { set_r32(BP, frame); } else { set_r16(BP, frame as! u16); }
                    var top = sp_get() - size;
                    if !big { top &= 0xFFFF; }
                    let probe = translate(cpu.base[SS] + top, true, cpu.cpl == 3);
                    sp_set(top);
                },
                0xC9 => { sp_set(if stack32() { r32(BP) } else { r16(BP) }); let v = popv(); set_regw(BP, osz, v); },
                0xCA => { let n = fetch16(); far_ret(osz, n); if osz == 16 { cpu.ip &= 0xFFFF; } },
                0xCB => { far_ret(osz, 0); if osz == 16 { cpu.ip &= 0xFFFF; } },
                0xCC => { deliver(3, true, false, 0); },
                0xCD => { let n = fetch8(); if v86() { io_sensitive(); } deliver(n, true, false, 0); },
                0xCE => { if flag(OF) { deliver(4, true, false, 0); } },
                0xCF => { do_iret(osz); if osz == 16 { cpu.ip &= 0xFFFF; } },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0xD => {
            match op {
                0xD0..0xD4 => {
                    let w = width(op);
                    decode_modrm();
                    let n: u8 = if op < 0xD2 { 1 } else { r8(1) };
                    rm_write(w, shift(m_reg, rm_read(w), n, w));
                },
                0xD4 => {
                    let base = fetch8();
                    if base == 0 { fault(0); }
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
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0xE => {
            match op {
                0xE0 => { addr_reg_add(CX, 0xFFFFFFFF); jump_rel8(addr_reg(CX) != 0 && !flag(ZF)); },
                0xE1 => { addr_reg_add(CX, 0xFFFFFFFF); jump_rel8(addr_reg(CX) != 0 && flag(ZF)); },
                0xE2 => { addr_reg_add(CX, 0xFFFFFFFF); jump_rel8(addr_reg(CX) != 0); },
                0xE3 => { jump_rel8(addr_reg(CX) == 0); },
                0xE4 => { let port = fetch8(); io_check(port, 8); set_r8(0, port_in8(port)); },
                0xE5 => { let port = fetch8(); io_check(port, osz); set_regw(AX, osz, port_read(port, osz)); },
                0xE6 => { let port = fetch8(); io_check(port, 8); port_out8(port, r8(0)); },
                0xE7 => { let port = fetch8(); io_check(port, osz); port_write(port, osz, regw(AX, osz)); },
                0xE8 => { let d = fetchv(); pushv(cpu.ip); set_ip(cpu.ip + d); },
                0xE9 => { let d = fetchv(); set_ip(cpu.ip + d); },
                0xEA => { let off = fetchv(); let seg = fetch16() as! u16; far_jump(seg, off); },
                0xEB => { jump_rel8(true); },
                0xEC => { io_check(r16(DX), 8); set_r8(0, port_in8(r16(DX))); },
                0xED => { io_check(r16(DX), osz); set_regw(AX, osz, port_read(r16(DX), osz)); },
                0xEE => { io_check(r16(DX), 8); port_out8(r16(DX), r8(0)); },
                0xEF => { io_check(r16(DX), osz); port_write(r16(DX), osz, regw(AX, osz)); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        0xF => {
            match op {
                0xF4 => { need_ring0(); cpu.halted = true; },
                0xF5 => { set_flag(CF, !flag(CF)); },
                0xF6, 0xF7 => { group3(op); },
                0xF8 => { set_flag(CF, false); },
                0xF9 => { set_flag(CF, true); },
                0xFA => { io_sensitive(); set_flag(IF, false); },
                0xFB => { io_sensitive(); if !flag(IF) { shadow = true; } set_flag(IF, true); },
                0xFC => { set_flag(DF, false); },
                0xFD => { set_flag(DF, true); },
                0xFE, 0xFF => { group45(op); },
                _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
            }
        },
        _ => { cpu.ip = saved.ip; stop("unimplemented opcode", op); },
    }
    return true;
}

// With --faults, every fault is reported on standard error: its vector and error code, where it
// happened and the bytes there. Page faults are left out unless they come from the kernel
// itself going wrong (they are how demand paging works).
var log_faults = false;
var faults_logged = 0;

fn note_fault(vec: u8, has_err: bool, err: u32) {
    if vec == 14 || faults_logged >= 40 { return; }
    faults_logged++;
    var msg: u8[>..] = [];
    format(msg, "g86m: fault ", vec);
    if has_err { format(msg, " error "); format_int(msg, err, 16, 4, '0'); }
    format(msg, " at ");
    format_int(msg, cpu.segs[CS], 16, 4, '0');
    format(msg, ":");
    format_int(msg, cpu.ip, 16, 8, '0');
    format(msg, "  bytes:");
    for i: u32 in 0..10 {
        format(msg, " ");
        format_int(msg, mem8(translate_quiet(cpu.base[CS] + cpu.ip + i)), 16, 2, '0');
    }
    format(msg, "\n");
    write_stderr(msg);
}

// Runs one instruction; if it faults, puts the state back and delivers the fault. A fault while
// delivering a fault becomes a double fault, and a fault while delivering that stops the machine
// (a real one would reset).
fn step() {
    saved = cpu;
    if exec_one() { return; }
    var vec = fault_vec;
    var has_err = fault_has_err;
    var err = fault_err;
    for attempt in 3 {
        cpu = saved;
        flush_tlb();                     // the privilege level may have gone back with the rest
        if log_faults { note_fault(vec, has_err, err); }
        if attempt == 2 { stop("triple fault; the last vector was", vec); return; }
        pending = true;
        pending_vec = vec;
        pending_has_err = has_err;
        pending_err = err;
        if exec_one() { return; }
        vec = 8;
        has_err = true;
        err = 0;
    }
}
