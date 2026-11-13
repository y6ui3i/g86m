// Protection: descriptors, loading segment registers, far control transfers, and delivering
// interrupts and faults, in real mode, protected mode and virtual-8086 mode.
//
// Everything here can fault (see raise in state.goose), so it runs inside exec_one.

import state;

// ---- Descriptors ----

// The linear address of the descriptor a selector names; false when it lies outside its table.
fn desc_at(sel: u16) -> u32, bool {
    let index: u32 = sel & 0xFFF8;
    if sel & 4 != 0 {
        if ldtr_sel & 0xFFFC == 0 || index + 7 > ldtr_limit { return 0, false; }
        return ldtr_base + index, true;
    }
    if index + 7 > gdtr_limit { return 0, false; }
    return gdtr_base + index, true;
}

fn d_base(lo: u32, hi: u32) -> u32 { return lo >> 16 | (hi & 0xFF) << 16 | hi & 0xFF000000; }

fn d_limit(lo: u32, hi: u32) -> u32 {
    let l = lo & 0xFFFF | hi & 0x000F0000;
    if hi & 0x00800000 != 0 { return l << 12 | 0xFFF; }
    return l;
}

// The cache attributes of a descriptor: access byte, flags nibble, and "usable".
fn d_attr(hi: u32) -> u32 { return hi >> 8 & 0xFF | hi >> 8 & 0xF000 | A_VALID; }
fn d_dpl(hi: u32) -> u8 { return (hi >> 13 & 3) as! u8; }

// Reads the descriptor for sel. A null selector or one outside its table is a general
// protection fault carrying err_null or the selector.
fn read_desc(sel: u16, err_null: u32) -> u32, u32, u32 {
    if sel & 0xFFFC == 0 { raise_gp(err_null); }
    let at, ok = desc_at(sel);
    if !ok { raise_gp(sel & 0xFFFC); }
    return at, sys_read(at, 32), sys_read(at + 4, 32);
}

fn mark_accessed(at: u32, hi: u32) {
    if hi & 0x100 == 0 { sys_write(at + 5, 8, hi >> 8 & 0xFF | 1); }
}

fn set_cache(s: i64, sel: u16, lo: u32, hi: u32) {
    cpu.segs[s] = sel;
    cpu.base[s] = d_base(lo, hi);
    cpu.limit[s] = d_limit(lo, hi);
    cpu.attr[s] = d_attr(hi) | A_ACCESSED;
}

fn null_seg(s: i64, sel: u16) {
    cpu.segs[s] = sel;
    cpu.base[s] = 0;
    cpu.limit[s] = 0;
    cpu.attr[s] = 0;
}

// A segment register as virtual-8086 mode has it: real-mode addressing, 64 KB, privilege level 3.
fn v86_seg(s: i64, sel: u16) {
    set_seg(s, sel);
    cpu.limit[s] = 0xFFFF;
    cpu.attr[s] = if s == CS { 0x100FB } else { 0x100F3 };
}

// ---- Loading ES, SS, DS, FS, GS ----

fn load_seg(s: i64, sel: u16) {
    if !protected() { set_seg(s, sel); return; }
    if v86() { v86_seg(s, sel); return; }
    if sel & 0xFFFC == 0 {
        if s == SS { raise_gp(0); }
        null_seg(s, sel);
        return;
    }
    let at, lo, hi = read_desc(sel, 0);
    let e: u32 = sel & 0xFFFC;
    let acc = hi >> 8;
    let rpl: u8 = (sel & 3) as! u8;
    let dpl = d_dpl(hi);
    if s == SS {
        if rpl != cpu.cpl || dpl != cpu.cpl || acc & A_S == 0 || acc & A_CODE != 0 || acc & A_RW == 0 { raise_gp(e); }
        if acc & A_PRESENT == 0 { raise_ss(e); }
    } else {
        if acc & A_S == 0 { raise_gp(e); }
        if acc & A_CODE != 0 && acc & A_RW == 0 { raise_gp(e); }             // execute-only code
        if acc & A_CODE == 0 || acc & A_DOWN_CONF == 0 {                     // data, or non-conforming code
            if rpl > dpl || cpu.cpl > dpl { raise_gp(e); }
        }
        if acc & A_PRESENT == 0 { raise_np(e); }
    }
    mark_accessed(at, hi);
    set_cache(s, sel, lo, hi);
}

