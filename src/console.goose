// The interactive console: draws the text screen in the host terminal and turns host keystrokes
// into scancodes. The terminal itself (raw mode, reads, sleeping) is in console.c.

import std;
import os;
import state;
import dev;
import bios;

extern fn con_is_tty() -> i32;
extern fn con_open() -> i32;
extern fn con_raw() -> i32;
extern fn con_close();
extern fn con_read() -> i32;
extern fn con_sleep_us(us: i32);
extern fn con_rows() -> i32;
extern fn con_cols() -> i32;

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

// Queues the key a CSI or SS3 escape sequence stands for: its final byte and numeric parameter.
// True when the key is F12, which leaves the console instead of going to the guest.
fn escape_key(last: u8, param: i64) -> bool {
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
                24 => { return true; },
                _ => {},
            }
        },
        _ => {},
    }
    return false;
}

// True when the guest has taken every key given to it so far: from the keyboard controller and,
// for guests that read keys through the BIOS, from the BIOS queue (15 keys; the rest are dropped).
fn guest_took_keys() -> bool {
    return kbd_queued() == 0 && !kbd_full && !bios_key_available();
}

var key_head = 0;            // the next byte of key_buf to hand to the guest

// Reads what the host keyboard has sent and hands it to the guest one key at a time, as fast as
// the guest takes them. A paste therefore arrives whole instead of overflowing the guest's queue.
// False when the user asked to leave: Ctrl-], Ctrl-\ or F12.
fn console_keys() -> bool {
    let fresh = key_buf.len;
    loop {
        let b = con_read();
        if b < 0 { break; }
        key_buf.push(b as! u8);
    }
    // A quit key acts at once, even with other keys still waiting in front of it.
    for i in fresh..key_buf.len {
        let c = key_buf[i];
        if c == 0x1D || c == 0x1C { return false; }
        if c == '~' && i >= 4 && key_buf[i - 1] == '4' && key_buf[i - 2] == '2' && key_buf[i - 3] == '[' && key_buf[i - 4] == 0x1B {
            return false;
        }
    }
    if key_head < key_buf.len && guest_took_keys() {
        let c = key_buf[key_head];
        key_head++;
        if c == 0x1B && key_head < key_buf.len && (key_buf[key_head] == '[' || key_buf[key_head] == 'O') {
            key_head++;
            var param = 0;
            while key_head < key_buf.len && key_buf[key_head] >= '0' && key_buf[key_head] <= ';' {
                if key_buf[key_head] <= '9' { param = param * 10 + (key_buf[key_head] - '0'); }
                key_head++;
            }
            if key_head < key_buf.len {
                if escape_key(key_buf[key_head], param) { return false; }
                key_head++;
            }
        }
        else if c < 0x20 && c != 0x1B && c != '\r' && c != '\n' && c != '\t' && c != 0x08 { type_ctrl(c); }
        else { type_char(c); }
    }
    if key_head >= key_buf.len { key_buf.clear(); key_head = 0; }
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

var shown_cursor = -1;
var out: u8[>..];

// The part of the 80x25 screen that fits in the terminal. When the terminal is smaller than the
// screen, the view follows the guest's cursor.
var view_rows = 25;
var view_cols = 80;
var view_top = 0;
var view_left = 0;
var view_drawn = false;       // false until the first redraw, which has to clear and set up the terminal

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

// Moves the terminal's cursor to the screen cell pos, which must be inside the view.
fn move_to(pos: i64) {
    out.push(ESC);
    format(out, "[", pos / 80 - view_top + 1, ";", pos % 80 - view_left + 1, "H");
}

// CGA colour numbers have blue in bit 0 and red in bit 2; ANSI has them the other way round.
fn ansi_colour(c: u8) -> i64 { return (c & 1) << 2 | c & 2 | (c & 4) >> 2; }

fn set_attr(attr: u8) {
    let fg = attr & 0x0F;
    let bg = attr >> 4 & 7;
    out.push(ESC);
    format(out, "[", (if fg & 8 != 0 { 90 } else { 30 }) + ansi_colour(fg), ";", 40 + ansi_colour(bg), "m");
}

// Where a view of size cells should start so that it contains at, without leaving 0..limit.
fn view_start(start: i64, size: i64, at: i64, limit: i64) -> i64 {
    var s = start;
    if at < s { s = at; }
    if at >= s + size { s = at - size + 1; }
    if s + size > limit { s = limit - size; }
    if s < 0 { s = 0; }
    return s;
}

// Sends the cells that changed since the last call, then puts the cursor where the guest has it.
fn console_render() {
    let hi: i64 = crtc[14];
    let lo: i64 = crtc[15];
    var cursor = hi << 8 | lo;
    if cursor >= 2000 { cursor = 1999; }

    // Fit the view to the terminal as it is now, and keep the guest's cursor inside it.
    let term_rows: i64 = con_rows();
    let term_cols: i64 = con_cols();
    let rows = if term_rows < 25 { term_rows } else { 25 };
    let cols = if term_cols < 80 { term_cols } else { 80 };
    let top = view_start(view_top, rows, cursor / 80, 25);
    // Sideways the view goes back to column 0 as soon as the cursor fits, so that a prompt at the
    // start of a line is not left hidden after a long line pushed the view right.
    let left = view_start(0, cols, cursor % 80, 80);
    if !view_drawn || rows != view_rows || cols != view_cols || top != view_top || left != view_left {
        view_drawn = true;
        view_rows = rows;
        view_cols = cols;
        view_top = top;
        view_left = left;
        for i in 4000 { shown[i] = 0xFF; }
        shown_cursor = -1;
        out.push(ESC);
        format(out, "[0m");
        out.push(ESC);
        format(out, "[2J");
        // With a row to spare below the screen, say how to leave. (The window title says it too.)
        if term_rows > 25 {
            out.push(ESC);
            format(out, "[26;1H");
            out.push(ESC);
            format(out, "[2mg86m: Ctrl-] or F12 to quit");
            out.push(ESC);
            format(out, "[0m");
        }
    }

    var pen = -1;            // the screen cell the terminal's cursor is on after the last character
    var attr = -1;
    for row in view_top..view_top + view_rows {
        for col in view_left..view_left + view_cols {
            let i = row * 80 + col;
            let ch = ram[0xB8000 + i * 2];
            let at = ram[0xB8000 + i * 2 + 1];
            if ch == shown[i * 2] && at == shown[i * 2 + 1] { continue; }
            shown[i * 2] = ch;
            shown[i * 2 + 1] = at;
            if pen != i { move_to(i); }
            if attr != at { set_attr(at); attr = at; }
            put_char(ch);
            // After the last column of the view the terminal's cursor position is not dependable.
            pen = if col == view_left + view_cols - 1 { -1 } else { i + 1 };
        }
    }
    if out.len > 0 || cursor != shown_cursor {
        move_to(cursor);
        shown_cursor = cursor;
        write_stdout(out);
        flush_stdout();
        out.clear();
    }
}
