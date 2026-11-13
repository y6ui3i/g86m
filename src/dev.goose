// Devices: the interrupt controllers (8259), the timer (8254), the keyboard controller (8042),
// the CRT controller's cursor registers, and the I/O port dispatch that reaches them.

import state;

// ---- Interrupt controllers (8259 pair) ----

struct Pic {
    base: u8,        // vector of this controller's IRQ 0
    imr: u8,         // masked lines
    irr: u8,         // requested
    isr: u8,         // in service
    init: u8,        // which ICW comes next: 0 none, 2..4
    read_isr: bool,  // OCW3 selected ISR for the next read of the command port
}

var pic: Pic[2] = [Pic { base: 0x08, imr: 0xF8, irr: 0, isr: 0, init: 0, read_isr: false },
                   Pic { base: 0x70, imr: 0xFF, irr: 0, isr: 0, init: 0, read_isr: false }];

// True while some unmasked request could be delivered. Recomputed whenever a controller changes,
// so the run loop tests one bool per instruction.
var irq_line = false;

// The lowest-numbered request that is unmasked and not blocked by one in service; -1 if none.
fn pic_candidate(k: i64) -> i64 {
    let ready = pic[k].irr & ~pic[k].imr;
    for n: u8 in 0..8 {
        let bit: u8 = 1 << n;
        if pic[k].isr & bit != 0 { return -1; }
        if ready & bit != 0 { return n; }
    }
    return -1;
}

fn pic_update() {
    // The slave hangs off the master's line 2.
    if pic_candidate(1) >= 0 { pic[0].irr |= 4; } else { pic[0].irr &= ~4; }
    irq_line = pic_candidate(0) >= 0;
}

fn raise_irq(n: u8) {
    if n < 8 { pic[0].irr |= 1 << n; } else { pic[1].irr |= 1 << (n - 8); }
    pic_update();
}

// Acknowledges the pending request and returns its vector.
fn pic_ack() -> u8 {
    let n = pic_candidate(0);
    if n < 0 { return pic[0].base + 7; }
    let bit: u8 = 1 << n;
    if n == 2 {
        let m = pic_candidate(1);
        if m >= 0 {
            let mbit: u8 = 1 << m;
            pic[1].irr &= ~mbit;
            pic[1].isr |= mbit;
            pic[0].isr |= bit;
            pic_update();
            return pic[1].base + (m as! u8);
        }
    }
    pic[0].irr &= ~bit;
    pic[0].isr |= bit;
    pic_update();
    return pic[0].base + (n as! u8);
}

fn pic_command(k: i64, v: u8) {
    if v & 0x10 != 0 {                       // ICW1: start initialization
        pic[k].init = 2;
        pic[k].imr = 0;
        pic[k].isr = 0;
        pic[k].irr = 0;
        pic[k].read_isr = false;
    } else if v & 0x08 != 0 {                // OCW3
        if v & 0x02 != 0 { pic[k].read_isr = v & 0x01 != 0; }
    } else {                                 // OCW2
        if v & 0x20 != 0 {
            if v & 0x40 != 0 {               // specific EOI
                pic[k].isr &= ~(1 << (v & 7));
            } else {                         // non-specific: clear the highest priority in service
                for n: u8 in 0..8 {
                    let bit: u8 = 1 << n;
                    if pic[k].isr & bit != 0 { pic[k].isr &= ~bit; break; }
                }
            }
        }
    }
    pic_update();
}

fn pic_data(k: i64, v: u8) {
    if pic[k].init == 2 { pic[k].base = v & 0xF8; pic[k].init = 3; }
    else if pic[k].init == 3 { pic[k].init = 4; }
    else if pic[k].init == 4 { pic[k].init = 0; }
    else { pic[k].imr = v; }
    pic_update();
}

// ---- Timer (8254) ----
//
// The virtual clock is the instruction count: the timer's 1,193,182 Hz input advances one tick
// every TICK_INSNS instructions. Only channel 0 raises an interrupt.

let TICK_INSNS = 4;