// Loads CS with a code segment already checked, at privilege level level.
fn load_cs(sel: u16, at: u32, lo: u32, hi: u32, level: u8) {
    mark_accessed(at, hi);
    set_cache(CS, sel & 0xFFFC | level, lo, hi);
    cpu.cpl = level;
}

// Checks that a descriptor is a present code segment control may go to from the current level:
// a conforming one at the same or a more privileged level, another at exactly `need`.
fn check_code(sel: u16, hi: u32, need: u8, err_ext: u32) {
    let e: u32 = sel & 0xFFFC | err_ext;
    let acc = hi >> 8;
    if acc & A_S == 0 || acc & A_CODE == 0 { raise_gp(e); }
    if acc & A_DOWN_CONF != 0 { if d_dpl(hi) > need { raise_gp(e); } }
    else if d_dpl(hi) != need { raise_gp(e); }
    if acc & A_PRESENT == 0 { raise_np(e); }
}

// After a return to a less privileged level: a data segment register left pointing at a segment
// the new level may not use is emptied.
fn drop_privileged_segs() {
    for s in [ES, DS, FS, GS] {
        let a = cpu.attr[s];
        let dpl: u8 = (a >> 5 & 3) as! u8;
        if a & A_VALID != 0 && (a & A_CODE == 0 || a & A_DOWN_CONF == 0) && dpl < cpu.cpl { null_seg(s, 0); }
    }
}

// ---- The task segment ----

// The stack a more privileged level starts on: SS and ESP for that level, from the task segment.
fn level_stack(level: u8) -> u16, u32 {
    let k: u32 = level;
    if tr_32 {
        let at = 4 + k * 8;
        if at + 7 > tr_limit { raise(10, true, tr_sel & 0xFFFC); }
        return sys_read(tr_base + at + 4, 16) as! u16, sys_read(tr_base + at, 32);
    }
    let at = 2 + k * 4;
    if at + 3 > tr_limit { raise(10, true, tr_sel & 0xFFFC); }
    return sys_read(tr_base + at + 2, 16) as! u16, sys_read(tr_base + at, 16);
}

// Loads SS for a switch to a more privileged level. Problems are invalid-TSS faults.
fn load_inner_ss(sel: u16, level: u8) {
    let e: u32 = sel & 0xFFFC;
    if e == 0 { raise(10, true, 0); }
    let at, ok = desc_at(sel);
    if !ok { raise(10, true, e); }
    let lo = sys_read(at, 32);
    let hi = sys_read(at + 4, 32);
    let acc = hi >> 8;
    if (sel & 3) as! u8 != level || d_dpl(hi) != level || acc & A_S == 0 || acc & A_CODE != 0 || acc & A_RW == 0 { raise(10, true, e); }
    if acc & A_PRESENT == 0 { raise_ss(e); }
    mark_accessed(at, hi);
    set_cache(SS, sel, lo, hi);
}

// May the current code use I/O port `port` for an access of w bits?
fn io_check(port: u16, w: u8) {
    if !protected() { return; }
    if !v86() && cpu.cpl <= iopl() { return; }
    // Otherwise the task segment's I/O permission bitmap decides: a clear bit allows the port.
    if !tr_32 || tr_limit < 0x67 { raise_gp(0); }
    let map: u32 = sys_read(tr_base + 0x66, 16);
    for i: u32 in 0..(w as u32) / 8 {
        let first: u32 = port;
        let p = first + i;
        let at = map + p / 8;
        if at > tr_limit { raise_gp(0); }
        if sys_read(tr_base + at, 8) >> (p & 7) & 1 != 0 { raise_gp(0); }
    }
}

// ---- Far jumps, calls and returns ----

