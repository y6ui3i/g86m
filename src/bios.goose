// BIOS: power-on setup and the services the emulator performs in place of ROM code.
// Execution reaches bios_call when it arrives at BIOS_SEG:n (see state.goose).

import std;
import state;
import dev;

// The boot disk: a floppy image, drive 0.
var disk: u8[>..];
var disk_cyls: u16 = 80;
var disk_heads: u16 = 2;
var disk_spt: u16 = 18;

let BDA_KB_HEAD = 0x41A;
let BDA_KB_TAIL = 0x41C;
let KB_BUF_START = 0x1E;
let KB_BUF_END = 0x3E;
let VRAM = 0xB8000;

// Works out the floppy geometry from the image size. False for a size that is not a floppy.
fn disk_geometry() -> bool {
    match disk.len {
        368640 => { disk_cyls = 40; disk_heads = 2; disk_spt = 9; },
        737280 => { disk_cyls = 80; disk_heads = 2; disk_spt = 9; },
        1228800 => { disk_cyls = 80; disk_heads = 2; disk_spt = 15; },
        1474560 => { disk_cyls = 80; disk_heads = 2; disk_spt = 18; },
        2949120 => { disk_cyls = 80; disk_heads = 2; disk_spt = 36; },
        _ => { return false; },
    }
    return true;
}

fn power_on() {
    for n: u16 in 0..256 {
        wr16(0, n * 4, n);
        wr16(0, n * 4 + 2, BIOS_SEG);
    }
    // BIOS data area (segment 40h).
    wr16(0, 0x400, 0x3F8);               // COM1
    wr16(0, 0x408, 0x378);               // LPT1
    wr16(0, 0x410, 0x0221);              // equipment: one floppy, 80x25 colour, one serial port
    wr16(0, 0x413, 640);                 // conventional memory in KB
    wr8(0, 0x449, 0x03);                 // video mode 3
    wr16(0, 0x44A, 80);                  // columns
    wr16(0, 0x44C, 0x1000);              // bytes per page
    wr16(0, 0x460, 0x0607);              // cursor shape
    wr16(0, 0x463, 0x3D4);               // CRT controller port
    wr16(0, BDA_KB_HEAD, KB_BUF_START);
    wr16(0, BDA_KB_TAIL, KB_BUF_START);
    wr16(0, 0x480, KB_BUF_START);
    wr16(0, 0x482, KB_BUF_END);
    wr8(0, 0x484, 24);                   // rows - 1
    // ROM identification at the top of the BIOS segment.
    let date = "08/08/26";
    for c, i in date { ram[0xFFFF5 + i] = c; }
    ram[0xFFFFE] = 0xFE;                 // model: PC/XT
    // An empty text screen: spaces in light grey on black.
    for i in 2000 { ram[VRAM + i * 2] = 0x20; ram[VRAM + i * 2 + 1] = 0x07; }
}

// ---- Returning status to the caller ----

// The interrupt pushed FLAGS, CS, IP. The service's carry flag has to land in that pushed FLAGS
// word, because IRET restores it.
fn ret_carry(on: bool) {
    let sp = r16(SP);
    let f = rd16(cpu.segs[SS], sp + 4);
    wr16(cpu.segs[SS], sp + 4, if on { f | 1 } else { f & 0xFFFE });
}

fn ret_zero(on: bool) {
    let sp = r16(SP);
    let f = rd16(cpu.segs[SS], sp + 4);
    wr16(cpu.segs[SS], sp + 4, if on { f | 0x40 } else { f & 0xFFBF });
}

// ---- Text screen ----

fn cursor_col() -> u8 { return ram[0x450]; }
fn cursor_row() -> u8 { return ram[0x451]; }

fn set_cursor(row: u8, col: u8) {
    ram[0x450] = col;
    ram[0x451] = row;
    let pos: u16 = (row as u16) * 80 + col;
    crtc[14] = (pos >> 8) as! u8;
    crtc[15] = pos as! u8;
}

// Scrolls the window (r0,c0)-(r1,c1) by n lines; n == 0 clears it. down selects the direction.
fn scroll(n0: u8, attr: u8, r0: u8, c0: u8, r1: u8, c1: u8, down: bool) {
    if r1 > 24 || c1 > 79 || r0 > r1 || c0 > c1 { return; }
    let rows: i64 = r1 - r0 + 1;
    let n: i64 = if n0 == 0 || n0 > rows { rows } else { n0 };
    for k in rows {
        let dst: i64 = if down { r1 - k } else { r0 + k };
        let src: i64 = if down { dst - n } else { dst + n };
        let blank = src < r0 || src > r1;
        for c: i64 in c0..c1 + 1 {
            let d = VRAM + (dst * 80 + c) * 2;
            if blank { ram[d] = 0x20; ram[d + 1] = attr; }
            else { let s = VRAM + (src * 80 + c) * 2; ram[d] = ram[s]; ram[d + 1] = ram[s + 1]; }
        }
    }
}

