// Machine state and memory: registers, flags, segment caches, control registers, 1 MB of RAM,
// paging, and the checks every memory access goes through.
//
// Registers are only touched through r32 / r16 / r8 and their setters. Guest memory is reached in
// three ways: by physical address (mem8 ...), by linear address through paging (lin_read ...), and
// by segment register and offset with the segment's limit and rights checked (seg_read ...).
//
// A fault cuts the current instruction short: raise() records it and returns from exec_one(), the
// function in exec.goose that runs one instruction, however deep the call that found the problem.
// So anything that can fault must run inside exec_one. The BIOS services use the unchecked
// real-mode helpers (rd8 ...) instead.
//
// The compiler holds us to that: a function that can fault and is called from nowhere is an
// error, because it is not inside a call of exec_one. Do not keep unused helpers here.

import std;
import os;
import exec;

let RAM_SIZE = 134217728;       // 128 MB

let AX = 0; let CX = 1; let DX = 2; let BX = 3;
let SP = 4; let BP = 5; let SI = 6; let DI = 7;
let ES = 0; let CS = 1; let SS = 2; let DS = 3; let FS = 4; let GS = 5;

let CF = 0x0001; let PF = 0x0004; let AF = 0x0010; let ZF = 0x0040;
let SF = 0x0080; let TF = 0x0100; let IF = 0x0200; let DF = 0x0400; let OF = 0x0800;
let IOPL = 0x3000; let NT = 0x4000; let RF = 0x10000; let VM = 0x20000;

// Segment cache attributes: the descriptor's access byte in bits 0-7, its flags nibble in bits
// 12-15, and a bit of our own for "holds a usable segment" (a null selector clears it).
let A_ACCESSED = 0x01; let A_RW = 0x02; let A_DOWN_CONF = 0x04; let A_CODE = 0x08;
let A_S = 0x10; let A_PRESENT = 0x80; let A_BIG = 0x4000; let A_VALID = 0x10000;

// BIOS entries. Every IVT vector starts as BIOS_SEG:n; when execution arrives there the emulator
// performs the BIOS service instead of fetching an instruction (the same scheme as rustx86). A
// vector the guest rewrites no longer points here, so the guest's handler takes over with no
// special case.
let BIOS_SEG = 0xF000;

struct Cpu {
    regs: u32[8],
    segs: u16[6],        // the visible selectors
    base: u32[6],        // the hidden part of each segment register: where the segment starts,
    limit: u32[6],       // its last valid offset,
    attr: u32[6],        // and its rights (see A_... above)
    ip: u32,
    flags: u32,
    cpl: u8,             // current privilege level: 0 in real mode, 3 in virtual-8086 mode
    halted: bool,
    fault: bool,
}

var cpu: Cpu = Cpu { regs: [0; 8], segs: [0; 6], base: [0; 6], limit: [0xFFFF; 6],
                     attr: [0x10093, 0x1009B, 0x10093, 0x10093, 0x10093, 0x10093],
                     ip: 0, flags: 2, cpl: 0, halted: false, fault: false };
// The state the current instruction started from, to go back to when it faults.
var saved: Cpu = cpu;

var tty: u8[>..];
var stop_message: u8[>..];   // why the machine stopped, kept so it can be shown again later

// ---- Control registers and descriptor tables ----

var cr: u32[8] = [0; 8];     // CR0 starts at zero: no coprocessor, so the ET bit is clear
var gdtr_base: u32 = 0;
var gdtr_limit: u32 = 0;
var idtr_base: u32 = 0;
var idtr_limit: u32 = 0x3FF;
var ldtr_sel: u16 = 0;
var ldtr_base: u32 = 0;
var ldtr_limit: u32 = 0;
var tr_sel: u16 = 0;
var tr_base: u32 = 0;
var tr_limit: u32 = 0;
var tr_32 = true;            // the task segment is a 32-bit one

// ---- Cached translations ----
//
// Three one-entry caches of the last page translated: for instruction bytes, for data reads and
// for data writes. Each holds a linear page number and the physical address behind it; FFFFFFFFh
// means empty. A real 386 keeps such translations too (its TLB), with the same consequence: a
// change to the page tables takes effect only after CR3 is reloaded. The write entry is separate
// because only a write marks the page dirty and checks that it may be written.
var code_page: u32 = 0xFFFFFFFF;
var code_phys: u32 = 0;
var read_page: u32 = 0xFFFFFFFF;
var read_phys: u32 = 0;
var write_page: u32 = 0xFFFFFFFF;
var write_phys: u32 = 0;

// Forgets the cached translations. Called when the page tables are switched, paging is turned on
// or off, or the privilege level changes (a cached page was checked for one level only).
fn flush_tlb() {
    code_page = 0xFFFFFFFF;
    read_page = 0xFFFFFFFF;
    write_page = 0xFFFFFFFF;
}

fn set_cpl(level: u8) {
    if level != cpu.cpl { flush_tlb(); }
    cpu.cpl = level;
}

