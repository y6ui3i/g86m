// g86m: an x86 emulator written in Goose.
//
//   g86m [options] image
//
// A Linux kernel image (a bzImage) is loaded and entered directly, with --initrd and --append
// giving its initramfs and command line; its console is the serial port. Started from a terminal,
// the terminal is that serial port (Ctrl-] leaves); otherwise what the kernel prints goes to
// standard output. A 512-byte image is a boot sector. A 64 KB or 128 KB image is a ROM that replaces the BIOS: it
// is placed at the top of the first megabyte and started at the reset vector, F000:FFF0. Anything
// else is a floppy image booted as drive A.
// A floppy image started from a terminal, with no script and no trace, opens the interactive
// console: the guest's text screen is drawn in the terminal and the keyboard goes to the guest.
// Ctrl-] or F12 leaves it.
//
//   --max N        stop after N instructions of virtual time
//   --trace        print the state at every instruction boundary, one line each, in the same
//                  format as rustx86's trace32 so the two can be diffed
//   --trace-after N  like --trace, but starting once N instructions have run
//   --wait TEXT    script step: run until TEXT is on the text screen
//   --type TEXT    script step: type TEXT at the keyboard (\n is Enter; \kNN presses the key
//                  with scancode NN in hex, so \k3F is F5)
//   --screen       print the text screen when the run ends
//   --ports        report the I/O ports the guest used that nothing answered, and how often
//                  each BIOS service was called
//   --headless     never open the interactive console
//   --cpu KIND     386 or i686: the CPU, instead of the one that goes with the image
//   --no-decode-cache  decode every instruction every time (for finding a fault in the cache)
//   --faults       report every fault except page faults on standard error
//   --dump FILE    write the first 1 MB of guest memory to FILE when the run ends
//   --com FILE     write what the guest sent to COM1 to FILE when the run ends
//   --initrd FILE  the initramfs for a Linux kernel
//   --append TEXT  the Linux kernel command line (default: console=ttyS0)
//
// Script steps run in the order given, and the run ends when the last one is done.

import std;
import os;
import state;
import exec;
import bios;
import dev;
import console;
import linux;
import big;         // last on purpose: see big.goose

var trace_buf: u8[>..];
let HEX = "0123456789ABCDEF";

fn hex4(v: u16) {
    trace_buf.push(HEX[v >> 12]);
    trace_buf.push(HEX[v >> 8 & 15]);
    trace_buf.push(HEX[v >> 4 & 15]);
    trace_buf.push(HEX[v & 15]);
}

fn hex8(v: u32) {
    hex4((v >> 16) as! u16);
    hex4(v as! u16);
}

fn field(name: u8[:], v: u32) {
    trace_buf.append(name);
    hex8(v);
}

fn seg_field(name: u8[:], s: i64) {
    trace_buf.append(name);
    hex4(cpu.segs[s]);
}

fn trace_line() {
    hex4(cpu.segs[CS]);
    trace_buf.push(':');
    hex8(cpu.ip);
    field(" EAX=", r32(AX)); field(" ECX=", r32(CX)); field(" EDX=", r32(DX)); field(" EBX=", r32(BX));
    field(" ESP=", r32(SP)); field(" EBP=", r32(BP)); field(" ESI=", r32(SI)); field(" EDI=", r32(DI));
    seg_field(" ES=", ES); seg_field(" SS=", SS); seg_field(" DS=", DS); seg_field(" FS=", FS); seg_field(" GS=", GS);
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
var serial = false;              // the guest's console is its serial port: the script waits on and types to that
var serial_seen = 0;             // how much of the serial output earlier wait steps have consumed

// Advances the script as far as it can go right now. True once every step is done.
fn script_poll() -> bool {
    let a = args();
    while step_pos < step_kind.len {
        let text = a[step_arg[step_pos]];
        if serial {
            if step_kind[step_pos] == STEP_WAIT {
                // Each wait looks only at what came after the last one matched, so that waiting
                // for the prompt a second time waits for a second prompt.
                let at = find(com_out[serial_seen..], text);
                if at < 0 { return false; }
                serial_seen += at + text.len;
            } else {
                // One byte per poll, once the guest has read the last one.
                if type_index < text.len && !com_has_input() {
                    var c = text[type_index];
                    if c == '\\' && type_index + 1 < text.len && text[type_index + 1] == 'n' {
                        c = '\r';               // Enter, as a terminal sends it
                        type_index++;
                    }
                    com_receive(c);
                    type_index++;
                }
                if type_index < text.len || com_has_input() { return false; }
                type_index = 0;
            }
        } else if step_kind[step_pos] == STEP_WAIT {
            var scr: u8[>..] = [];
            screen_text(scr, false);
            if find(scr, text) < 0 { return false; }
        } else {
            // One character per poll, and only once the guest has taken the last one: both from
            // the keyboard controller and, for guests that read keys through the BIOS, from the
            // BIOS queue, which holds 15 keys and drops the rest.
            let taken = kbd_queued() == 0 && !kbd_full && !bios_key_available();
            if type_index < text.len && taken {
                var c = text[type_index];
                if c == '\\' && type_index + 1 < text.len && text[type_index + 1] == 'n' {
                    c = '\n';
                    type_index++;
                }
                if c == '\\' && type_index + 3 < text.len && text[type_index + 1] == 'k' {
                    let scan, ok = parse_int(text[type_index + 2..type_index + 4], 16);
                    if ok { key(scan as! u8); }
                    type_index += 4;
                } else {
                    type_char(c);
                    type_index++;
                }
            }
            if type_index < text.len || kbd_queued() > 0 || kbd_full || bios_key_available() { return false; }
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
var trace_after = -1;     // start tracing at this virtual time; -1 for never
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
                vtime = if timer_at < limit { timer_at } else { limit };
                if vtime >= timer_at { timer_fire(); }
                continue;
            }
        }
        // The next moment at which something other than an instruction has to happen: the limit,
        // the timer reaching zero, a look at the script; with a trace, after every instruction.
        var stop_at = limit;
        if timer_on && timer_at < stop_at { stop_at = timer_at; }
        if scripted && next_poll < stop_at { stop_at = next_poll; }
        if trace || trace_after >= 0 { stop_at = vtime + 1; }
        replan = false;
        chain_until = stop_at;
        loop {
            step();
            vtime++;
            if vtime >= stop_at || cpu.halted || replan { break; }
        }
        if timer_on && vtime >= timer_at { timer_fire(); }
        if trace { trace_line(); }
        else if trace_after >= 0 && vtime >= trace_after { trace = true; }
        if scripted && vtime >= next_poll {
            if script_poll() { return RUN_SCRIPT; }
            next_poll = vtime + 20000;
        }
    }
    return RUN_BUDGET;
}

