// E002: the same fragment as probe/m0.goose, written in Rust for a speed comparison.
//
//   rustc --edition 2021 -C opt-level=3 -o build/m0_rs probe/m0.rs && ./build/m0_rs testdata/bench.bin

use std::io::Write;
use std::time::Instant;

const RAM_SIZE: usize = 1 << 20;

const AX: usize = 0; const CX: usize = 1; const SP: usize = 4; const SI: usize = 6;
const CS: usize = 1; const SS: usize = 2; const DS: usize = 3;

const CF: u16 = 0x0001; const PF: u16 = 0x0004; const AF: u16 = 0x0010; const ZF: u16 = 0x0040;
const SF: u16 = 0x0080; const DF: u16 = 0x0400; const OF: u16 = 0x0800;

struct Machine {
    regs: [u16; 8],
    segs: [u16; 4],
    ip: u16,
    flags: u16,
    halted: bool,
    fault: bool,
    ram: Box<[u8; RAM_SIZE]>,
    tty: Vec<u8>,
}

fn lin(seg: u16, off: u16) -> usize {
    (((seg as usize) << 4) + off as usize) & 0xFFFFF
}

fn parity8(v: u8) -> bool {
    let mut x = v;
    x ^= x >> 4;
    x ^= x >> 2;
    x ^= x >> 1;
    x & 1 == 0
}

impl Machine {
    fn rd8(&self, seg: u16, off: u16) -> u8 { self.ram[lin(seg, off)] }

    fn rd16(&self, seg: u16, off: u16) -> u16 {
        let lo = self.rd8(seg, off) as u16;
        let hi = self.rd8(seg, off.wrapping_add(1)) as u16;
        lo | hi << 8
    }

    fn wr8(&mut self, seg: u16, off: u16, v: u8) { self.ram[lin(seg, off)] = v; }

    fn wr16(&mut self, seg: u16, off: u16, v: u16) {
        self.wr8(seg, off, v as u8);
        self.wr8(seg, off.wrapping_add(1), (v >> 8) as u8);
    }

    fn fetch8(&mut self) -> u8 {
        let b = self.rd8(self.segs[CS], self.ip);
        self.ip = self.ip.wrapping_add(1);
        b
    }

    fn fetch16(&mut self) -> u16 {
        let w = self.rd16(self.segs[CS], self.ip);
        self.ip = self.ip.wrapping_add(2);
        w
    }

    fn get8(&self, i: u8) -> u8 {
        if i < 4 { self.regs[i as usize] as u8 } else { (self.regs[(i - 4) as usize] >> 8) as u8 }
    }

    fn set8(&mut self, i: u8, v: u8) {
        if i < 4 {
            let r = &mut self.regs[i as usize];
            *r = *r & 0xFF00 | v as u16;
        } else {
            let r = &mut self.regs[(i - 4) as usize];
            *r = *r & 0x00FF | (v as u16) << 8;
        }
    }

    fn set_flag(&mut self, mask: u16, on: bool) {
        if on { self.flags |= mask; } else { self.flags &= !mask; }
    }

    fn set_szp16(&mut self, r: u16) {
        self.set_flag(ZF, r == 0);
        self.set_flag(SF, r & 0x8000 != 0);
        self.set_flag(PF, parity8(r as u8));
    }

    fn set_szp8(&mut self, r: u8) {
        self.set_flag(ZF, r == 0);
        self.set_flag(SF, r & 0x80 != 0);
        self.set_flag(PF, parity8(r));
    }

    fn add16(&mut self, a: u16, b: u16) -> u16 {
        let r = a.wrapping_add(b);
        self.set_flag(CF, r < a);
        self.set_flag(OF, (a ^ r) & (b ^ r) & 0x8000 != 0);
        self.set_flag(AF, (a ^ b ^ r) & 0x10 != 0);
        self.set_szp16(r);
        r
    }

    fn sub16(&mut self, a: u16, b: u16) -> u16 {
        let r = a.wrapping_sub(b);
        self.set_flag(CF, a < b);
        self.set_flag(OF, (a ^ b) & (a ^ r) & 0x8000 != 0);
        self.set_flag(AF, (a ^ b ^ r) & 0x10 != 0);
        self.set_szp16(r);
        r
    }

    fn logic16(&mut self, r: u16) -> u16 {
        self.set_flag(CF, false);
        self.set_flag(OF, false);
        self.set_szp16(r);
        r
    }

    fn push16(&mut self, v: u16) {
        self.regs[SP] = self.regs[SP].wrapping_sub(2);
        self.wr16(self.segs[SS], self.regs[SP], v);
    }

    fn pop16(&mut self) -> u16 {
        let v = self.rd16(self.segs[SS], self.regs[SP]);
        self.regs[SP] = self.regs[SP].wrapping_add(2);
        v
    }

    fn jump_rel8(&mut self, taken: bool) {
        let d = self.fetch8() as i8;
        if taken { self.ip = self.ip.wrapping_add(d as u16); }
    }

    fn unimpl(&mut self, op: u8) {
        eprintln!("unimplemented opcode {} at ip {}", op, self.ip.wrapping_sub(1));
        self.halted = true;
        self.fault = true;
    }

