// BIOS サービスの代行と I/O ポート。M1 は INT 10h のテレタイプ出力だけ。

import state;

fn bios_call(n: u8) {
    let ah = r8(4);
    if n == 0x10 && ah == 0x0E { tty.push(r8(0)); return; }
    stop("unimplemented BIOS interrupt", n);
}

// デバイスは M2 以降。読みは全ビット 1、書きは捨てる。
fn port_in(port: u16) -> u16 { return 0xFFFF; }
fn port_out(port: u16, v: u16) {}
