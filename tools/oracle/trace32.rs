//! Oracle for g86m: steps a boot sector one instruction at a time on rustx86's 32-bit profile and
//! prints the full 32-bit state at every instruction boundary, one line each.
use rustx86_core::{Machine, MachineProfile};
use std::io::Write;

fn line(m: &Machine, out: &mut impl Write) {
    let c = &m.cpu;
    let r = &c.regs;
    writeln!(out,
        "{:04X}:{:08X} EAX={:08X} ECX={:08X} EDX={:08X} EBX={:08X} ESP={:08X} EBP={:08X} ESI={:08X} EDI={:08X} ES={:04X} SS={:04X} DS={:04X} FS={:04X} GS={:04X} F={:08X}",
        c.sregs[1], c.ip, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7],
        c.sregs[0], c.sregs[2], c.sregs[3], c.sregs[4], c.sregs[5], c.eflags()).unwrap();
}

fn main() {
    let path = std::env::args().nth(1).expect("image");
    let max: u64 = std::env::args().nth(2).map(|s| s.parse().unwrap()).unwrap_or(1_000_000);
    let sector = std::fs::read(&path).expect("read");
    let mut m = Machine::with_profile(MachineProfile::pc_32bit(16));
    m.load_boot_sector(&sector).expect("load");
    let stdout = std::io::stdout();
    let mut out = std::io::BufWriter::new(stdout.lock());
    line(&m, &mut out);
    let mut n = 0u64;
    while !m.halted && n < max {
        m.step();
        n += 1;
        line(&m, &mut out);
    }
    out.flush().unwrap();
    eprintln!("steps {} halted {} console {:?}", n, m.halted, String::from_utf8_lossy(&m.console));
}