fn far_jump(sel: u16, off: u32) {
    if !protected() { set_seg(CS, sel); cpu.ip = off; return; }
    if v86() { v86_seg(CS, sel); cpu.ip = off; return; }
    let at, lo, hi = read_desc(sel, 0);
    let e: u32 = sel & 0xFFFC;
    let acc = hi >> 8;
    let rpl: u8 = (sel & 3) as! u8;
    if acc & A_S != 0 {
        if acc & A_DOWN_CONF == 0 && rpl > cpu.cpl { raise_gp(e); }
        check_code(sel, hi, cpu.cpl, 0);
        if off > d_limit(lo, hi) { raise_gp(0); }
        load_cs(sel, at, lo, hi, cpu.cpl);
        cpu.ip = off;
        return;
    }
    let kind = acc & 0x0F;
    if kind != 4 && kind != 12 { stop("far jump to a task or unknown system segment, type", kind); return; }
    // Through a call gate: the gate names the real target.
    if d_dpl(hi) < cpu.cpl || d_dpl(hi) < rpl { raise_gp(e); }
    if acc & A_PRESENT == 0 { raise_np(e); }
    let tsel = (lo >> 16) as! u16;
    let toff = if kind == 12 { lo & 0xFFFF | hi & 0xFFFF0000 } else { lo & 0xFFFF };
    let tat, tlo, thi = read_desc(tsel, 0);
    check_code(tsel, thi, cpu.cpl, 0);
    load_cs(tsel, tat, tlo, thi, cpu.cpl);
    cpu.ip = toff;
}

fn far_call(sel: u16, off: u32, w: u8) {
    if !protected() || v86() {
        push_w(cpu.segs[CS], w);
        push_w(cpu.ip, w);
        if v86() { v86_seg(CS, sel); } else { set_seg(CS, sel); }
        cpu.ip = off;
        return;
    }
    let at, lo, hi = read_desc(sel, 0);
    let e: u32 = sel & 0xFFFC;
    let acc = hi >> 8;
    let rpl: u8 = (sel & 3) as! u8;
    if acc & A_S != 0 {
        if acc & A_DOWN_CONF == 0 && rpl > cpu.cpl { raise_gp(e); }
        check_code(sel, hi, cpu.cpl, 0);
        if off > d_limit(lo, hi) { raise_gp(0); }
        push_w(cpu.segs[CS], w);
        push_w(cpu.ip, w);
        load_cs(sel, at, lo, hi, cpu.cpl);
        cpu.ip = off;
        return;
    }
    let kind = acc & 0x0F;
    if kind != 4 && kind != 12 { stop("far call to a task or unknown system segment, type", kind); return; }
    if d_dpl(hi) < cpu.cpl || d_dpl(hi) < rpl { raise_gp(e); }
    if acc & A_PRESENT == 0 { raise_np(e); }
    let gw: u8 = if kind == 12 { 32 } else { 16 };
    let tsel = (lo >> 16) as! u16;
    let toff = if kind == 12 { lo & 0xFFFF | hi & 0xFFFF0000 } else { lo & 0xFFFF };
    let params = hi & 0x1F;
    let tat, tlo, thi = read_desc(tsel, 0);
    let tacc = thi >> 8;
    let te: u32 = tsel & 0xFFFC;
    if tacc & A_S == 0 || tacc & A_CODE == 0 || d_dpl(thi) > cpu.cpl { raise_gp(te); }
    if tacc & A_PRESENT == 0 { raise_np(te); }
    let old_cs = cpu.segs[CS];
    let old_ip = cpu.ip;
    if tacc & A_DOWN_CONF == 0 && d_dpl(thi) < cpu.cpl {
        // To a more privileged level: switch to that level's stack and carry the parameters over.
        let level = d_dpl(thi);
        let old_ss = cpu.segs[SS];
        let old_sp = sp_get();
        var copied: u32[32] = [0; 32];
        for i: u32 in 0..params { copied[i] = seg_read(SS, old_sp + i * ((gw as u32) / 8), gw); }
        let nss, nsp = level_stack(level);
        cpu.cpl = level;
        load_inner_ss(nss, level);
        sp_set(nsp);
        push_w(old_ss, gw);
        push_w(old_sp, gw);
        for k: u32 in 0..params { push_w(copied[params - 1 - k], gw); }
        push_w(old_cs, gw);
        push_w(old_ip, gw);
        load_cs(tsel, tat, tlo, thi, level);
    } else {
        push_w(old_cs, gw);
        push_w(old_ip, gw);
        load_cs(tsel, tat, tlo, thi, cpu.cpl);
    }
    cpu.ip = toff;
}

