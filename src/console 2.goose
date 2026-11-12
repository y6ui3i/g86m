// The interactive console: draws the text screen in the host terminal and turns host keystrokes
// into scancodes. The terminal itself (raw mode, reads, sleeping) is in console.c.

import std;
import os;
import state;
import dev;

extern fn con_is_tty() -> i32;
extern fn con_open() -> i32;
extern fn con_close();
extern fn con_read() -> i32;
extern fn con_sleep_us(us: i32);

// ---- Keys ----

let ROW_PLAIN = "1234567890-=\0\0qwertyuiop[]\0\0asdfghjkl;'`\0\\zxcvbnm,./";
let ROW_SHIFT = "!@#$%^&*()_+\0\0QWERTYUIOP{}\0\0ASDFGHJKL:\"~\0|ZXCVBNM<>?";

// One key: its make code, then its break code.
fn key(scan: u8) {
    kbd_push(scan);
    kbd_push(scan | 0x80);
}

// A key from the extended set (arrows, editing keys): each code is prefixed with E0h.
fn key_extended(scan: u8) {
    kbd_push(0xE0);
    kbd_push(scan);
    kbd_push(0xE0);
    kbd_push(scan | 0x80);
}

// Queues the scancodes (set 1) that produce the character c. Unknown characters are ignored.
fn type_char(c: u8) {
    var scan: u8 = 0;
    var shift = false;
    if c == '\n' || c == '\r' { scan = 0x1C; }
    else if c == ' ' { scan = 0x39; }
    else if c == '\t' { scan = 0x0F; }
    else if c == 0x1B { scan = 0x01; }
    else if c == 0x08 || c == 0x7F { scan = 0x0E; }
    else {
        for p, i in ROW_PLAIN { if p == c && p != 0 { scan = (i + 2) as! u8; } }
        for p, i in ROW_SHIFT { if p == c && p != 0 { scan = (i + 2) as! u8; shift = true; } }
    }
    if scan == 0 { return; }
    if shift { kbd_push(0x2A); }
    key(scan);
    if shift { kbd_push(0xAA); }
}

// Ctrl plus a letter, from the control character the terminal sends for it (01h..1Ah).
fn type_ctrl(c: u8) {
    let letter = c + 0x60;
    var scan: u8 = 0;
    for p, i in ROW_PLAIN { if p == letter { scan = (i + 2) as! u8; } }
    if scan == 0 { return; }
    kbd_push(0x1D);
    key(scan);
    kbd_push(0x9D);
}

var key_buf: u8[>..<];

// The key a CSI or SS3 escape sequence stands for: its final byte and numeric parameter.
fn escape_key(last: u8, param: i64) {
    match last {
        'A' => { key_extended(0x48); },
        'B' => { key_extended(0x50); },
        'C' => { key_extended(0x4D); },
        'D' => { key_extended(0x4B); },
        'H' => { key_extended(0x47); },
        'F' => { key_extended(0x4F); },
        'P' => { key(0x3B); },
        'Q' => { key(0x3C); },
        'R' => { key(0x3D); },
        'S' => { key(0x3E); },
        '~' => {
            match param {
                1, 7 => { key_extended(0x47); },
                2 => { key_extended(0x52); },
                3 => { key_extended(0x53); },
                4, 8 => { key_extended(0x4F); },
                5 => { key_extended(0x49); },
                6 => { key_extended(0x51); },
                11..16 => { key((0x3B + param - 11) as! u8); },
                17..22 => { key((0x40 + param - 17) as! u8); },
                _ => {},
            }
        },
        _ => {},
    }
}

// Reads what the host keyboard has sent and queues it for the guest.
// False when the user pressed Ctrl-] to leave.
fn console_keys() -> bool {
    key_buf.clear();
    loop {
        let b = con_read();
        if b < 0 { break; }
        key_buf.push(b as! u8);
    }
    var i = 0;
    while i < key_buf.len {
        let c = key_buf[i];
        i++;
        if c == 0x1D { return false; }
        if c == 0x1B && i < key_buf.len && (key_buf[i] == '[' || key_buf[i] == 'O') {
            i++;
            var param = 0;
            while i < key_buf.len && key_buf[i] >= '0' && key_buf[i] <= ';' {
                if key_buf[i] <= '9' { param = param * 10 + (key_buf[i] - '0'); }
                i++;
            }
            if i < key_buf.len { escape_key(key_buf[i], param); i++; }
        }
        else if c < 0x20 && c != 0x1B && c != '\r' && c != '\n' && c != '\t' && c != 0x08 { type_ctrl(c); }
        else { type_char(c); }
    }
    return true;
}

// ---- Screen ----

// Code page 437, upper half, as Unicode code points.
let CP437: u16[128] = [
    0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, 0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
    0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9, 0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
    0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA, 0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
    0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
    0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
    0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
    0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4, 0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
    0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248, 0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0];

let ESC = 0x1B;

var shown: u8[4000] = [0xFF; 4000];      // what the terminal currently shows; FFh forces a redraw
var shown_cursor = -1;
var out: u8[>..];

fn put_char(c: u8) {
    if c >= 0x20 && c < 0x7F { out.push(c); return; }
    if c < 0x80 { out.push(' '); return; }
    let cp: u32 = CP437[c - 0x80];
    if cp < 0x800 {
        out.push((0xC0 | cp >> 6) as! u8);
        out.push((0x80 | cp & 0x3F) as! u8);
    } else {
        out.push((0xE0 | cp >> 12) as! u8);
        out.push((0x80 | cp >> 6 & 0x3F) as! u8);
        out.push((0x80 | cp & 0x3F) as! u8);
    }
}

fn move_to(pos: i64) {
    out.push(ESC);
    format(out, "[", pos / 80 + 1, ";", pos % 80 + 1, "H");
}

// CGA colour numbers have blue in bit 0 and red in bit 2; ANSI has them the other way round.
fn ansi_colour(c: u8) -> i64 { return (c & 1) << 2 | c & 2 | (c & 4) >> 2; }

fn set_attr(attr: u8) {
    let fg = attr & 0x0F;
    let bg = attr >> 4 & 7;
    out.push(ESC);
    format(out, "[", (if fg & 8 != 0 { 90 } else { 30 }) + ansi_colour(fg), ";", 40 + ansi_colour(bg), "m");
}

// Sends the cells that changed since the last call, then puts the cursor where the guest has it.
fn console_render() {
    var pen = -1;            // where the terminal's cursor is after the last character sent
    var attr = -1;
    for i in 2000 {
        let ch = ram[0xB8000 + i * 2];
        let at = ram[0xB8000 + i * 2 + 1];
        if ch == shown[i * 2] && at == shown[i * 2 + 1] { continue; }
        shown[i * 2] = ch;
        shown[i * 2 + 1] = at;
        if pen != i { move_to(i); }
        if attr != at { set_attr(at); attr = at; }
        put_char(ch);
        pen = if i % 80 == 79 { -1 } else { i + 1 };
    }
    let hi: i64 = crtc[14];
    let lo: i64 = crtc[15];
    var cursor = hi << 8 | lo;
    if cursor >= 2000 { cursor = 1999; }
    if out.len > 0 || cursor != shown_cursor {
        move_to(cursor);
        shown_cursor = cursor;
        write_stdout(out);
        flush_stdout();
        out.clear();
    }
}
