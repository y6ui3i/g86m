// BIOS services handled by the emulator, and I/O ports. M1 has INT 10h teletype output only.

import state;

fn bios_call(n: u8) {
    let ah = r8(4);
    if n == 0x10 && ah == 0x0E { tty.push(r8(0)); return; }
    stop("unimplemented BIOS interrupt", n);
}

// Devices arrive in M2. Until then a read returns all ones and a write is dropped.
fn port_in(port: u16) -> u16 { return 0xFFFF; }
fn port_out(port: u16, v: u16) {}
