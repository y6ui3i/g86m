// g86m: Goose で書く x86 エミュレータ。
//
//   g86m [--trace] [--max N] boot.bin
//
// ブートセクタを 0000:7C00 に置いて HLT まで走らせる。--trace は命令境界ごとの
// 状態を標準出力に 1 行ずつ出す (rustx86 側の trace16 と同じ書式で、diff 用)。

import std;
import os;
import state;
import exec;

var trace_buf: u8[>..];
let HEX = "0123456789ABCDEF";

fn hex4(v: u16) {
    trace_buf.push(HEX[v >> 12]);
    trace_buf.push(HEX[v >> 8 & 15]);
    trace_buf.push(HEX[v >> 4 & 15]);
    trace_buf.push(HEX[v & 15]);
}

fn field(name: u8[:], v: u16) {
    trace_buf.append(name);
    hex4(v);
}

fn trace_line() {
    hex4(cpu.segs[CS]);
    trace_buf.push(':');
    hex4(cpu.ip);
    field(" AX=", r16(AX)); field(" CX=", r16(CX)); field(" DX=", r16(DX)); field(" BX=", r16(BX));
    field(" SP=", r16(SP)); field(" BP=", r16(BP)); field(" SI=", r16(SI)); field(" DI=", r16(DI));
    field(" ES=", cpu.segs[ES]); field(" SS=", cpu.segs[SS]); field(" DS=", cpu.segs[DS]);
    field(" F=", cpu.flags);
    trace_buf.push('\n');
    if trace_buf.len > 60000 { write_stdout(trace_buf); trace_buf.clear(); }
}

// 電源投入時の下ごしらえ: IVT の全ベクタを BIOS の入口に向ける。
fn power_on() {
    for n: u16 in 0..256 {
        wr16(0, n * 4, n);
        wr16(0, n * 4 + 2, BIOS_SEG);
    }
}

fn main() {
    let a = args();
    var trace = false;
    var max = 20000000000;
    var path: const u8[:] = "";
    var i = 1;
    while i < a.len {
        if a[i] == "--trace" { trace = true; }
        else if a[i] == "--max" && i + 1 < a.len {
            i++;
            let n, ok = parse_int(a[i]);
            guard ok else { write_stderr("g86m: --max needs a number\n"); exit(2); }
            max = n;
        }
        else { path = a[i]; }
        i++;
    }
    guard path.len > 0 else { write_stderr("usage: g86m [--trace] [--max N] boot.bin\n"); exit(2); }

    var img: u8[>..] = [];
    guard read_file(path, img) else { write_stderr("g86m: cannot read image\n"); exit(2); }
    guard img.len == 512 && img[510] == 0x55 && img[511] == 0xAA else {
        write_stderr("g86m: not a 512-byte boot sector with the 55AA signature\n");
        exit(2);
    }

    power_on();
    for b, k in img { ram[0x7C00 + k] = b; }
    cpu.ip = 0x7C00;
    set_r16(DX, 0x0080);                 // DL = ブートドライブ番号

    let t0 = clock_ns();
    var n = 0;
    if trace {
        trace_line();
        while !cpu.halted && n < max { step(); n++; trace_line(); }
        write_stdout(trace_buf);
    } else {
        while !cpu.halted && n < max { step(); n++; }
        write_stdout(tty);
        if tty.len > 0 { write_stdout("\n"); }
    }
    let ms = (clock_ns() - t0) / 1000000;

    var stats: u8[>..] = [];
    format(stats, "steps ", n, " halted ", cpu.halted, " fault ", cpu.fault, " ms ", ms, " console \"", tty, "\"\n");
    write_stderr(stats);
    if cpu.fault { exit(1); }
}