fn protected() -> bool { return cr[0] & 1 != 0; }
fn paging() -> bool { return cr[0] & 0x80000000 != 0; }
fn v86() -> bool { return cpu.flags & VM != 0; }
fn iopl() -> u8 { return (cpu.flags >> 12 & 3) as! u8; }

// ---- Faults ----

var fault_vec: u8 = 0;
var fault_has_err = false;
var fault_err: u32 = 0;

// Abandons the instruction being executed with fault vec. step() then restores the state the
// instruction started from and delivers the fault.
fn raise(vec: u8, has_err: bool, err: u32) {
    fault_vec = vec;
    fault_has_err = has_err;
    fault_err = err;
    return false from exec_one;
}

fn raise_gp(err: u32) { raise(13, true, err); }          // general protection
fn raise_ss(err: u32) { raise(12, true, err); }          // stack fault
fn raise_np(err: u32) { raise(11, true, err); }          // segment not present

// ---- Physical memory ----
//
// The 16-bit machine (boot sectors, floppies, ROMs) has 1 MB and its addresses wrap there, as on
// a PC with the A20 line off. The 32-bit machine (a Linux kernel) has all of RAM_SIZE. Above the
// end of memory nothing answers: reads give FFh and writes are dropped.
var phys_mask: u32 = 0xFFFFF;

fn mem8(a: u32) -> u8 {
    let p = a & phys_mask;
    if p < RAM_SIZE { return ram[p]; }
    return 0xFF;
}

fn set_mem8(a: u32, v: u8) {
    let p = a & phys_mask;
    if p < RAM_SIZE { ram[p] = v; }
}

fn mem16(a: u32) -> u16 {
    let lo: u16 = mem8(a);
    let hi: u16 = mem8(a + 1);
    return lo | hi << 8;
}

fn set_mem16(a: u32, v: u16) {
    set_mem8(a, v as! u8);
    set_mem8(a + 1, (v >> 8) as! u8);
}

fn mem32(a: u32) -> u32 {
    let lo: u32 = mem16(a);
    let hi: u32 = mem16(a + 2);
    return lo | hi << 16;
}

fn set_mem32(a: u32, v: u32) {
    set_mem16(a, v as! u16);
    set_mem16(a + 2, (v >> 16) as! u16);
}

// By real-mode segment value and 16-bit offset, with no checks. The BIOS services use these.
fn lin(seg: u16, off: u16) -> u32 {
    let s: u32 = seg;
    return (s << 4) + off;
}

fn rd8(seg: u16, off: u16) -> u8 { return mem8(lin(seg, off)); }
fn rd16(seg: u16, off: u16) -> u16 { return mem16(lin(seg, off)); }
fn wr8(seg: u16, off: u16, v: u8) { set_mem8(lin(seg, off), v); }
fn wr16(seg: u16, off: u16, v: u16) { set_mem16(lin(seg, off), v); }

// ---- Paging ----

// The physical address behind a linear one. Walks the two-level page table, checks the access
// against the user and writable bits, and marks the entries accessed (and dirty on a write).
// On a 386 a supervisor write ignores the writable bit.
fn translate(a: u32, write: bool, user: bool) -> u32 {
    if !paging() { return a; }
    let code: u32 = (if write { 2 } else { 0 }) | (if user { 4 } else { 0 });
    let pde_at = (cr[3] & 0xFFFFF000) + (a >> 22) * 4;
    let pde = mem32(pde_at);
    if pde & 1 == 0 { cr[2] = a; raise(14, true, code); }
    let pte_at = (pde & 0xFFFFF000) + (a >> 12 & 0x3FF) * 4;
    let pte = mem32(pte_at);
    if pte & 1 == 0 { cr[2] = a; raise(14, true, code); }
    if user && (pde & pte & 4 == 0 || (write && pde & pte & 2 == 0)) { cr[2] = a; raise(14, true, code | 1); }
    if pde & 0x20 == 0 { set_mem32(pde_at, pde | 0x20); }
    let want: u32 = if write { 0x60 } else { 0x20 };
    if pte & want != want { set_mem32(pte_at, pte | want); }
    return pte & 0xFFFFF000 | a & 0xFFF;
}

// The physical address behind a linear one for debugging output: no checks, no faults, no
// accessed bits. Gives the linear address back where there is no mapping.
fn translate_quiet(a: u32) -> u32 {
    if !paging() { return a; }
    let pde = mem32((cr[3] & 0xFFFFF000) + (a >> 22) * 4);
    if pde & 1 == 0 { return a; }
    let pte = mem32((pde & 0xFFFFF000) + (a >> 12 & 0x3FF) * 4);
    if pte & 1 == 0 { return a; }
    return pte & 0xFFFFF000 | a & 0xFFF;
}

// By linear address, at a width of 8, 16 or 32 bits. An access that crosses a page boundary is
// translated byte by byte, after checking every page it touches so that a fault leaves nothing
// half written.
fn lin_read(a: u32, w: u8, user: bool) -> u32 {
    let n: u32 = ((w as u32) >> 3);
    if !paging() || (a & 0xFFF) + n <= 0x1000 {
        let p = translate(a, false, user);
        if w == 8 { return mem8(p); }
        if w == 16 { return mem16(p); }
        return mem32(p);
    }
    var v: u32 = 0;
    for i: u32 in 0..n {
        let b: u32 = mem8(translate(a + i, false, user));
        v |= b << (i * 8);
    }
    return v;
}

