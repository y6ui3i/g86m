// Machine state: registers, flags, 1 MB of RAM, the stack.
//
// Registers are only touched through r32 / r16 / r8 and their setters, and segment registers are
// only loaded through set_seg, so that what a segment register means can change in one place when
// protected mode arrives.

import std;
import os;

let RAM_SIZE = 1048576;

let AX = 0; let CX = 1; let DX = 2; let BX = 3;
let SP = 4; let BP = 5; let SI = 6; let DI = 7;
let ES = 0; let CS = 1; let SS = 2; let DS = 3; let FS = 4; let GS = 5;

let CF = 0x0001; let PF = 0x0004; let AF = 0x0010; let ZF = 0x0040;
let SF = 0x0080; let TF = 0x0100; let IF = 0x0200; let DF = 0x0400; let OF = 0x0800;

// BIOS entries. Every IVT vector starts as BIOS_SEG:n; when execution arrives there the emulator
// performs the BIOS service instead of fetching an instruction (the same scheme as rustx86). A
// vector the guest rewrites no longer points here, so the guest's handler takes over with no
// special case.
let BIOS_SEG = 0xF000;

struct Cpu {
    regs: u32[8],
    segs: u16[6],        // the visible selectors
    base: u32[6],        // where each segment starts; in real mode, the selector times 16
    ip: u32,
    flags: u32,
    halted: bool,
    fault: bool,
}

var ram: u8[RAM_SIZE] = [0; RAM_SIZE];
var cpu: Cpu = Cpu { regs: [0; 8], segs: [0; 6], base: [0; 6], ip: 0, flags: 2, halted: false, fault: false };
var tty: u8[>..];
var stop_message: u8[>..];   // why the machine stopped, kept so it can be shown again later

// ---- Memory ----

// Physical memory. Addresses wrap at 1 MB: there is no memory above it yet and the A20 line is
// treated as off.
fn mem8(a: u32) -> u8 { return ram[a & 0xFFFFF]; }
fn set_mem8(a: u32, v: u8) { ram[a & 0xFFFFF] = v; }

fn mem16(a: u32) -> u16 {
    let lo: u16 = mem8(a);
    let hi: u16 = mem8(a + 1);
    return lo | hi << 8;
}

fn set_mem16(a: u32, v: u16) {
    set_mem8(a, v as! u8);
    set_mem8(a + 1, (v >> 8) as! u8);
}

// By real-mode segment value and 16-bit offset. The BIOS services use these.
fn lin(seg: u16, off: u16) -> u32 {
    let s: u32 = seg;
    return (s << 4) + off;
}

fn rd8(seg: u16, off: u16) -> u8 { return mem8(lin(seg, off)); }
fn rd16(seg: u16, off: u16) -> u16 { return mem16(lin(seg, off)); }
fn wr8(seg: u16, off: u16, v: u8) { set_mem8(lin(seg, off), v); }
fn wr16(seg: u16, off: u16, v: u16) { set_mem16(lin(seg, off), v); }

// By segment register (ES..GS) and offset, at a width of 8, 16 or 32 bits. Values travel as u32.
// Instruction execution uses these.
fn seg_read(s: i64, off: u32, w: u8) -> u32 {
    let a = cpu.base[s] + off;
    if w == 8 { return mem8(a); }
    if w == 16 { return mem16(a); }
    let lo: u32 = mem16(a);
    let hi: u32 = mem16(a + 2);
    return lo | hi << 16;
}

fn seg_write(s: i64, off: u32, w: u8, v: u32) {
    let a = cpu.base[s] + off;
    if w == 8 { set_mem8(a, v as! u8); }
    else if w == 16 { set_mem16(a, v as! u16); }
    else { set_mem16(a, v as! u16); set_mem16(a + 2, (v >> 16) as! u16); }
}

// ---- Registers ----

fn r32(i: u8) -> u32 { return cpu.regs[i & 7]; }
fn set_r32(i: u8, v: u32) { cpu.regs[i & 7] = v; }

