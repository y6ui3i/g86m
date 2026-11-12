// M0: Goose でエミュレータの核が書けるかの試し書き (docs/experiments.md E001)。
// rustx86 の asm/hello.bin と asm/bench.bin が使う命令だけを実装した 8086 の断片。
//
//   goose build -o m0 probe/m0.goose && ./m0 testdata/hello.bin

import std;
import os;

let RAM_SIZE = 1048576;

let AX = 0; let CX = 1; let DX = 2; let BX = 3;
let SP = 4; let BP = 5; let SI = 6; let DI = 7;
let ES = 0; let CS = 1; let SS = 2; let DS = 3;

let CF = 0x0001; let PF = 0x0004; let AF = 0x0010; let ZF = 0x0040;
let SF = 0x0080; let DF = 0x0400; let OF = 0x0800;

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

fn get8(i: u8) -> u8 {
    if i < 4 { return cpu.regs[i] as! u8; }
    return (cpu.regs[i - 4] >> 8) as! u8;
}

fn set8(i: u8, v: u8) {
    if i < 4 { cpu.regs[i] = cpu.regs[i] & 0xFF00 | v; }
    else { cpu.regs[i - 4] = cpu.regs[i - 4] & 0x00FF | (v as u16) << 8; }
}

fn set_flag(mask: u16, on: bool) {
    if on { cpu.flags |= mask; } else { cpu.flags &= ~mask; }
}

fn parity8(v: u8) -> bool {
    var x = v;
    x ^= x >> 4;
    x ^= x >> 2;
    x ^= x >> 1;
    return x & 1 == 0;
}

fn set_szp16(r: u16) {
    set_flag(ZF, r == 0);
    set_flag(SF, r & 0x8000 != 0);
    set_flag(PF, parity8(r as! u8));
}

fn set_szp8(r: u8) {
    set_flag(ZF, r == 0);
    set_flag(SF, r & 0x80 != 0);
    set_flag(PF, parity8(r));
}

fn add16(a: u16, b: u16) -> u16 {
    let r = a + b;
    set_flag(CF, r < a);
    set_flag(OF, (a ^ r) & (b ^ r) & 0x8000 != 0);
    set_flag(AF, (a ^ b ^ r) & 0x10 != 0);
    set_szp16(r);
    return r;
}

fn sub16(a: u16, b: u16) -> u16 {
    let r = a - b;
    set_flag(CF, a < b);
    set_flag(OF, (a ^ b) & (a ^ r) & 0x8000 != 0);
    set_flag(AF, (a ^ b ^ r) & 0x10 != 0);
    set_szp16(r);
    return r;
}

fn logic16(r: u16) -> u16 {
    set_flag(CF, false);
    set_flag(OF, false);
    set_szp16(r);
    return r;
}

fn push16(v: u16) {
    cpu.regs[SP] -= 2;
    wr16(cpu.segs[SS], cpu.regs[SP], v);
}

fn pop16() -> u16 {
    let v = rd16(cpu.segs[SS], cpu.regs[SP]);
    cpu.regs[SP] += 2;
    return v;
}

fn jump_rel8(taken: bool) {
    let d = fetch8() as! i8;
    if taken { cpu.ip += d as! u16; }
}

fn unimpl(op: u8) {
    var msg: u8[>..] = [];
    format(msg, "unimplemented opcode ", op, " at ip ", cpu.ip - 1, "\n");
    write_stderr(msg);
    cpu.halted = true;
    cpu.fault = true;
}

// レジスタ同士の ModR/M だけを受ける。メモリオペランドは M1 で入れる。
fn modrm_rr(op: u8) -> u8 {
    let m = fetch8();
    if m < 0xC0 { unimpl(op); }
    return m;
}