struct Channel {
    reload: u32,     // 0 means 65536
    mode: u8,
    access: u8,      // 1 low byte, 2 high byte, 3 low then high
    write_hi: bool,
    read_hi: bool,
    latched: bool,
    latch: u16,
    pending: u16,    // low byte of a two-byte write
}

var pit: Channel[3] = [Channel { reload: 0, mode: 3, access: 3, write_hi: false, read_hi: false, latched: false, latch: 0, pending: 0 },
                       Channel { reload: 18, mode: 2, access: 1, write_hi: false, read_hi: false, latched: false, latch: 0, pending: 0 },
                       Channel { reload: 0, mode: 3, access: 3, write_hi: false, read_hi: false, latched: false, latch: 0, pending: 0 }];

var timer_on = true;         // channel 0 is counting
var timer_left = 262144;     // instructions until channel 0 next reaches zero

fn pit_period() -> i64 {
    let n: i64 = if pit[0].reload == 0 { 65536 } else { pit[0].reload };
    return n * TICK_INSNS;
}

// Channel 0 reached zero.
fn timer_fire() {
    raise_irq(0);
    timer_left = pit_period();
    if pit[0].mode != 2 && pit[0].mode != 3 { timer_on = false; }     // one-shot modes stop
}

fn pit_count(k: i64) -> u16 {
    if k == 0 { return (timer_left / TICK_INSNS) as! u16; }
    return pit[k].reload as! u16;
}

fn pit_control(v: u8) {
    let k: i64 = v >> 6;
    if k == 3 { return; }                    // read-back command: not modelled
    let access = v >> 4 & 3;
    if access == 0 {                         // latch the current count
        pit[k].latch = pit_count(k);
        pit[k].latched = true;
        pit[k].read_hi = false;
        return;
    }
    pit[k].access = access;
    pit[k].mode = v >> 1 & 7;
    if pit[k].mode > 5 { pit[k].mode -= 4; }
    pit[k].write_hi = false;
    pit[k].read_hi = false;
    // A control word alone stops the count until a new value is written.
    if k == 0 { timer_on = false; }
}

fn pit_write(k: i64, v: u8) {
    if pit[k].access == 3 {
        if !pit[k].write_hi { pit[k].pending = v; pit[k].write_hi = true; return; }
        pit[k].write_hi = false;
        pit[k].reload = pit[k].pending | (v as u32) << 8;
    } else if pit[k].access == 2 {
        pit[k].reload = (v as u32) << 8;
    } else {
        pit[k].reload = v;
    }
    if k == 0 { timer_on = true; timer_left = pit_period(); }
}

fn pit_read(k: i64) -> u8 {
    let v = if pit[k].latched { pit[k].latch } else { pit_count(k) };
    if pit[k].access == 3 {
        if !pit[k].read_hi { pit[k].read_hi = true; return v as! u8; }
        pit[k].read_hi = false;
        pit[k].latched = false;
        return (v >> 8) as! u8;
    }
    pit[k].latched = false;
    if pit[k].access == 2 { return (v >> 8) as! u8; }
    return v as! u8;
}

// ---- Keyboard controller (8042) ----

let KBD_QUEUE = 256;

var kbd_queue: u8[KBD_QUEUE] = [0; KBD_QUEUE];
var kbd_head = 0;
var kbd_tail = 0;
var kbd_out: u8 = 0;         // the output buffer the guest reads at port 60h
var kbd_full = false;
var kbd_command: u8 = 0;     // controller command waiting for its data byte, or 0
var kbd_config: u8 = 0x45;   // command byte: interrupt on, system flag, translation
var port_b: u8 = 0;          // port 61h (speaker gate and friends)

// Moves the next queued byte into the output buffer and raises IRQ 1.
fn kbd_pump() {
    if kbd_full || kbd_head == kbd_tail { return; }
    kbd_out = kbd_queue[kbd_head];
    kbd_head = (kbd_head + 1) % KBD_QUEUE;
    kbd_full = true;
    if kbd_config & 1 != 0 { raise_irq(1); }
}

