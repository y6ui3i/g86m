// g86m: an x86 emulator written in Goose.
//
//   g86m [options] image
//
// A 512-byte image is a boot sector; anything else is a floppy image booted as drive A.
// A floppy image started from a terminal, with no script and no trace, opens the interactive
// console: the guest's text screen is drawn in the terminal and the keyboard goes to the guest.
// Ctrl-] or F12 leaves it.
//
//   --max N        stop after N instructions of virtual time
//   --trace        print the state at every instruction boundary, one line each, in the same
//                  format as rustx86's trace16 so the two can be diffed
//   --wait TEXT    script step: run until TEXT is on the text screen
//   --type TEXT    script step: type TEXT at the keyboard (\n is Enter)
//   --screen       print the text screen when the run ends
//   --ports        report the I/O ports the guest used that nothing answered
//   --headless     never open the interactive console
//
// Script steps run in the order given, and the run ends when the last one is done.

import std;
import os;
import state;
import exec;
import bios;
import dev;
import console;

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

// ---- Text screen ----

// The 80x25 text screen as lines of characters. With trim, trailing blanks are removed (for
// printing); without, every line is 80 columns (for matching text that ends in a space).
fn screen_text(out: u8[>..]&, trim: bool) {
    for row in 25 {
        var width = 80;
        if trim {
            width = 0;
            for col in 80 {
                let c = ram[0xB8000 + (row * 80 + col) * 2];
                if c != 0x20 && c != 0 { width = col + 1; }
            }
        }
        for col in width {
            let c = ram[0xB8000 + (row * 80 + col) * 2];
            out.push(if c >= 0x20 && c < 0x7F { c } else { ' ' });
        }
        out.push('\n');
    }
}

// ---- Script ----

let STEP_WAIT = 1;
let STEP_TYPE = 2;

var step_kind: u8[>..];
var step_arg: i64[>..];          // index of the step's text in args()
var step_pos = 0;
var step_started = false;        // the current type step has queued its keys
var type_index = 0;              // next character of the current type step

// Advances the script as far as it can go right now. True once every step is done.
fn script_poll() -> bool {
    let a = args();
    while step_pos < step_kind.len {
        let text = a[step_arg[step_pos]];
        if step_kind[step_pos] == STEP_WAIT {
            var scr: u8[>..] = [];
            screen_text(scr, false);
            if find(scr, text) < 0 { return false; }
        } else {
            // Feed the keyboard a few characters at a time so its queue never overflows.
            while type_index < text.len && kbd_queued() < 200 {
                var c = text[type_index];
                if c == '\\' && type_index + 1 < text.len && text[type_index + 1] == 'n' {
                    c = '\n';
                    type_index++;
                }
                type_char(c);
                type_index++;
            }
            if type_index < text.len || kbd_queued() > 0 || kbd_full { return false; }
            type_index = 0;
        }
        step_pos++;
    }
    return true;
}

// ---- Run ----

let RUN_BUDGET = 0;      // virtual time reached the limit
let RUN_STOPPED = 1;     // the machine cannot go on: a fault, or halted with nothing to wake it
let RUN_SCRIPT = 2;      // the script finished

var vtime = 0;           // virtual time, in instructions
var trace = false;
var scripted = false;
var next_poll = 0;

// Runs the machine until virtual time reaches limit, or it stops, or the script finishes.
fn run_until(limit: i64) -> i64 {
    while vtime < limit {
        if cpu.halted {
            if cpu.fault || !flag(IF) { return RUN_STOPPED; }
            if !irq_line {
                // Idle: nothing can happen until the timer fires, so jump there, but not past
                // the limit, so that a caller pacing against real time keeps its count.
                guard timer_on else { return RUN_STOPPED; }
                let skip = if timer_left < limit - vtime { timer_left } else { limit - vtime };
                vtime += skip;
                timer_left -= skip;
                if timer_left <= 0 { timer_fire(); }
                continue;
            }
        }
        if irq_line && flag(IF) && !shadow {
            cpu.halted = false;
            interrupt(pic_ack());
        }
        step();
        vtime++;
        if timer_on {
            timer_left -= 1;
            if timer_left <= 0 { timer_fire(); }
        }
        if trace { trace_line(); }
        if scripted && vtime >= next_poll {
            if script_poll() { return RUN_SCRIPT; }
            next_poll = vtime + 20000;
        }
    }
    return RUN_BUDGET;
}

// The virtual CPU runs TICK_INSNS instructions per timer tick, and the timer ticks 1,193,182
// times a second, so this many instructions are one second of guest time.
let INSNS_PER_SECOND = 1193182 * TICK_INSNS;