fn step() {
    let op = fetch8();
    match op {
        0x01 => {
            let m = modrm_rr(op); let rm = m & 7; let reg = m >> 3 & 7;
            cpu.regs[rm] = add16(cpu.regs[rm], cpu.regs[reg]);
        },
        0x08 => {
            let m = modrm_rr(op); let rm = m & 7; let reg = m >> 3 & 7;
            let r = get8(rm) | get8(reg);
            set_flag(CF, false);
            set_flag(OF, false);
            set_szp8(r);
            set8(rm, r);
        },
        0x31 => {
            let m = modrm_rr(op); let rm = m & 7; let reg = m >> 3 & 7;
            cpu.regs[rm] = logic16(cpu.regs[rm] ^ cpu.regs[reg]);
        },
        0x39 => {
            let m = modrm_rr(op); let rm = m & 7; let reg = m >> 3 & 7;
            let unused = sub16(cpu.regs[rm], cpu.regs[reg]);
        },
        0x40..0x48 => {
            let r = op & 7;
            let carry = cpu.flags & CF != 0;
            cpu.regs[r] = add16(cpu.regs[r], 1);
            set_flag(CF, carry);
        },
        0x48..0x50 => {
            let r = op & 7;
            let carry = cpu.flags & CF != 0;
            cpu.regs[r] = sub16(cpu.regs[r], 1);
            set_flag(CF, carry);
        },
        0x50..0x58 => { push16(cpu.regs[op & 7]); },
        0x58..0x60 => { cpu.regs[op & 7] = pop16(); },
        0x74 => { jump_rel8(cpu.flags & ZF != 0); },
        0x75 => { jump_rel8(cpu.flags & ZF == 0); },
        0x8E => {
            let m = modrm_rr(op);
            cpu.segs[m >> 3 & 3] = cpu.regs[m & 7];
        },
        0x90 => {},
        0xA1 => { let off = fetch16(); cpu.regs[AX] = rd16(cpu.segs[DS], off); },
        0xA3 => { let off = fetch16(); wr16(cpu.segs[DS], off, cpu.regs[AX]); },
        0xAC => {
            set8(0, rd8(cpu.segs[DS], cpu.regs[SI]));
            if cpu.flags & DF != 0 { cpu.regs[SI] -= 1; } else { cpu.regs[SI] += 1; }
        },
        0xB0..0xB8 => { let v = fetch8(); set8(op & 7, v); },
        0xB8..0xC0 => { cpu.regs[op & 7] = fetch16(); },
        0xCD => {
            let n = fetch8();
            if n == 0x10 && get8(4) == 0x0E { tty.push(get8(0)); }
            else { unimpl(op); }
        },
        0xD1 => {
            let m = modrm_rr(op); let rm = m & 7;
            if m >> 3 & 7 != 4 { unimpl(op); }
            let v = cpu.regs[rm];
            let r = v << 1;
            set_flag(CF, v & 0x8000 != 0);
            set_flag(OF, (v ^ r) & 0x8000 != 0);
            set_szp16(r);
            cpu.regs[rm] = r;
        },
        0xE2 => {
            cpu.regs[CX] -= 1;
            jump_rel8(cpu.regs[CX] != 0);
        },
        0xE6 => { let port = fetch8(); },
        0xEB => { jump_rel8(true); },
        0xF4 => { cpu.halted = true; },
        0xFC => { set_flag(DF, false); },
        _ => { unimpl(op); },
    }
}

fn main() {
    let a = args();
    guard a.len >= 2 else { write_stderr("usage: m0 image.bin\n"); return; }
    var img: u8[>..] = [];
    guard read_file(a[1], img) else { write_stderr("cannot read image\n"); return; }
    for b, i in img { if i < 512 { ram[0x7C00 + i] = b; } }
    cpu.ip = 0x7C00;

    let t0 = clock_ns();
    var n = 0;
    while !cpu.halted && n < 2000000000 { step(); n++; }
    let t1 = clock_ns();

    write_stdout(tty);
    if tty.len > 0 { write_stdout("\n"); }
    let ms = (t1 - t0) / 1000000;
    var stats: u8[>..] = [];
    format(stats, "steps ", n, "  ms ", ms, "  fault ", cpu.fault,
           "  ax ", cpu.regs[AX], " bx ", cpu.regs[BX], " dx ", cpu.regs[DX], "\n");
    write_stderr(stats);
}