// RETF: pops the return address and then `extra` bytes of parameters.
fn far_ret(w: u8, extra: u32) {
    let n: u32 = (w as u32) / 8;
    if !protected() || v86() {
        let ip = pop_w(w);
        let cs = pop_w(w) as! u16;
        if v86() { v86_seg(CS, cs); } else { set_seg(CS, cs); }
        cpu.ip = ip;
        sp_set(sp_get() + extra);
        return;
    }
    let sp = sp_get();
    let ip = seg_read(SS, sp, w);
    let sel = seg_read(SS, sp + n, w) as! u16;
    let rpl: u8 = (sel & 3) as! u8;
    let at, lo, hi = read_desc(sel, 0);
    if rpl < cpu.cpl { raise_gp(sel & 0xFFFC); }
    check_code(sel, hi, rpl, 0);
    if rpl == cpu.cpl {
        sp_set(sp + 2 * n + extra);
        load_cs(sel, at, lo, hi, rpl);
        cpu.ip = ip;
        return;
    }
    // To a less privileged level: the caller's stack is on ours, after the parameters.
    let nsp = seg_read(SS, sp + 2 * n + extra, w);
    let nss = seg_read(SS, sp + 3 * n + extra, w) as! u16;
    load_cs(sel, at, lo, hi, rpl);
    load_seg(SS, nss);
    sp_set(nsp + extra);
    drop_privileged_segs();
    cpu.ip = ip;
}

// ---- Interrupts and faults ----

// Enters the handler for vector vec. soft is true for INT n, INT3 and INTO, which a gate's
// privilege level can forbid; an error code is pushed for the faults that have one.
fn deliver(vec: u8, soft: bool, has_err: bool, err: u32) {
    cpu.halted = false;
    let v: u32 = vec;
    if !protected() {
        // Real mode: the vector table holds 16-bit segment:offset pairs.
        if v * 4 + 3 > idtr_limit { stop("interrupt vector outside the real-mode table", vec); return; }
        push_w(cpu.flags, 16);
        push_w(cpu.segs[CS], 16);
        push_w(cpu.ip, 16);
        set_flag(IF, false);
        set_flag(TF, false);
        cpu.ip = sys_read(idtr_base + v * 4, 16);
        set_seg(CS, sys_read(idtr_base + v * 4 + 2, 16) as! u16);
        return;
    }
    let ext: u32 = if soft { 0 } else { 1 };
    let e = v * 8 + 2 + ext;
    if v * 8 + 7 > idtr_limit { raise_gp(e); }
    let lo = sys_read(idtr_base + v * 8, 32);
    let hi = sys_read(idtr_base + v * 8 + 4, 32);
    let kind = hi >> 8 & 0x1F;
    if kind == 5 { stop("task gate in the interrupt table, vector", vec); return; }
    if kind != 6 && kind != 7 && kind != 14 && kind != 15 { raise_gp(e); }
    if soft && d_dpl(hi) < cpu.cpl { raise_gp(v * 8 + 2); }
    if hi & 0x8000 == 0 { raise_np(e); }
    let w: u8 = if kind >= 14 { 32 } else { 16 };
    let tsel = (lo >> 16) as! u16;
    let toff = if w == 32 { lo & 0xFFFF | hi & 0xFFFF0000 } else { lo & 0xFFFF };
    if tsel & 0xFFFC == 0 { raise_gp(ext); }
    let tat, ok = desc_at(tsel);
    let te: u32 = tsel & 0xFFFC | ext;
    if !ok { raise_gp(te); }
    let tlo = sys_read(tat, 32);
    let thi = sys_read(tat + 4, 32);
    let tacc = thi >> 8;
    if tacc & A_S == 0 || tacc & A_CODE == 0 || d_dpl(thi) > cpu.cpl { raise_gp(te); }
    if tacc & A_PRESENT == 0 { raise_np(te); }

    let old_flags = cpu.flags;
    let old_cs = cpu.segs[CS];
    let old_ip = cpu.ip;
    var level = cpu.cpl;
    if tacc & A_DOWN_CONF == 0 && d_dpl(thi) < cpu.cpl {
        // The handler is more privileged: it runs on its own stack, taken from the task segment.
        level = d_dpl(thi);
        let from_v86 = v86();
        if from_v86 && level != 0 { raise_gp(te); }
        let old_ss = cpu.segs[SS];
        let old_sp = sp_get();
        let nss, nsp = level_stack(level);
        cpu.flags &= ~VM;                // from here on segment registers load the protected way
        cpu.cpl = level;
        load_inner_ss(nss, level);
        sp_set(nsp);
        if from_v86 {
            push_w(cpu.segs[GS], 32);
            push_w(cpu.segs[FS], 32);
            push_w(cpu.segs[DS], 32);
            push_w(cpu.segs[ES], 32);
            for s in [ES, DS, FS, GS] { null_seg(s, 0); }
        }
        push_w(old_ss, w);
        push_w(old_sp, w);
    } else if v86() {
        raise_gp(te);                    // a handler cannot run in virtual-8086 mode
    }
    push_w(old_flags, w);
    push_w(old_cs, w);
    push_w(old_ip, w);
    if has_err { push_w(err, w); }
    load_cs(tsel, tat, tlo, thi, level);
    cpu.ip = toff;
    cpu.flags &= ~(TF | NT | VM | RF);
    if kind == 6 || kind == 14 { set_flag(IF, false); }      // an interrupt gate, not a trap gate
}