fn r16(i: u8) -> u16 { return cpu.regs[i & 7] as! u16; }
fn set_r16(i: u8, v: u16) { cpu.regs[i & 7] = cpu.regs[i & 7] & 0xFFFF0000 | v; }

// 8-bit registers are numbered AL CL DL BL AH CH DH BH.
fn r8(i: u8) -> u8 {
    if i & 4 == 0 { return cpu.regs[i & 3] as! u8; }
    return (cpu.regs[i & 3] >> 8) as! u8;
}

fn set_r8(i: u8, v: u8) {
    let k = i & 3;
    let wide: u32 = v;
    if i & 4 == 0 { cpu.regs[k] = cpu.regs[k] & 0xFFFFFF00 | wide; }
    else { cpu.regs[k] = cpu.regs[k] & 0xFFFF00FF | wide << 8; }
}

fn regw(i: u8, w: u8) -> u32 {
    if w == 8 { return r8(i); }
    if w == 16 { return r16(i); }
    return r32(i);
}

fn set_regw(i: u8, w: u8, v: u32) {
    if w == 8 { set_r8(i, v as! u8); }
    else if w == 16 { set_r16(i, v as! u16); }
    else { set_r32(i, v); }
}

// Loads a segment register in real mode: the segment starts at the selector times 16.
fn set_seg(s: i64, v: u16) {
    let wide: u32 = v;
    cpu.segs[s] = v;
    cpu.base[s] = wide << 4;
}

// ---- Flags ----

fn flag(mask: u32) -> bool { return cpu.flags & mask != 0; }

fn set_flag(mask: u32, on: bool) {
    if on { cpu.flags |= mask; } else { cpu.flags &= ~mask; }
}

// What POPF and IRET may write. The machine is a 386: IOPL and NT (bits 12-14) can be written,
// bit 15 cannot, and above bit 15 nothing can (no AC bit, so not a 486; no ID bit, so no CPUID).
// Bit 1 always reads as one. Software tells CPU generations apart by exactly these bits.
fn write_flags(v: u32) { cpu.flags = v & 0x7FD5 | 2; }
fn pushed_flags() -> u16 { return (cpu.flags & 0x7FD5 | 2) as! u16; }

// ---- Stack ----
//
// In real mode the stack pointer is SP, 16 bits, whatever the size of what is pushed.

fn push16(v: u16) {
    let sp = r16(SP) - 2;
    set_r16(SP, sp);
    seg_write(SS, sp, 16, v);
}

fn pop16() -> u16 {
    let sp = r16(SP);
    let v = seg_read(SS, sp, 16) as! u16;
    set_r16(SP, sp + 2);
    return v;
}

fn push32(v: u32) {
    let sp = r16(SP) - 4;
    set_r16(SP, sp);
    seg_write(SS, sp, 32, v);
}

fn pop32() -> u32 {
    let sp = r16(SP);
    let v = seg_read(SS, sp, 32);
    set_r16(SP, sp + 4);
    return v;
}

// ---- Interrupts (real mode: through the IVT, with 16-bit FLAGS, CS and IP on the stack) ----

fn interrupt(n: u8) {
    push16(pushed_flags());
    push16(cpu.segs[CS]);
    push16(cpu.ip as! u16);
    set_flag(IF, false);
    set_flag(TF, false);
    let vec: u32 = n;
    cpu.ip = mem16(vec * 4);
    set_seg(CS, mem16(vec * 4 + 2));
}

fn iret() {
    cpu.ip = pop16();
    set_seg(CS, pop16());
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
    for i: u32 in 0..12 {
        format(msg, " ");
        format_int(msg, mem8(cpu.base[CS] + cpu.ip + i), 16, 2, '0');
    }
    format(msg, "\n");
    stop_message.clear();
    stop_message.append(msg);
    write_stderr(msg);
    cpu.halted = true;
    cpu.fault = true;
}