fn teletype(ch: u8) {
    tty.push(ch);
    var row = cursor_row();
    var col = cursor_col();
    match ch {
        0x07 => {},
        0x08 => { if col > 0 { col -= 1; } },
        0x0A => { row += 1; },
        0x0D => { col = 0; },
        _ => {
            ram[VRAM + ((row as i64) * 80 + col) * 2] = ch;
            col += 1;
            if col >= 80 { col = 0; row += 1; }
        },
    }
    if row > 24 { scroll(1, 0x07, 0, 0, 24, 79, false); row = 24; }
    set_cursor(row, col);
}

fn int10() {
    let ah = r8(4);
    match ah {
        0x00 => {
            for i in 2000 { ram[VRAM + i * 2] = 0x20; ram[VRAM + i * 2 + 1] = 0x07; }
            set_cursor(0, 0);
        },
        0x01 => {},
        0x02 => { set_cursor(r8(6), r8(2)); },
        0x03 => { set_r8(6, cursor_row()); set_r8(2, cursor_col()); set_r16(CX, 0x0607); },
        0x05 => {},
        0x06 => { scroll(r8(0), r8(7), r8(5), r8(1), r8(6), r8(2), false); },
        0x07 => { scroll(r8(0), r8(7), r8(5), r8(1), r8(6), r8(2), true); },
        0x08 => {
            let p = VRAM + ((cursor_row() as i64) * 80 + cursor_col()) * 2;
            set_r8(0, ram[p]);
            set_r8(4, ram[p + 1]);
        },
        0x09, 0x0A => {
            var p = VRAM + ((cursor_row() as i64) * 80 + cursor_col()) * 2;
            for i in r16(CX) {
                if p >= VRAM + 4000 { break; }
                ram[p] = r8(0);
                if ah == 0x09 { ram[p + 1] = r8(3); }
                p += 2;
            }
        },
        0x0E => { teletype(r8(0)); },
        0x0F => { set_r16(AX, 0x5003); set_r8(7, 0); },        // 80 columns, mode 3, page 0
        0x10, 0x11 => {},                                      // palette, fonts
        0x12 => { if r8(3) == 0x10 { set_r16(BX, 0x0003); set_r16(CX, 0x0009); } },
        0x1A => { if r8(0) == 0 { set_r8(0, 0x1A); set_r16(BX, 0x0008); } },
        _ => { stop("unimplemented INT 10h AH", ah); },
    }
}

// ---- Disk ----

fn int13() {
    let ah = r8(4);
    let drive = r8(2);
    if drive != 0 {                          // only drive A exists
        set_r8(4, 0x01);
        ret_carry(true);
        return;
    }
    match ah {
        0x00 => { set_r8(4, 0); ret_carry(false); },
        0x01 => { set_r8(4, 0); ret_carry(false); },
        0x02, 0x03, 0x04 => {
            let count: i64 = r8(0);
            let cl = r8(1);
            let ch: i64 = r8(5);
            let cyl = ch | ((cl & 0xC0) as i64) << 2;
            let sector: i64 = cl & 0x3F;
            let head: i64 = r8(6);
            if sector == 0 || sector > disk_spt || head >= disk_heads || cyl >= disk_cyls {
                set_r16(AX, 0x0400);         // sector not found, nothing transferred
                ret_carry(true);
                return;
            }
            let lba = (cyl * disk_heads + head) * disk_spt + sector - 1;
            var done = 0;
            for s in count {
                let base = (lba + s) * 512;
                if base + 512 > disk.len { break; }
                if ah != 0x04 {
                    for i: u16 in 0..512 {
                        let off: u16 = r16(BX) + (s as! u16) * 512 + i;
                        if ah == 0x02 { wr8(cpu.segs[ES], off, disk[base + i]); }
                        else { disk[base + i] = rd8(cpu.segs[ES], off); }
                    }
                }
                done += 1;
            }
            set_r8(0, done as! u8);
            if done == count { set_r8(4, 0); ret_carry(false); }
            else { set_r8(4, 0x04); ret_carry(true); }
        },
        0x08 => {
            set_r16(AX, 0);
            set_r8(3, if disk_spt == 36 { 5 } else { 4 });       // drive type
            set_r8(5, (disk_cyls - 1) as! u8);
            set_r8(1, disk_spt as! u8);
            set_r8(6, (disk_heads - 1) as! u8);
            set_r8(2, 1);                                        // one drive
            cpu.segs[ES] = BIOS_SEG;
            set_r16(DI, 0x1E);
            ret_carry(false);
        },
        0x15 => { set_r8(4, 1); ret_carry(false); },             // floppy without change line
        0x16 => { set_r8(4, 0); ret_carry(false); },             // disk not changed
        _ => { set_r8(4, 0x01); ret_carry(true); },
    }
}