// IRET.
fn do_iret(w: u8) {
    let n: u32 = (w as u32) / 8;
    if !protected() || v86() {
        if v86() && iopl() < 3 { raise_gp(0); }
        let ip = pop_w(w);
        let cs = pop_w(w) as! u16;
        let fl = pop_w(w);
        if v86() { v86_seg(CS, cs); } else { set_seg(CS, cs); }
        cpu.ip = ip;
        // Virtual-8086 code cannot change IOPL; nothing here can set VM.
        let m: u32 = if v86() { 0x4FD5 } else { 0x7FD5 };
        write_flags(fl, if w == 32 { m | RF } else { m });
        return;
    }
    if flag(NT) { stop("IRET with NT set (task return) is not implemented", 0); return; }
    let sp = sp_get();
    let ip = seg_read(SS, sp, w);
    let sel = seg_read(SS, sp + n, w) as! u16;
    let fl = seg_read(SS, sp + 2 * n, w);
    if w == 32 && fl & VM != 0 && cpu.cpl == 0 {
        // Back to virtual-8086 mode: the frame also holds ESP, SS and the four data segments.
        let nsp = seg_read(SS, sp + 12, 32);
        let nss = seg_read(SS, sp + 16, 32) as! u16;
        let es = seg_read(SS, sp + 20, 32) as! u16;
        let ds = seg_read(SS, sp + 24, 32) as! u16;
        let fs = seg_read(SS, sp + 28, 32) as! u16;
        let gs = seg_read(SS, sp + 32, 32) as! u16;
        write_flags(fl, 0x37FD5);
        cpu.cpl = 3;
        v86_seg(CS, sel);
        v86_seg(SS, nss);
        v86_seg(ES, es);
        v86_seg(DS, ds);
        v86_seg(FS, fs);
        v86_seg(GS, gs);
        cpu.ip = ip & 0xFFFF;
        set_r32(SP, nsp);
        return;
    }
    let rpl: u8 = (sel & 3) as! u8;
    let at, lo, hi = read_desc(sel, 0);
    if rpl < cpu.cpl { raise_gp(sel & 0xFFFC); }
    check_code(sel, hi, rpl, 0);
    // IF changes only if the level may do I/O; IOPL only at level 0.
    var m: u32 = 0x4DD5;
    if w == 32 { m |= RF; }
    if cpu.cpl <= iopl() { m |= IF; }
    if cpu.cpl == 0 { m |= IOPL; }
    if rpl == cpu.cpl {
        sp_set(sp + 3 * n);
        load_cs(sel, at, lo, hi, rpl);
        cpu.ip = ip;
        write_flags(fl, m);
        return;
    }
    let nsp = seg_read(SS, sp + 3 * n, w);
    let nss = seg_read(SS, sp + 4 * n, w) as! u16;
    write_flags(fl, m);
    load_cs(sel, at, lo, hi, rpl);
    load_seg(SS, nss);
    sp_set(nsp);
    drop_privileged_segs();
    cpu.ip = ip;
}
