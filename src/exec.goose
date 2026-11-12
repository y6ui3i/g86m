// Instruction execution. 16-bit real mode with 386 behaviour: PUSH SP pushes the old
// value, shift counts use 5 bits, and a divide error points at the start of the instruction.

import state;
import alu;
import bios;
import dev;

// ---- Decode state that lives for one instruction ----

var seg_ovr = -1;            // segment override: -1 none, 0..3 are ES CS SS DS
var rep: u8 = 0;             // 0 none, 1 REPNE (F2), 2 REP/REPE (F3)
var shadow = false;         // the instruction just executed holds interrupts off for one more
var insn_ip: u16 = 0;        // start of the instruction, prefixes included; where a fault returns to
var m_mod: u8 = 0;
var m_reg: u8 = 0;
var m_rm: u8 = 0;
var ea_seg: u16 = 0;         // segment value of the effective address
var ea_off: u16 = 0;

fn fetch8() -> u8 {
    let b = rd8(cpu.segs[CS], cpu.ip);
    cpu.ip += 1;
    return b;
}

fn fetch16() -> u16 {
    let w = rd16(cpu.segs[CS], cpu.ip);
    cpu.ip += 2;
    return w;
}

fn fetch_s8() -> u16 { return (fetch8() as! i8) as! u16; }

fn fetchw(w: u8) -> u32 {
    if w == 8 { return fetch8(); }
    return fetch16();
}

// The default segment def, replaced by an override prefix when there is one.
fn seg_val(def: i64) -> u16 {
    if seg_ovr >= 0 { return cpu.segs[seg_ovr]; }
    return cpu.segs[def];
}

fn decode_modrm() {
    let m = fetch8();
    m_mod = m >> 6;
    m_reg = m >> 3 & 7;
    m_rm = m & 7;
    if m_mod == 3 { return; }
    var off: u16 = 0;
    var def = DS;
    match m_rm {
        0 => { off = r16(BX) + r16(SI); },
        1 => { off = r16(BX) + r16(DI); },
        2 => { off = r16(BP) + r16(SI); def = SS; },
        3 => { off = r16(BP) + r16(DI); def = SS; },
        4 => { off = r16(SI); },
        5 => { off = r16(DI); },
        6 => { if m_mod == 0 { off = fetch16(); } else { off = r16(BP); def = SS; } },
        _ => { off = r16(BX); },
    }
    if m_mod == 1 { off += fetch_s8(); } else if m_mod == 2 { off += fetch16(); }
    ea_off = off;
    ea_seg = seg_val(def);
}

fn rm_read(w: u8) -> u32 {
    if m_mod == 3 { return regw(m_rm, w); }
    return rdw(ea_seg, ea_off, w);
}

fn rm_write(w: u8, v: u32) {
    if m_mod == 3 { set_regw(m_rm, w, v); } else { wrw(ea_seg, ea_off, w, v); }
}

fn width(op: u8) -> u8 { if op & 1 == 0 { return 8; } return 16; }

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

fn jump_rel8(taken: bool) {
    let d = fetch_s8();
    if taken { cpu.ip += d; }
}

// Divide error (#DE). It returns to the start of the instruction.
fn divide_error() {
    cpu.ip = insn_ip;
    interrupt(0);
}

fn far_call(seg: u16, off: u16) {
    push16(cpu.segs[CS]);
    push16(cpu.ip);
    cpu.segs[CS] = seg;
    cpu.ip = off;
}

// ---- String instructions (A4..A7, AA..AF) ----

fn string_op(op: u8) {
    let w = width(op);
    let n: u16 = if w == 8 { 1 } else { 2 };
    let d: u16 = if flag(DF) { 0 - n } else { n };
    let kind = op & 0xFE;
    let src = seg_val(DS);
    loop {
        if rep != 0 && r16(CX) == 0 { break; }
        match kind {
            0xA4 => {
                wrw(cpu.segs[ES], r16(DI), w, rdw(src, r16(SI), w));
                set_r16(SI, r16(SI) + d);
                set_r16(DI, r16(DI) + d);
            },
            0xA6 => {
                let a = rdw(src, r16(SI), w);
                let b = rdw(cpu.segs[ES], r16(DI), w);
                alu(7, a, b, w);
                set_r16(SI, r16(SI) + d);
                set_r16(DI, r16(DI) + d);
            },
            0xAA => {
                wrw(cpu.segs[ES], r16(DI), w, regw(0, w));
                set_r16(DI, r16(DI) + d);
            },
            0xAC => {
                set_regw(0, w, rdw(src, r16(SI), w));
                set_r16(SI, r16(SI) + d);
            },
            _ => {
                alu(7, regw(0, w), rdw(cpu.segs[ES], r16(DI), w), w);
                set_r16(DI, r16(DI) + d);
            },
        }
        if rep == 0 { break; }
        set_r16(CX, r16(CX) - 1);
        if kind == 0xA6 || kind == 0xAE {
            if rep == 2 && !flag(ZF) { break; }
            if rep == 1 && flag(ZF) { break; }
        }
    }
}