fn kbd_push(v: u8) {
    let next = (kbd_tail + 1) % KBD_QUEUE;
    if next == kbd_head { return; }          // full: the byte is dropped
    kbd_queue[kbd_tail] = v;
    kbd_tail = next;
    kbd_pump();
}

fn kbd_queued() -> i64 { return (kbd_tail - kbd_head + KBD_QUEUE) % KBD_QUEUE; }

fn kbd_read_data() -> u8 {
    let v = kbd_out;
    kbd_full = false;
    kbd_pump();
    return v;
}

fn kbd_write_data(v: u8) {
    if kbd_command == 0x60 { kbd_config = v; kbd_command = 0; return; }
    if kbd_command != 0 { kbd_command = 0; return; }       // data for a command not modelled
    // A byte for the keyboard itself (LEDs, typematic, reset ...): acknowledge it.
    if v == 0xFF { kbd_push(0xFA); kbd_push(0xAA); return; }
    kbd_push(0xFA);
}

fn kbd_write_command(v: u8) {
    match v {
        0x20 => { kbd_push(kbd_config); },
        0x60, 0xD1 => { kbd_command = v; },
        0xAA => { kbd_push(0x55); },
        0xAB => { kbd_push(0x00); },
        0xD0 => { kbd_push(0x02); },
        _ => {},
    }
}

// ---- CRT controller ----

var crtc_index: u8 = 0;
var crtc: u8[32] = [0; 32];
var retrace: u8 = 0;

// ---- Diagnostic port and serial port (used by the test386 ROM) ----

var post_trail: u8[>..];     // every code written to the diagnostic port, in order
var com_out: u8[>..];        // every byte sent through COM1
var com_lcr: u8 = 0;         // COM1's line control register

// ---- Port dispatch ----


fn note_unknown(port: u16) {
    if unknown_ports[port] < 255 { unknown_ports[port] += 1; }
}

fn port_in8(port: u16) -> u8 {
    match port {
        0x20 => { return if pic[0].read_isr { pic[0].isr } else { pic[0].irr }; },
        0x21 => { return pic[0].imr; },
        0xA0 => { return if pic[1].read_isr { pic[1].isr } else { pic[1].irr }; },
        0xA1 => { return pic[1].imr; },
        0x40..0x43 => { return pit_read(port - 0x40); },
        0x60 => { return kbd_read_data(); },
        0x61 => { return port_b; },
        0x64 => { return if kbd_full { 0x1D } else { 0x1C }; },
        0x3D4 => { return crtc_index; },
        0x3D5 => { return crtc[crtc_index & 31]; },
        0x3DA => { retrace ^= 0x09; return retrace; },
        0x3FD => { return 0x60; },                       // COM1 line status: ready to send
        _ => { note_unknown(port); return 0xFF; },
    }
}

fn port_out8(port: u16, v: u8) {
    match port {
        0x20 => { pic_command(0, v); },
        0x21 => { pic_data(0, v); },
        0xA0 => { pic_command(1, v); },
        0xA1 => { pic_data(1, v); },
        0x40..0x43 => { pit_write(port - 0x40, v); },
        0x43 => { pit_control(v); },
        0x60 => { kbd_write_data(v); },
        0x61 => { port_b = v; },
        0x64 => { kbd_write_command(v); },
        0x3D4 => { crtc_index = v; },
        0x3D5 => { crtc[crtc_index & 31] = v; },
        0x190 => { post_trail.push(v); },
        // With the divisor latch open (bit 7 of the line control register), the data register
        // holds the low byte of the baud rate divisor, not a byte to send.
        0x3F8 => { if com_lcr & 0x80 == 0 { com_out.push(v); } },
        0x3FB => { com_lcr = v; },
        0x3F9, 0x3FA, 0x3FC => {},                       // the rest of COM1's setup
        _ => { note_unknown(port); },
    }
}

fn port_in(port: u16) -> u16 {
    let lo: u16 = port_in8(port);
    let hi: u16 = port_in8(port + 1);
    return lo | hi << 8;
}

fn port_out(port: u16, v: u16) {
    port_out8(port, v as! u8);
    port_out8(port + 1, (v >> 8) as! u8);
}