// The interactive console: run a hundredth of a second of guest time, exchange keys and screen
// with the terminal, then sleep until real time has caught up. Returns how the machine ended.
fn run_console(max: i64) -> i64 {
    let slice = INSNS_PER_SECOND / 100;
    var t0 = clock_ns();
    var v0 = vtime;
    var result = RUN_BUDGET;
    while vtime < max {
        result = run_until(vtime + slice);
        guard console_keys() else { break; }
        console_render();
        guard result == RUN_BUDGET else { break; }
        let guest_ns = (vtime - v0) * 1000000000 / INSNS_PER_SECOND;
        let ahead = guest_ns - (clock_ns() - t0);
        if ahead > 0 {
            let nap = if ahead > 50000000 { 50000000 } else { ahead };
            con_sleep_us((nap / 1000) as! i32);
        } else if ahead < -200000000 {
            // The host could not keep up: stop trying to make up the lost time.
            t0 = clock_ns();
            v0 = vtime;
        }
    }
    return result;
}

fn main() {
    let a = args();
    var show_screen = false;
    var show_ports = false;
    var headless = false;
    var max = 20000000000;
    var path: const u8[:] = "";
    var i = 1;
    while i < a.len {
        if a[i] == "--trace" { trace = true; }
        else if a[i] == "--screen" { show_screen = true; }
        else if a[i] == "--ports" { show_ports = true; }
        else if a[i] == "--headless" { headless = true; }
        else if a[i] == "--max" && i + 1 < a.len {
            i++;
            let n, ok = parse_int(a[i]);
            guard ok else { write_stderr("g86m: --max needs a number\n"); exit(2); }
            max = n;
        }
        else if (a[i] == "--wait" || a[i] == "--type") && i + 1 < a.len {
            step_kind.push(if a[i] == "--wait" { STEP_WAIT } else { STEP_TYPE });
            i++;
            step_arg.push(i);
        }
        else { path = a[i]; }
        i++;
    }
    guard path.len > 0 else { write_stderr("usage: g86m [--trace] [--max N] [--wait TEXT] [--type TEXT] [--screen] [--ports] [--headless] image\n"); exit(2); }

    var img: u8[>..] = [];
    guard read_file(path, img) else { write_stderr("g86m: cannot read image\n"); exit(2); }
    guard img.len >= 512 && img[510] == 0x55 && img[511] == 0xAA else {
        write_stderr("g86m: the image does not start with a boot sector (55AA signature)\n");
        exit(2);
    }

    power_on();
    for k in 512 { ram[0x7C00 + k] = img[k]; }
    cpu.ip = 0x7C00;
    if img.len == 512 {
        set_r16(DX, 0x0080);             // a bare boot sector: DL = 80h, as rustx86 starts it
    } else {
        disk.append(img);
        guard disk_geometry() else { write_stderr("g86m: the image is not a floppy size\n"); exit(2); }
        set_r16(DX, 0x0000);             // DL = drive A
    }

    scripted = step_kind.len > 0;
    var interactive = !trace && !scripted && !headless && img.len != 512 && con_is_tty() != 0;
    if interactive {
        // Said on the ordinary screen first, so it is also there to scroll back to afterwards.
        write_stdout("g86m: Ctrl-] or F12 to quit\r\n");
        flush_stdout();
        if con_rows() <= 25 { con_sleep_us(1200000); }     // no room for the hint line: let it be read
        interactive = con_open() != 0;
    }
    let t0 = clock_ns();
    if trace { trace_line(); }
    let result = if interactive { run_console(max) } else { run_until(max) };
    let ms = (clock_ns() - t0) / 1000000;
    if interactive { con_close(); }
    if trace { write_stdout(trace_buf); }

    if show_screen || scripted || interactive {
        var scr: u8[>..] = [];
        screen_text(scr, true);
        write_stdout(scr);
    } else if !trace {
        write_stdout(tty);
        if tty.len > 0 { write_stdout("\n"); }
    }

    var stats: u8[>..] = [];
    format(stats, "steps ", vtime, " halted ", cpu.halted, " fault ", cpu.fault, " ms ", ms);
    if scripted { format(stats, " script ", step_pos, "/", step_kind.len); }
    if !scripted && !interactive { format(stats, " console \"", tty, "\""); }
    format(stats, "\n");
    write_stderr(stats);
    if show_ports {
        var ports: u8[>..] = [];
        for count, port in unknown_ports {
            if count > 0 {
                format(ports, "port ");
                format_int(ports, port, 16, 4, '0');
                format(ports, " x", count, "\n");
            }
        }
        write_stderr(ports);
    }
    if cpu.fault || (scripted && result != RUN_SCRIPT) { exit(1); }
}