    fn modrm_rr(&mut self, op: u8) -> u8 {
        let m = self.fetch8();
        if m < 0xC0 { self.unimpl(op); }
        m
    }

    fn step(&mut self) {
        let op = self.fetch8();
        match op {
            0x01 => {
                let m = self.modrm_rr(op); let rm = (m & 7) as usize; let reg = (m >> 3 & 7) as usize;
                self.regs[rm] = self.add16(self.regs[rm], self.regs[reg]);
            }
            0x08 => {
                let m = self.modrm_rr(op); let rm = m & 7; let reg = m >> 3 & 7;
                let r = self.get8(rm) | self.get8(reg);
                self.set_flag(CF, false);
                self.set_flag(OF, false);
                self.set_szp8(r);
                self.set8(rm, r);
            }
            0x31 => {
                let m = self.modrm_rr(op); let rm = (m & 7) as usize; let reg = (m >> 3 & 7) as usize;
                self.regs[rm] = self.logic16(self.regs[rm] ^ self.regs[reg]);
            }
            0x39 => {
                let m = self.modrm_rr(op); let rm = (m & 7) as usize; let reg = (m >> 3 & 7) as usize;
                let _ = self.sub16(self.regs[rm], self.regs[reg]);
            }
            0x40..=0x47 => {
                let r = (op & 7) as usize;
                let carry = self.flags & CF != 0;
                self.regs[r] = self.add16(self.regs[r], 1);
                self.set_flag(CF, carry);
            }
            0x48..=0x4F => {
                let r = (op & 7) as usize;
                let carry = self.flags & CF != 0;
                self.regs[r] = self.sub16(self.regs[r], 1);
                self.set_flag(CF, carry);
            }
            0x50..=0x57 => { self.push16(self.regs[(op & 7) as usize]); }
            0x58..=0x5F => { self.regs[(op & 7) as usize] = self.pop16(); }
            0x74 => { self.jump_rel8(self.flags & ZF != 0); }
            0x75 => { self.jump_rel8(self.flags & ZF == 0); }
            0x8E => {
                let m = self.modrm_rr(op);
                self.segs[(m >> 3 & 3) as usize] = self.regs[(m & 7) as usize];
            }
            0x90 => {}
            0xA1 => { let off = self.fetch16(); self.regs[AX] = self.rd16(self.segs[DS], off); }
            0xA3 => { let off = self.fetch16(); self.wr16(self.segs[DS], off, self.regs[AX]); }
            0xAC => {
                let v = self.rd8(self.segs[DS], self.regs[SI]);
                self.set8(0, v);
                if self.flags & DF != 0 { self.regs[SI] = self.regs[SI].wrapping_sub(1); }
                else { self.regs[SI] = self.regs[SI].wrapping_add(1); }
            }
            0xB0..=0xB7 => { let v = self.fetch8(); self.set8(op & 7, v); }
            0xB8..=0xBF => { self.regs[(op & 7) as usize] = self.fetch16(); }
            0xCD => {
                let n = self.fetch8();
                if n == 0x10 && self.get8(4) == 0x0E { let c = self.get8(0); self.tty.push(c); }
                else { self.unimpl(op); }
            }
            0xD1 => {
                let m = self.modrm_rr(op); let rm = (m & 7) as usize;
                if m >> 3 & 7 != 4 { self.unimpl(op); }
                let v = self.regs[rm];
                let r = v << 1;
                self.set_flag(CF, v & 0x8000 != 0);
                self.set_flag(OF, (v ^ r) & 0x8000 != 0);
                self.set_szp16(r);
                self.regs[rm] = r;
            }
            0xE2 => {
                self.regs[CX] = self.regs[CX].wrapping_sub(1);
                self.jump_rel8(self.regs[CX] != 0);
            }
            0xE6 => { let _port = self.fetch8(); }
            0xEB => { self.jump_rel8(true); }
            0xF4 => { self.halted = true; }
            0xFC => { self.set_flag(DF, false); }
            _ => { self.unimpl(op); }
        }
    }
}

fn main() {
    let path = match std::env::args().nth(1) {
        Some(p) => p,
        None => { eprintln!("usage: m0_rs image.bin"); return; }
    };
    let img = match std::fs::read(&path) {
        Ok(b) => b,
        Err(_) => { eprintln!("cannot read image"); return; }
    };
    let ram: Box<[u8; RAM_SIZE]> = vec![0u8; RAM_SIZE].into_boxed_slice().try_into().unwrap();
    let mut m = Machine {
        regs: [0; 8], segs: [0; 4], ip: 0x7C00, flags: 2, halted: false, fault: false,
        ram, tty: Vec::new(),
    };
    for (i, b) in img.iter().take(512).enumerate() { m.ram[0x7C00 + i] = *b; }

    let t0 = Instant::now();
    let mut n: i64 = 0;
    while !m.halted && n < 2_000_000_000 { m.step(); n += 1; }
    let ms = t0.elapsed().as_millis();

    std::io::stdout().write_all(&m.tty).unwrap();
    if !m.tty.is_empty() { println!(); }
    eprintln!("steps {}  ms {}  fault {}  ax {} bx {} dx {}", n, ms, m.fault, m.regs[AX], m.regs[3], m.regs[2]);
}