// ---- Keyboard (BIOS queue in the data area) ----

let ASCII_OF_SCAN = "\0\x1b1234567890-=\x08\tqwertyuiop[]\r\0asdfghjkl;'`\0\\zxcvbnm,./\0*\0 ";

fn bios_key_available() -> bool { return rd16(0, BDA_KB_HEAD) != rd16(0, BDA_KB_TAIL); }

fn bios_key_put(scan: u8, ascii: u8) {
    let tail = rd16(0, BDA_KB_TAIL);
    var next = tail + 2;
    if next >= KB_BUF_END { next = KB_BUF_START; }
    if next == rd16(0, BDA_KB_HEAD) { return; }
    wr8(0x40, tail, ascii);
    wr8(0x40, tail + 1, scan);
    wr16(0, BDA_KB_TAIL, next);
}

fn int16() {
    let ah = r8(4);
    match ah {
        0x00, 0x10 => {
            if !bios_key_available() {
                // Nothing typed yet: run the INT again once something else has happened.
                cpu.ip = rd16(cpu.segs[SS], r16(SP)) - 2;
                wr16(cpu.segs[SS], r16(SP), cpu.ip);
                return;
            }
            let head = rd16(0, BDA_KB_HEAD);
            set_r16(AX, rd16(0x40, head));
            var next = head + 2;
            if next >= KB_BUF_END { next = KB_BUF_START; }
            wr16(0, BDA_KB_HEAD, next);
        },
        0x01, 0x11 => {
            if bios_key_available() { set_r16(AX, rd16(0x40, rd16(0, BDA_KB_HEAD))); ret_zero(false); }
            else { ret_zero(true); }
        },
        0x02, 0x12 => { set_r8(0, 0); },
        _ => {},
    }
}

// ---- Entry ----

fn bios_call(n: u8) {
    match n {
        0x08 => {                                  // IRQ 0: count the tick, then end the interrupt
            let lo = rd16(0, 0x46C) + 1;
            wr16(0, 0x46C, lo);
            if lo == 0 { wr16(0, 0x46E, rd16(0, 0x46E) + 1); }
            pic_command(0, 0x20);
        },
        0x09 => {                                  // IRQ 1: move the scancode into the BIOS queue
            let scan = kbd_read_data();
            if scan < 0x80 && scan < ASCII_OF_SCAN.len { bios_key_put(scan, ASCII_OF_SCAN[scan]); }
            pic_command(0, 0x20);
        },
        0x0A..0x10 => { pic_command(0, 0x20); },   // other hardware interrupts: just acknowledge
        0x10 => { int10(); },
        0x11 => { set_r16(AX, rd16(0, 0x410)); },
        0x12 => { set_r16(AX, rd16(0, 0x413)); },
        0x13 => { int13(); },
        0x14 => { set_r8(4, 0x80); },              // serial: timeout
        0x15 => {
            if r8(4) == 0x88 { set_r16(AX, 0); ret_carry(false); }
            else { set_r8(4, 0x86); ret_carry(true); }
        },
        0x16 => { int16(); },
        0x17 => { set_r8(4, 0x01); },              // printer: timeout
        0x1A => {
            let ah = r8(4);
            if ah == 0x00 { set_r16(DX, rd16(0, 0x46C)); set_r16(CX, rd16(0, 0x46E)); set_r8(0, 0); }
            else if ah == 0x02 { set_r16(CX, 0x1200); set_r16(DX, 0x0000); ret_carry(false); }     // 12:00:00
            else if ah == 0x04 { set_r16(CX, 0x2026); set_r16(DX, 0x1112); ret_carry(false); }     // 2026-11-12
            else { ret_carry(true); }
        },
        0x1C => {},                                // timer tick hook
        0x70..0x78 => { pic_command(1, 0x20); pic_command(0, 0x20); },
        _ => { stop("unimplemented BIOS interrupt", n); },
    }
}
