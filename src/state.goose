// Machine state: registers, flags, 1 MB of RAM, the stack.
//
// Registers are only touched through r16 / set_r16 / r8 / set_r8, so that widening
// them to 32 bits in M4 changes their storage in this file alone.

import std;
import os;

let RAM_SIZE = 1048576;

let AX = 0; let CX = 1; let DX = 2; let BX = 3;
let SP = 4; let BP = 5; let SI = 6; let DI = 7;
let ES = 0; let CS = 1; let SS = 2; let DS = 3;

let CF = 0x0001; let PF = 0x0004; let AF = 0x0010; let ZF = 0x0040;
let SF = 0x0080; let TF = 0x0100; let IF = 0x0200; let DF = 0x0400; let OF = 0x0800;

// BIOS entries. Every IVT vector starts as BIOS_SEG:n; when execution arrives there
// the emulator performs the BIOS service instead of fetching an instruction (the same
// scheme as rustx86). A vector the guest rewrites no longer points here, so the guest's
// handler takes over with no special case.
let BIOS_SEG = 0xF000;

struct Cpu {
    regs: u16[8],
    segs: u16[4],
    ip: u16,
    flags: u16,
    halted: bool,
    fault: bool,
}

var ram: u8[RAM_SIZE] = [0; RAM_SIZE];
var cpu: Cpu = Cpu { regs: [0; 8], segs: [0; 4], ip: 0, flags: 2, halted: false, fault: false };
var tty: u8[>..];
var stop_message: u8[>..];   // why the machine stopped, kept so it can be shown again later

// ---- Memory ----

fn lin(seg: u16, off: u16) -> i64 {
    return (((seg as i64) << 4) + off) & 0xFFFFF;
}

fn rd8(seg: u16, off: u16) -> u8 { return ram[lin(seg, off)]; }

fn rd16(seg: u16, off: u16) -> u16 {
    let lo: u16 = rd8(seg, off);
    let hi: u16 = rd8(seg, off + 1);
    return lo | hi << 8;
}

fn wr8(seg: u16, off: u16, v: u8) { ram[lin(seg, off)] = v; }

fn wr16(seg: u16, off: u16, v: u16) {
    wr8(seg, off, v as! u8);
    wr8(seg, off + 1, (v >> 8) as! u8);
}

// The same, taking the width (8 or 16) as an argument. Values travel as u32.
fn rdw(seg: u16, off: u16, w: u8) -> u32 {
    if w == 8 { return rd8(seg, off); }
    return rd16(seg, off);
}

fn wrw(seg: u16, off: u16, w: u8, v: u32) {
    if w == 8 { wr8(seg, off, v as! u8); } else { wr16(seg, off, v as! u16); }
}

// ---- Registers ----

fn r16(i: u8) -> u16 { return cpu.regs[i & 7]; }
fn set_r16(i: u8, v: u16) { cpu.regs[i & 7] = v; }

// 8-bit registers are numbered AL CL DL BL AH CH DH BH.
fn r8(i: u8) -> u8 {
    if i & 4 == 0 { return cpu.regs[i & 3] as! u8; }
    return (cpu.regs[i & 3] >> 8) as! u8;
}

fn set_r8(i: u8, v: u8) {
    let k = i & 3;
    if i & 4 == 0 { cpu.regs[k] = cpu.regs[k] & 0xFF00 | v; }
    else { cpu.regs[k] = cpu.regs[k] & 0x00FF | (v as u16) << 8; }
}

fn regw(i: u8, w: u8) -> u32 {
    if w == 8 { return r8(i); }
    return r16(i);
}

fn set_regw(i: u8, w: u8, v: u32) {
    if w == 8 { set_r8(i, v as! u8); } else { set_r16(i, v as! u16); }
}

// ---- Flags ----

fn flag(mask: u16) -> bool { return cpu.flags & mask != 0; }

fn set_flag(mask: u16, on: bool) {
    if on { cpu.flags |= mask; } else { cpu.flags &= ~mask; }
}

// Lets through only the bits POPF and IRET may write. The machine behaves as an 8086,
// so the top four bits (IOPL / NT) are not kept. PUSHF and interrupts push them as
// ones instead (pushed_flags). Software tells CPU generations apart by these four bits.
fn write_flags(v: u16) { cpu.flags = v & 0x0FD5 | 2; }
fn pushed_flags() -> u16 { return cpu.flags | 0xF002; }

// ---- Stack ----

fn push16(v: u16) {
    cpu.regs[SP] -= 2;
    wr16(cpu.segs[SS], cpu.regs[SP], v);
}

fn pop16() -> u16 {
    let v = rd16(cpu.segs[SS], cpu.regs[SP]);
    cpu.regs[SP] += 2;
    return v;
}

// ---- Interrupts ----

fn interrupt(n: u8) {
    push16(pushed_flags());
    push16(cpu.segs[CS]);
    push16(cpu.ip);
    set_flag(IF, false);
    set_flag(TF, false);
    let vec: u16 = (n as u16) * 4;
    cpu.ip = rd16(0, vec);
    cpu.segs[CS] = rd16(0, vec + 2);
}

fn iret() {
    cpu.ip = pop16();
    cpu.segs[CS] = pop16();
    write_flags(pop16());
}

// Stops the machine on anything unimplemented, rather than carrying on silently.
fn stop(what: u8[:], v: i64) {
    var msg: u8[>..] = [];
    format(msg, "g86m: ", what, " ");
    format_int(msg, v, 16, 2, '0');
    format(msg, " at ");
    format_int(msg, cpu.segs[CS], 16, 4, '0');
    format(msg, ":");
    format_int(msg, cpu.ip, 16, 4, '0');
    format(msg, "  bytes:");
    for i: u16 in 0..12 {
        format(msg, " ");
        format_int(msg, rd8(cpu.segs[CS], cpu.ip + i), 16, 2, '0');
    }
    format(msg, "\n");
    stop_message.clear();
    stop_message.append(msg);
    write_stderr(msg);
    cpu.halted = true;
    cpu.fault = true;
}