fn lin_write(a: u32, w: u8, v: u32, user: bool) {
    let n: u32 = ((w as u32) >> 3);
    if !paging() || (a & 0xFFF) + n <= 0x1000 {
        let p = translate(a, true, user);
        if w == 8 { set_mem8(p, v as! u8); }
        else if w == 16 { set_mem16(p, v as! u16); }
        else { set_mem32(p, v); }
        return;
    }
    let last = translate(a + n - 1, true, user);
    for i: u32 in 0..n { set_mem8(translate(a + i, true, user), (v >> (i * 8)) as! u8); }
}

// System tables (GDT, LDT, IDT, the task segment) are read and written as the supervisor.
fn sys_read(a: u32, w: u8) -> u32 { return lin_read(a, w, false); }
fn sys_write(a: u32, w: u8, v: u32) { lin_write(a, w, v, false); }

// ---- Segmented access ----

// Checks an access of w bits at offset off in segment s and returns its linear address.
// A violation is a stack fault for SS and a general protection fault for the others.
fn seg_check(s: i64, off: u32, w: u8, write: bool) -> u32 {
    let a = cpu.attr[s];
    let last = off + ((w as u32) >> 3) - 1;
    var bad = last < off;
    if protected() && !v86() {
        if a & A_VALID == 0 { bad = true; }
        else if a & A_CODE != 0 { if write || a & A_RW == 0 { bad = true; } }
        else if write && a & A_RW == 0 { bad = true; }
    }
    if a & A_CODE == 0 && a & A_DOWN_CONF != 0 {
        // Expand-down data: valid offsets are those above the limit.
        let top: u32 = if a & A_BIG != 0 { 0xFFFFFFFF } else { 0xFFFF };
        if off <= cpu.limit[s] || last > top { bad = true; }
    } else if last > cpu.limit[s] { bad = true; }
    if bad { if s == SS { raise_ss(0); } else { raise_gp(0); } }
    return cpu.base[s] + off;
}

// Data access at the current privilege level, through the cached translations when the access
// lies within one page.
fn data_read(a: u32, w: u8) -> u32 {
    if (a & 0xFFF) + ((w as u32) >> 3) > 0x1000 { return lin_read(a, w, cpu.cpl == 3); }
    if a >> 12 != read_page {
        read_phys = translate(a, false, cpu.cpl == 3) & 0xFFFFF000;
        read_page = a >> 12;
    }
    let p = read_phys | a & 0xFFF;
    if w == 8 { return mem8(p); }
    if w == 16 { return mem16(p); }
    return mem32(p);
}

fn data_write(a: u32, w: u8, v: u32) {
    if (a & 0xFFF) + ((w as u32) >> 3) > 0x1000 { lin_write(a, w, v, cpu.cpl == 3); return; }
    if a >> 12 != write_page {
        write_phys = translate(a, true, cpu.cpl == 3) & 0xFFFFF000;
        write_page = a >> 12;
    }
    let p = write_phys | a & 0xFFF;
    if w == 8 { set_mem8(p, v as! u8); }
    else if w == 16 { set_mem16(p, v as! u16); }
    else { set_mem32(p, v); }
}

fn seg_read(s: i64, off: u32, w: u8) -> u32 { return data_read(seg_check(s, off, w, false), w); }
fn seg_write(s: i64, off: u32, w: u8, v: u32) { data_write(seg_check(s, off, w, true), w, v); }

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

// Loads a segment register the real-mode way: the segment starts at the selector times 16. The
// limit and rights stay as they were, as on a real 386.
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

// Writes the bits of v that mask allows into EFLAGS. The machine is a 386: nothing above the VM
// bit exists (no AC bit, so not a 486; no ID bit, so no CPUID), and bit 1 always reads as one.
// Software tells CPU generations apart by exactly these bits.
fn write_flags(v: u32, mask: u32) {
    let m = mask & 0x00037FD5;
    cpu.flags = cpu.flags & ~m | v & m | 2;
}

// ---- Stack ----
//
// The stack pointer is ESP when the stack segment is a 32-bit one and SP otherwise, whatever the
// size of what is pushed.

fn stack32() -> bool { return cpu.attr[SS] & A_BIG != 0; }
fn sp_get() -> u32 { if stack32() { return r32(SP); } return r16(SP); }
fn sp_set(v: u32) { if stack32() { set_r32(SP, v); } else { set_r16(SP, v as! u16); } }

fn push_w(v: u32, w: u8) {
    var sp = sp_get() - ((w as u32) >> 3);
    if !stack32() { sp &= 0xFFFF; }
    seg_write(SS, sp, w, v);
    sp_set(sp);
}

fn pop_w(w: u8) -> u32 {
    let sp = sp_get();
    let v = seg_read(SS, sp, w);
    sp_set(sp + ((w as u32) >> 3));
    return v;
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