// The virtual CPU runs tick_insns instructions per timer tick, and the timer ticks 1,193,182
// times a second, so this many instructions are one second of guest time.
fn insns_per_second() -> i64 { return 1193182 * tick_insns; }

// The interactive console: run a hundredth of a second of guest time, exchange keys and screen
// with the terminal, then sleep until real time has caught up. Returns how the machine ended.
fn run_console(max: i64) -> i64 {
    let slice = insns_per_second() / 100;
    var t0 = clock_ns();
    var v0 = vtime;
    var result = RUN_BUDGET;
    while vtime < max {
        result = run_until(vtime + slice);
        guard console_keys() else { break; }
        console_render();
        guard result == RUN_BUDGET else { break; }
        let guest_ns = (vtime - v0) * 1000000000 / insns_per_second();
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

// The serial console: the guest's serial port is the terminal. As run_console, but there is no
// screen to draw: what the guest sends is written as it comes, and what is typed goes to the
// port. Ctrl-] leaves.
fn run_serial(max: i64) -> i64 {
    let slice = insns_per_second() / 100;
    var t0 = clock_ns();
    var v0 = vtime;
    var result = RUN_BUDGET;
    while vtime < max {
        result = run_until(vtime + slice);
        var quit = false;
        loop {
            let b = con_read();
            if b < 0 { break; }
            if b == 0x1D { quit = true; break; }
            com_receive(b as! u8);
        }
        com_flush();
        guard !quit && result == RUN_BUDGET else { break; }
        let guest_ns = (vtime - v0) * 1000000000 / insns_per_second();
        let ahead = guest_ns - (clock_ns() - t0);
        if ahead > 0 {
            let nap = if ahead > 50000000 { 50000000 } else { ahead };
            con_sleep_us((nap / 1000) as! i32);
        } else if ahead < -200000000 {
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
    var dump_arg = 0;
    var com_arg = 0;
    var cpu_arg = 0;
    var initrd_arg = 0;
    var append_arg = 0;
    var max = 20000000000;
    var path: const u8[:] = "";
    var i = 1;
    while i < a.len {
        if a[i] == "--trace" { trace = true; }
        else if a[i] == "--trace-after" && i + 1 < a.len {
            i++;
            let n, ok = parse_int(a[i]);
            guard ok else { write_stderr("g86m: --trace-after needs a number\n"); exit(2); }
            trace_after = n;
        }
        else if a[i] == "--screen" { show_screen = true; }
        else if a[i] == "--ports" { show_ports = true; }
        else if a[i] == "--headless" { headless = true; }
        else if a[i] == "--cpu" && i + 1 < a.len { i++; cpu_arg = i; }
        else if a[i] == "--faults" { log_faults = true; }
        else if a[i] == "--no-decode-cache" { dc_on = false; }
        else if a[i] == "--dump" && i + 1 < a.len { i++; dump_arg = i; }
        else if a[i] == "--com" && i + 1 < a.len { i++; com_arg = i; }
        else if a[i] == "--initrd" && i + 1 < a.len { i++; initrd_arg = i; }
        else if a[i] == "--append" && i + 1 < a.len { i++; append_arg = i; }
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
    let rom = img.len == 65536 || img.len == 131072;
    let kernel = is_bzimage(img);
    if kernel {
        var initrd: u8[>..] = [];
        if initrd_arg > 0 {
            guard read_file(a[initrd_arg], initrd) else { write_stderr("g86m: cannot read the initramfs\n"); exit(2); }
        }
        let cmdline: const u8[:] = if append_arg > 0 { a[append_arg] } else { "console=ttyS0" };
        let problem = linux_boot(img, initrd, cmdline);
        guard problem.len == 0 else { write_stderr(str("g86m: ", problem, "\n")); exit(2); }
        // No BIOS runs first: the interrupt controller is masked and the timer stopped.
        bios_on = false;
        pic[0].imr = 0xFF;
        timer_on = false;
        com_live = true;
        i686 = true;
        tick_insns = 64;
        serial = true;
    } else if rom {
        // The ROM ends at the top of the first megabyte. A CPU starts at the reset vector.
        for b, k in img { ram[0x100000 - img.len + k] = b; }
        bios_on = false;
        // No BIOS has set up the interrupt controller or the timer: nothing interrupts the ROM.
        pic[0].imr = 0xFF;
        timer_on = false;
        set_seg(CS, 0xF000);
        cpu.ip = 0xFFF0;
    } else {
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
    }

    if cpu_arg > 0 {
        guard a[cpu_arg] == "386" || a[cpu_arg] == "i686" else { write_stderr("g86m: --cpu takes 386 or i686\n"); exit(2); }
        i686 = a[cpu_arg] == "i686";
    }
    if i686 { cr[0] |= 0x10; }               // ET: the i686 has an FPU

    scripted = step_kind.len > 0;
    var interactive = !trace && !scripted && !headless && img.len != 512 && !rom && !kernel && con_is_tty() != 0;
    if interactive {
        // Said on the ordinary screen first, so it is also there to scroll back to afterwards.
        write_stdout("g86m: Ctrl-] or F12 to quit\r\n");
        flush_stdout();
        if con_rows() <= 25 { con_sleep_us(1200000); }     // no room for the hint line: let it be read
        interactive = con_open() != 0;
    }
    // A kernel started from a terminal gets that terminal as its serial console.
    var serial_console = kernel && !trace && !scripted && !headless && con_is_tty() != 0;
    if serial_console {
        write_stdout("g86m: Ctrl-] to quit\r\n");
        flush_stdout();
        serial_console = con_raw() != 0;
    }
    let t0 = clock_ns();
    if trace { trace_line(); }
    let result = if interactive { run_console(max) } else if serial_console { run_serial(max) } else { run_until(max) };
    com_flush();
    let ms = (clock_ns() - t0) / 1000000;
    if serial_console { con_close(); write_stdout("\n"); }
    if interactive {
        con_close();
        // The reason was written while the console's screen was up, where it cannot be seen.
        if stop_message.len > 0 { write_stderr(stop_message); }
    }
    if trace { write_stdout(trace_buf); }

    if show_screen || (scripted && !serial) || interactive {
        var scr: u8[>..] = [];
        screen_text(scr, true);
        write_stdout(scr);
    } else if !trace {
        write_stdout(tty);
        if tty.len > 0 { write_stdout("\n"); }
    }

    var stats: u8[>..] = [];
    format(stats, "steps ", vtime, " halted ", cpu.halted, " fault ", cpu.fault, " ms ", ms, " at ");
    format_int(stats, cpu.segs[CS], 16, 4, '0');
    format(stats, ":");
    format_int(stats, cpu.ip, 16, 4, '0');
    if scripted { format(stats, " script ", step_pos, "/", step_kind.len); }
    if !scripted && !interactive && !rom && !kernel { format(stats, " console \"", tty, "\""); }
    if rom {
        format(stats, " post");
        for code in post_trail { format(stats, " "); format_int(stats, code, 16, 2, '0'); }
        format(stats, " com ", com_out.len, " bytes");
    }
    format(stats, "\n");
    write_stderr(stats);
    if com_arg > 0 {
        if !write_file(a[com_arg], com_out) { write_stderr("g86m: cannot write the serial output\n"); }
    }
    if dump_arg > 0 {
        if !write_file(a[dump_arg], ram[..0x100000]) { write_stderr("g86m: cannot write the memory dump\n"); }
    }
    if show_ports {
        var ports: u8[>..] = [];
        for count, port in unknown_ports {
            if count > 0 {
                format(ports, "port ");
                format_int(ports, port, 16, 4, '0');
                format(ports, " x", count, "\n");
            }
        }
        for count, slot in bios_calls {
            if count > 0 && slot >> 8 >= 0x10 {
                format(ports, "int ");
                format_int(ports, slot >> 8, 16, 2, '0');
                format(ports, " ah=");
                format_int(ports, slot & 0xFF, 16, 2, '0');
                format(ports, " x", count, "\n");
            }
        }
        write_stderr(ports);
    }
    if cpu.fault || (scripted && result != RUN_SCRIPT) { exit(1); }
}