// ---- Group instructions ----

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
            if w == 8 {
                let a: u32 = r8(0);
                let p = a * v;
                set_r16(AX, p as! u16);
                set_flag(CF, p > 0xFF);
                set_flag(OF, p > 0xFF);
            } else {
                // Never multiply a call that returns a narrower type by a wider value directly
                // (docs/goose-notes.md, item 1).
                let a: u32 = r16(AX);
                let p = a * v;
                set_r16(AX, p as! u16);
                set_r16(DX, (p >> 16) as! u16);
                set_flag(CF, p > 0xFFFF);
                set_flag(OF, p > 0xFFFF);
            }
        },
        5 => {
            if w == 8 {
                let p = sx(r8(0), 8) * sx(v, 8);
                set_r16(AX, p as! u16);
                let over = p < -128 || p > 127;
                set_flag(CF, over);
                set_flag(OF, over);
            } else {
                let p = sx(r16(AX), 16) * sx(v, 16);
                set_r16(AX, p as! u16);
                set_r16(DX, (p >> 16) as! u16);
                let over = p < -32768 || p > 32767;
                set_flag(CF, over);
                set_flag(OF, over);
            }
        },
        6 => {
            if v == 0 { divide_error(); return; }
            if w == 8 {
                let n: u32 = r16(AX);
                let q = n / v;
                if q > 0xFF { divide_error(); return; }
                set_r8(0, q as! u8);
                set_r8(4, (n % v) as! u8);
            } else {
                let hi: u32 = r16(DX);
                let lo: u32 = r16(AX);
                let n = hi << 16 | lo;
                let q = n / v;
                if q > 0xFFFF { divide_error(); return; }
                set_r16(AX, q as! u16);
                set_r16(DX, (n % v) as! u16);
            }
        },
        _ => {
            if v == 0 { divide_error(); return; }
            if w == 8 {
                let n = sx(r16(AX), 16);
                let dv = sx(v, 8);
                let q = n / dv;
                if q < -128 || q > 127 { divide_error(); return; }
                set_r8(0, q as! u8);
                set_r8(4, (n - q * dv) as! u8);
            } else {
                let hi: i64 = sx(r16(DX), 16);
                let lo: i64 = r16(AX);
                let n = hi * 65536 + lo;
                let dv = sx(v, 16);
                let q = n / dv;
                if q < -32768 || q > 32767 { divide_error(); return; }
                set_r16(AX, q as! u16);
                set_r16(DX, (n - q * dv) as! u16);
            }
        },
    }
}

