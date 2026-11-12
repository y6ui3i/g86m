//! g86m の正解器: ブートセクタを 1 命令ずつ進め、命令境界ごとの状態を 1 行で吐く。
use rustx86_core::Machine;
use std::io::Write;

fn line(m: &Machine, out: &mut impl Write) {
    let c = &m.cpu;
    let r = &c.regs;
    writeln!(out,
        "{:04X}:{:04X} AX={:04X} CX={:04X} DX={:04X} BX={:04X} SP={:04X} BP={:04X} SI={:04X} DI={:04X} ES={:04X} SS={:04X} DS={:04X} F={:04X}",
        c.sregs[1], c.ip & 0xFFFF, r[0] & 0xFFFF, r[1] & 0xFFFF, r[2] & 0xFFFF, r[3] & 0xFFFF,
        r[4] & 0xFFFF, r[5] & 0xFFFF, r[6] & 0xFFFF, r[7] & 0xFFFF,
        c.sregs[0], c.sregs[2], c.sregs[3], c.eflags() & 0xFFFF).unwrap();
}

fn main() {
    let path = std::env::args().nth(1).expect("image");
    let max: u64 = std::env::args().nth(2).map(|s| s.parse().unwrap()).unwrap_or(1_000_000);
    let sector = std::fs::read(&path).expect("read");
    let mut m = Machine::new();
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