// FE / FF: INC DEC CALL CALLF JMP JMPF PUSH
fn group45(op: u8) {
    let w = width(op);
    decode_modrm();
    if m_reg == 0 { rm_write(w, inc(rm_read(w), w)); return; }
    if m_reg == 1 { rm_write(w, dec(rm_read(w), w)); return; }
    if w == 8 { stop("undefined FE /r", m_reg); return; }
    match m_reg {
        2 => { let t = rm_read(16) as! u16; push16(cpu.ip); cpu.ip = t; },
        3 => {
            if m_mod == 3 { stop("far call to register", m_rm); return; }
            far_call(rd16(ea_seg, ea_off + 2), rd16(ea_seg, ea_off));
        },
        4 => { cpu.ip = rm_read(16) as! u16; },
        5 => {
            if m_mod == 3 { stop("far jump to register", m_rm); return; }
            let off = rd16(ea_seg, ea_off);
            cpu.segs[CS] = rd16(ea_seg, ea_off + 2);
            cpu.ip = off;
        },
        6 => { push16(rm_read(16) as! u16); },
        _ => { stop("undefined FF /7", m_reg); },
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

// ---- One instruction ----

fn step() {
    // At a BIOS entry: perform the service instead of fetching an instruction, then IRET.
    if cpu.segs[CS] == BIOS_SEG && cpu.ip < 256 {
        bios_call(cpu.ip as! u8);
        iret();
        return;
    }

    insn_ip = cpu.ip;
    shadow = false;
    seg_ovr = -1;
    rep = 0;
    var op = fetch8();
    loop {
        match op {
            0x26 => { seg_ovr = ES; },
            0x2E => { seg_ovr = CS; },
            0x36 => { seg_ovr = SS; },
            0x3E => { seg_ovr = DS; },
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
        0x06 => { push16(cpu.segs[ES]); },
        0x07 => { cpu.segs[ES] = pop16(); },
        0x0E => { push16(cpu.segs[CS]); },
        0x16 => { push16(cpu.segs[SS]); },
        0x17 => { cpu.segs[SS] = pop16(); shadow = true; },
        0x1E => { push16(cpu.segs[DS]); },
        0x1F => { cpu.segs[DS] = pop16(); },
        0x27 => { daa_das(false); },
        0x2F => { daa_das(true); },
        0x37 => { aaa_aas(false); },
        0x3F => { aaa_aas(true); },

        0x40..0x48 => { set_r16(op, inc(r16(op), 16) as! u16); },
        0x48..0x50 => { set_r16(op, dec(r16(op), 16) as! u16); },
        0x50..0x58 => { push16(r16(op)); },
        0x58..0x60 => { let v = pop16(); set_r16(op, v); },

        0x60 => {
            let sp0 = r16(SP);
            for i: u8 in 0..8 { if i == 4 { push16(sp0); } else { push16(r16(i)); } }
        },
        0x61 => {
            for k: u8 in 0..8 {
                let i = 7 - k;
                let v = pop16();
                if i != 4 { set_r16(i, v); }
            }
        },
        0x68 => { push16(fetch16()); },
        0x6A => { push16(fetch_s8()); },
        0x69, 0x6B => {
            decode_modrm();
            let a = sx(rm_read(16), 16);
            let b = if op == 0x69 { sx(fetch16(), 16) } else { sx(fetch_s8(), 16) };
            let p = a * b;
            set_r16(m_reg, p as! u16);
            let over = p < -32768 || p > 32767;
            set_flag(CF, over);
            set_flag(OF, over);
        },

        0x70..0x80 => { jump_rel8(cond(op & 0x0F)); },

        0x80..0x84 => {
            let w = width(op);
            decode_modrm();
            let a = rm_read(w);
            var b: u32 = 0;
            if op == 0x81 { b = fetch16(); } else if op == 0x83 { b = fetch_s8(); } else { b = fetch8(); }
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
        0x8C => { decode_modrm(); rm_write(16, cpu.segs[m_reg & 3]); },
        0x8D => { decode_modrm(); set_r16(m_reg, ea_off); },
        0x8E => { decode_modrm(); cpu.segs[m_reg & 3] = rm_read(16) as! u16; if m_reg & 3 == SS { shadow = true; } },
        0x8F => { let v = pop16(); decode_modrm(); rm_write(16, v); },

        0x90..0x98 => { let t = r16(AX); set_r16(AX, r16(op)); set_r16(op, t); },
        0x98 => { set_r16(AX, (r8(0) as! i8) as! u16); },
        0x99 => { set_r16(DX, if r16(AX) & 0x8000 != 0 { 0xFFFF } else { 0 }); },
        0x9A => { let off = fetch16(); let seg = fetch16(); far_call(seg, off); },
        0x9B => {},
        0x9C => { push16(pushed_flags()); },
        0x9D => { write_flags(pop16()); },
        0x9E => { cpu.flags = cpu.flags & 0xFF00 | (r8(4) & 0xD5) | 2; },
        0x9F => { set_r8(4, cpu.flags as! u8); },

        0xA0 => { let off = fetch16(); set_r8(0, rd8(seg_val(DS), off)); },
        0xA1 => { let off = fetch16(); set_r16(AX, rd16(seg_val(DS), off)); },
        0xA2 => { let off = fetch16(); wr8(seg_val(DS), off, r8(0)); },
        0xA3 => { let off = fetch16(); wr16(seg_val(DS), off, r16(AX)); },
        0xA4..0xA8 => { string_op(op); },
        0xA8, 0xA9 => { let w = width(op); alu(4, regw(0, w), fetchw(w), w); },
        0xAA..0xB0 => { string_op(op); },

        0xB0..0xB8 => { let v = fetch8(); set_r8(op, v); },
        0xB8..0xC0 => { let v = fetch16(); set_r16(op, v); },

        0xC0, 0xC1 => {
            let w = width(op);
            decode_modrm();
            let n = fetch8();
            rm_write(w, shift(m_reg, rm_read(w), n, w));
        },
        0xC2 => { let n = fetch16(); cpu.ip = pop16(); set_r16(SP, r16(SP) + n); },
        0xC3 => { cpu.ip = pop16(); },
        0xC4, 0xC5 => {
            decode_modrm();
            if m_mod == 3 { stop("LES/LDS with register", op); return; }
            set_r16(m_reg, rd16(ea_seg, ea_off));
            cpu.segs[if op == 0xC4 { ES } else { DS }] = rd16(ea_seg, ea_off + 2);
        },
        0xC6, 0xC7 => { let w = width(op); decode_modrm(); rm_write(w, fetchw(w)); },
        0xC8 => {
            let size = fetch16();
            let level = fetch8() & 0x1F;
            push16(r16(BP));
            let frame = r16(SP);
            if level > 0 {
                for i in 1..level {
                    set_r16(BP, r16(BP) - 2);
                    push16(rd16(cpu.segs[SS], r16(BP)));
                }
                push16(frame);
            }
            set_r16(BP, frame);
            set_r16(SP, r16(SP) - size);
        },
        0xC9 => { set_r16(SP, r16(BP)); let v = pop16(); set_r16(BP, v); },
        0xCA => { let n = fetch16(); cpu.ip = pop16(); cpu.segs[CS] = pop16(); set_r16(SP, r16(SP) + n); },
        0xCB => { cpu.ip = pop16(); cpu.segs[CS] = pop16(); },
        0xCC => { interrupt(3); },
        0xCD => { let n = fetch8(); interrupt(n); },
        0xCE => { if flag(OF) { interrupt(4); } },
        0xCF => { iret(); },

        0xD0..0xD4 => {
            let w = width(op);
            decode_modrm();
            let n: u8 = if op < 0xD2 { 1 } else { r8(1) };
            rm_write(w, shift(m_reg, rm_read(w), n, w));
        },
        0xD4 => {
            let base = fetch8();
            if base == 0 { divide_error(); return; }
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
        0xD7 => { let idx: u16 = r8(0); set_r8(0, rd8(seg_val(DS), r16(BX) + idx)); },
        0xD8..0xE0 => { decode_modrm(); },      // no FPU: skip the operand

        0xE0 => { set_r16(CX, r16(CX) - 1); jump_rel8(r16(CX) != 0 && !flag(ZF)); },
        0xE1 => { set_r16(CX, r16(CX) - 1); jump_rel8(r16(CX) != 0 && flag(ZF)); },
        0xE2 => { set_r16(CX, r16(CX) - 1); jump_rel8(r16(CX) != 0); },
        0xE3 => { jump_rel8(r16(CX) == 0); },
        0xE4 => { let port = fetch8(); set_r8(0, port_in8(port)); },
        0xE5 => { let port = fetch8(); set_r16(AX, port_in(port)); },
        0xE6 => { let port = fetch8(); port_out8(port, r8(0)); },
        0xE7 => { let port = fetch8(); port_out(port, r16(AX)); },
        0xE8 => { let d = fetch16(); push16(cpu.ip); cpu.ip += d; },
        0xE9 => { let d = fetch16(); cpu.ip += d; },
        0xEA => { let off = fetch16(); let seg = fetch16(); cpu.segs[CS] = seg; cpu.ip = off; },
        0xEB => { jump_rel8(true); },
        0xEC => { set_r8(0, port_in8(r16(DX))); },
        0xED => { set_r16(AX, port_in(r16(DX))); },
        0xEE => { port_out8(r16(DX), r8(0)); },
        0xEF => { port_out(r16(DX), r16(AX)); },

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
