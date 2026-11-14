# Experiment ledger

A card is written before an experiment runs, and its result is added in the same place.

## E001: Can the core of an emulator be written in Goose? (M0, 2026-11-12)

- **Hypothesis**: With Goose v2026.4, the four shapes at the core of an x86 interpreter can be written
  without fighting the language.
  (a) A struct for the CPU state and 1 MB of guest RAM, both as globals
  (b) Opcode dispatch with `match`, at a usable speed
  (c) A round trip of the CPU state through `to_bytes` / `from_bytes` (the seed of snapshots)
  (d) Calling our own C through `extern fn` (glue for things like terminal raw mode)
- **What changed since last time**: First run. The inputs are rustx86's `asm/hello.bin` and
  `asm/bench.bin` (a 10-instruction loop with a fixed instruction count).
- **Next move for each result**:
  - hello prints `Hello, World!`, bench stops at HLT and runs at 100 MIPS or more → go on to M1
    (the full 8086 instruction set) written the same way
  - It works but below 30 MIPS → read the generated C, then change the bounds checks (`--bce-lines`)
    and where RAM lives, and measure again
  - (a) or (b) cannot be written under the language rules → move RAM to the C side and reassess.
    If that fails too, report it as grounds for dropping Goose
  - Only (c) or (d) cannot be written → carry on with M1, and record in an ADR that snapshots and
    glue live on the C side
- **Cut-off**: The same day. On anything that looks like a compiler bug, keep a minimal reproduction
  and move on with a workaround.

### Result

2026-11-12, Goose v2026.4 (macos-arm64 release), clang 21.0.0, Apple Silicon. All four passed.
**Next move: on to M1, written the same way.**

| Item | Result |
|---|---|
| (a) struct + 1 MB RAM | `var ram: u8[RAM_SIZE]` and `var cpu: Cpu` work as globals (`probe/m0.goose`) |
| (b) `match` dispatch | hello.bin prints `Hello, World!` and halts after 84 instructions. bench.bin halts after 369,095,178 instructions; three runs took 1857–1890 ms = **about 197 MIPS** |
| (b) correctness | At the end of bench, AX=57136 BX=13090 DX=4148 and the instruction count match a separately written Python model |
| (c) snapshot | `Cpu[>..]` (30 bytes) and 1 MB of RAM make the round trip through `to_bytes` → `from_bytes` and compare equal. Corrupting the first byte returns `false` and an empty array (`probe/m0_snap.goose`) |
| (d) C interop | `c_sources` in `m0_cext.build` links our own C; a scalar and a slice (`{data, len}`) cross the boundary (`probe/m0_cext.goose`) |

What was learned:

- A `--debug` build takes 21,248 ms on bench (about 17 MIPS). It adds signed-overflow and range
  checks, so tests use debug and measurements use release
- Serialization works on arrays. A single struct goes in a one-element `T[>..]`
- `args` and `write_stderr` need `import os;` (`std` alone does not provide them)
- An integer `match` takes half-open ranges (`0x40..0x48`), so opcodes with an embedded register
  number can be listed as they are
- The only thing typechecking made me fix was one import line. Nothing got stuck on the language rules

Not measured: ModR/M with memory operands, interrupts, devices. The 197 MIPS figure is for a
10-instruction loop, not for running an operating system.

## E002: Speed against the same fragment written in Rust (2026-11-12)

- **Hypothesis**: Rust code of the same shape as `probe/m0.goose` (`probe/m0.rs`: the same
  instructions, the same flag computation, the same 1 MB of RAM) is within ±20% of the Goose version
  on bench.bin.
- **What changed since last time**: The Goose version from E001 is unchanged. Two things are added
  to compare against: (1) the same fragment in Rust, and (2) rustx86's own `core/examples/bench.rs`,
  as a reference only, since it is the finished product with a decode cache, devices and interrupts.
- **Next move for each result**:
  - Within ±20% → stop worrying about the language's speed and go on to M1. Work on speed waits
    until the instruction set is complete
  - Goose is more than 20% slower → before M1, look at the remaining bounds checks with
    `--bce-lines` and decide how RAM access is written
  - Goose is more than 20% faster → check why once (the generated C and assembly), record it, and
    go on to M1
- **Cut-off**: The same day. Five runs each, compared by the median.

### Result

2026-11-12, Apple Silicon, bench.bin (369,095,178 instructions), median of five runs each.
**The hypothesis was wrong. The Goose version takes about 35% longer than Rust code of the same shape.**

| Implementation | Median | MIPS | Notes |
|---|---:|---:|---|
| Rust fragment (`probe/m0.rs`, rustc 1.97.1 `-C opt-level=3`) | 1386 ms | about 266 | |
| Goose fragment (`probe/m0.goose`, v2026.4 → clang 21 `-O2`) | 1873 ms | about 197 | 1.35 times the Rust time |
| rustx86 itself (`core/examples/bench.rs`, release) | 7.07 s | about 52 | The finished product, with devices, interrupts and 32-bit support; a reference only |

All three execute 369,095,178 instructions. The two fragments also agree on AX / BX / DX at the end.

The cause was looked into once:

- **Not bounds checks.** `--bce-lines` shows 59 of 60 removed. The one that remains is on the AH side
  of `get8` (`regs[i - 4]`), which bench's inner loop never reaches
- **Not indirection through globals.** `GS_GL` in the generated C is the address of static storage;
  no pointer is reloaded
- **Hardly the C optimization level.** Recompiling the generated C at `-O3` gives 1765 ms (about 5% better)
- One candidate remains and is untested: a `u8` write to RAM may alias the CPU state, so clang may
  reload flags and registers after every write. Rust avoids this through the uniqueness of `Box`

Next move (the "more than 20% slower" branch of the card, updated with what was found):

- Bounds checks are not the cause, so the way RAM access is written stays. **M1 goes ahead as planned**
- Speed is measured again once the instruction set is complete, at the point lazy flags go in
  (keep only the result and the operands, compute a flag when it is read). That cuts the reads and
  writes in set_flag, so it should help at the same time if aliasing reloads are the cause
- Even as a fragment, Goose is about 3.8 times faster than rustx86 itself. rustx86 does much more,
  so this does not mean Goose is faster than Rust

## E003: Verify the 8086 instruction set by diffing traces against rustx86 (M1, 2026-11-12)

- **Hypothesis**: The 16-bit real-mode implementation in `src/` matches rustx86 on every line of the
  state at each instruction boundary (CS:IP, the eight general registers, ES/SS/DS, FLAGS), for eight
  test boot sectors, one per instruction group (`tests/asm/t_*.asm`), and four rustx86 boot sectors.
- **What changed since last time**: The fragment from E001 (25 instructions) grew into the 8086 + 186
  instruction set. The oracle is `trace16`, added to rustx86 (`tools/oracle/trace16.rs`). rustx86
  matches expected values from a real 386 bit for bit on test386.asm, so g86m follows rustx86 on
  undefined flags too.
- **Next move for each result**:
  - Every line matches → fix the expected traces in `tests/expected/`, open a PR, go on to M2 (ELKS)
  - A mismatch → find the instruction at the first line that differs and fix it. If it is an
    undefined flag, read rustx86's implementation and follow it
  - If rustx86 looks like it departs from the 8086 specification → do not follow it; record it and ask
- **Cut-off**: The same day. Instructions with no test (IN/OUT on real devices, the interrupt
  controller) move to M2.

### Result

2026-11-12. **Every line matched. Next move: fix the expected traces, open a PR, go on to M2.**

| Test | Lines | Contents |
|---|---:|---|
| t_alu / t_alu2 | 945 / 400 | The 8 operations and TEST, INC / DEC / NEG / NOT, in every operand form |
| t_shift | 2924 | 7 rotates and shifts × 14 counts × 8 and 16 bits |
| t_muldiv | 650 | MUL / IMUL / DIV / IDIV, divide errors, CBW / CWD / AAM / AAD |
| t_bcd | 4533 | DAA / DAS / AAA / AAS × 52 values of AL × 4 combinations of CF and AF |
| t_string | 96 | MOVS / CMPS / SCAS / STOS / LODS, each REP form, both directions of DF, segment overrides |
| t_flow | 538 | 16 conditions × 14 flag words, the LOOP family, CALL / RET / far forms, INT / INTO / IRET |
| t_misc | 147 | 24 ModR/M forms, default and overridden segments, the stack, PUSHA / ENTER, XCHG / XLAT, flag instructions |
| hello / interrupt / vram | 98 / 37 / 44 | rustx86's boot sectors |
| s_selfcheck | - | Self-check for the two cases the oracle cannot judge (IDIV of the minimum value, SALC) |

Of the four rustx86 boot sectors the hypothesis named, three were compared. The fourth, `mode13.bin`,
needs devices and is listed under "Left out of M1" below.

Debug and release builds give the same result. `tools/difftest.sh` reproduces it; the expected traces
are fixed in `tests/expected/`, so rustx86 is not needed.

On the first run, 7 of the 11 matched. The causes of the other 4:

| Mismatch | Cause | Fixed in |
|---|---|---|
| OF after right rotates and shifts | A real 386 leaves OF alone unless the count is 1 (only left rotates update it at every count). g86m updated it every time | g86m |
| The top 4 bits pushed by PUSHF | rustx86 defaults to its 8086 profile, which pushes them as ones. g86m pushed zeros | g86m |
| The high word of 16-bit `MUL` was 0 | A Goose compiler bug ([goose-notes.md](goose-notes.md), item 1) | g86m (workaround) |
| The sign of the IDIV remainder | Goose's `%` floors ([goose-notes.md](goose-notes.md), item 2) | g86m |

The tests had three bugs of their own: NASM emitted the 386 near Jcc; a table was read with DF set,
so the read ran backwards; and a caller of RET n did not push the arguments. The backwards read was
an endless loop, and a trace with no cut-off grew to 60 GB. It was deleted at once, and `difftest.sh`
now stops at 2 million instructions.

What turned up in rustx86 and was not followed is at the end of [goose-notes.md](goose-notes.md).

Speed: bench.bin takes 3394–3487 ms on the release build = **about 108 MIPS**. It is slower than the
E001 fragment (197 MIPS) because prefix handling and the general form of ModR/M are now in. It is
about twice rustx86 itself (about 52 MIPS).

Left out of M1:

- `mode13.bin`: it needs the INT 10h mode set and the VGA DAC ports. Devices start in M2
- IN / OUT on real devices, the PIC and PIT, hardware interrupts
- The 66h / 67h prefixes and instructions that start with 0Fh (386 and later). g86m stops on them
- Checking what is in VRAM. For vram.bin only the register trace is compared

## E004: Boot ELKS to a shell (M2, 2026-11-12)

- **Hypothesis**: With a PIC, a PIT, an 8042 keyboard controller, BIOS disk services (INT 13h) and
  hardware interrupt delivery added to the M1 core, ELKS 0.9.1 (`fd2880.img`, the image rustx86
  boots) reaches `login:`, accepts `root` typed through the keyboard controller, and runs a command
  at the shell prompt.
- **What changed since last time**: M1 ran boot sectors with interrupts disabled and no devices. This
  adds devices, a virtual clock (the PIT advances one tick per 4 instructions), interrupt delivery
  between instructions, and a headless script (`--wait TEXT` / `--type TEXT`) that drives the
  keyboard and reads the text screen at B8000h.
- **Next move for each result**:
  - Reaches the shell and `uname -a` prints an ELKS line → fix the script as a regression test,
    open a PR, then add an interactive terminal front end
  - Stops on an unimplemented BIOS call, port or opcode → implement it and run again (the machine
    stops rather than guessing, so each stop names what is missing)
  - Runs without stopping but never reaches `login:` → compare the trace with rustx86's from the
    start of the disk boot, find the first line that differs that is not an interrupt arriving at a
    different time, and fix that instruction
  - The screen and rustx86's agree up to a point and then the kernel hangs waiting → suspect the
    clock or the interrupt controller, not the CPU: check that IRQ0 is delivered and acknowledged
- **Cut-off**: The same day. If the kernel boots but the keyboard path does not work by then, record
  how far it got and open the PR with `login:` as the reached point.

### Result

2026-11-12. **ELKS reaches the shell and runs commands. Next move: open a PR, then an interactive
terminal front end.**

The script waits for `login:`, types `root`, waits for the `# ` prompt, runs `uname -a` and then
`ls /bin | head -3; echo done-$?`. The screen at the end:

```
[0.69 secs] login: root
# uname -a
ELKS elks 0.9.1 commit d9ca2128 05 May 2026 15:34:43 -0700 ibmpc i8086
# ls /bin | head -3; echo done-$?
advent
arp
banner
done-0
#
```

- It passes on both the debug and the release build, and is now part of `tools/difftest.sh`
  (skipped, and reported as skipped, when `images/fd2880.img` is absent)
- The whole script takes about 0.1 s of real time on the release build
- The M1 trace tests still match on every line after the device work
- bench.bin: 3468–3577 ms, about 105 MIPS (about 108 before). The per-instruction timer countdown
  and the interrupt check cost about 3%

ELKS reached `login:` on the first run of the new code: the machine did not stop on an unimplemented
BIOS call, port or opcode. So the "implement what it stops on" branch of the card was never taken,
and the trace comparison against rustx86 for the disk boot was not needed and not done.

What that leaves untested, since ELKS did not exercise it or nothing checks it:

- The BIOS keyboard path (INT 16h, the INT 09h handler). ELKS installs its own keyboard handler
- INT 10h scrolling and character writes other than teletype output
- Disk writes (INT 13h AH=03h) reach the in-memory image only; nothing is written back to the file
- The clock. One timer tick per 4 instructions is a made-up ratio, and idle time is skipped, so
  nothing here says whether time passes at a believable rate for a person at the keyboard

Known wrong:

- The date ELKS prints is `Thu Oct 17 09:47:13 1991`. There is no CMOS clock, so ports 70h/71h read
  as FFh and ELKS decodes that
- `ktcp` fails to open `/dev/ne0`: the image has networking enabled and there is no NE2000. Expected

Ports ELKS used that nothing answers (from `--ports`): 70h/71h (CMOS), 80h (POST delay), 2E9h/2F9h/
3E9h/3F9h (serial probes), 240h–24Fh and 300h–31Ch and 330h (network and ATA probes), 3F2h (floppy
controller), 110h, 510h/511h.

Not done in M2: an interactive front end. The only way to use the shell so far is the script.

## E005: An interactive terminal console (2026-11-12)

- **Hypothesis**: A console that draws the 80x25 text screen in the host terminal with ANSI escapes,
  feeds host keystrokes to the keyboard controller as scancodes, and paces the virtual clock against
  real time, is enough to use the ELKS shell by hand: what is typed appears, commands run, and
  `sleep 3` takes about 3 seconds.
- **What changed since last time**: E004 drove the machine with a script and skipped idle time. This
  adds C glue for raw terminal mode (`src/console.c`), a renderer that sends only the cells that
  changed, key translation (printable keys, Enter, Backspace, Ctrl combinations, arrows and the
  editing keys), and pacing: the machine runs one hundredth of a second of virtual time, then sleeps
  until real time catches up. The virtual CPU speed stays at 4 instructions per timer tick, about
  4.77 million instructions per second.
- **Next move for each result**:
  - A pseudo-terminal test logs in, runs a command, sees `sleep 3` take 2.5–3.5 s, and quits with
    the terminal restored → open a PR and hand it over to be tried by hand
  - Text is garbled or keys are lost → dump the bytes the console writes and reads in the test and
    fix the renderer or the key translation
  - `sleep 3` is far from 3 s → the pacing or the timer model is wrong; measure virtual against
    real time over the same interval before changing the ratio
  - The terminal is left in raw mode after quitting or a crash → fix the restore path before
    anything else, since that breaks the user's shell
- **Cut-off**: The same day. FreeDOS is out of scope here: it needs M3.

### Result

2026-11-12. **The console works through a pseudo-terminal. Next move: open a PR and hand it over to
be tried by hand.**

`tools/console_test.py` starts g86m on a pseudo-terminal, keeps its own 80x25 grid from the escape
sequences g86m writes, and types as a person would:

| Check | Result |
|---|---|
| Boots to `login:` | 0.7 s of real time, the same figure ELKS prints as `[0.69 secs]` |
| Logs in as root, runs `uname -a` | `ibmpc i8086` on the screen, then the prompt |
| `sleep 3; echo slept` | 3.04 s of real time (accepted range 2.5–3.5 s) |
| Backspace | Seven Backspaces erase `wrongXX`, and the line that runs prints `backsp` |
| Ctrl-C | `sleep 30` is still running after 1 s; Ctrl-C brings the prompt back in 0.02 s |
| Ctrl-] | g86m exits with status 0, leaves the alternate screen, and the terminal modes are back to what they were |

It is part of `tools/difftest.sh` when the image and python3 are there. The M1 trace tests and the
ELKS script still pass on both builds. bench.bin is unchanged at about 105 MIPS.

Two things went wrong on the way, both in the test and not in the console:

- The first version stripped escape sequences and searched the remaining text. The console sends
  only the cells that changed, so blanks that were already on the screen are never sent, and `# `
  could not match. The test now applies cursor moves to a grid of its own
- The first Ctrl-C check passed in 0.00 s: it looked at the grid before reading any new output and
  saw the old prompt. It now waits until `sleep 30` has been running for a second before sending
  Ctrl-C

Not checked, because a pseudo-terminal test cannot see it:

- How it looks: colours, the cursor, the code page 437 line-drawing characters. ELKS at a shell
  prompt uses none of the last
- A host terminal smaller than 80x25. Nothing handles it; lines will wrap (this was the first
  thing to go wrong by hand; see the follow-up below)
- Arrow keys, function keys and the editing keys. The translation is written but no test presses them
- How it feels to type. The guest runs at about 4.77 million instructions per second, a made-up
  figure that follows from 4 instructions per timer tick

### Follow-up: first try by hand (2026-11-12)

The first session by hand looked broken: prompts repeated down the screen, and the output of `ls`
appeared as one line with a `#` written over its start. The pasted screen had 10 lines.

- **Cause, as far as the evidence goes**: the terminal was shorter than 25 rows. The console
  addressed rows up to 25, a terminal clamps a row past its last line to the last line, and so the
  lower rows of the guest's screen were all drawn on top of each other there. This is the case the
  result above listed as not handled. It is inferred from the 10-line paste and from the fix
  curing a 10-row pseudo-terminal; the terminal's size at the time was not measured
- **Fix**: the console reads the terminal's size on every redraw and draws only the part of the
  80x25 screen that fits. Down the screen the view follows the guest's cursor and otherwise stays
  put; sideways it returns to column 0 whenever the cursor fits. A change of size or view clears
  and redraws
- **Test**: `tools/console_test.py` now also scrolls the guest's screen with `ls /bin`, fails if
  the console ever addresses a cell outside the terminal, and repeats the session on an 80x10 and
  a 60x12 terminal. All three sizes pass

The 60x12 run failed once before it passed: after a line longer than the view, the view stayed
shifted right and hid the `# ` prompt. That is why the sideways rule differs from the vertical one.

Still not checked on a real terminal: colours, the cursor, line-drawing characters, arrow and
function keys, and resizing the window while it runs.

### Follow-up: no way out (2026-11-12)

The second try by hand ended with "I don't know how to get out". The quit key, Ctrl-], was
mentioned in the README and nowhere on the screen.

- The way out is now shown in three places: a line printed before the console opens (held for 1.2 s
  when the terminal has no spare row, and left in the scrollback), the window title, and a dim line
  below the screen when the terminal has more than 25 rows
- Two more keys leave the console: F12 and Ctrl-\. Ctrl-] is awkward on some keyboard layouts
- The test checks the line before the console opens, the line below the screen at 100x30, and
  leaves by a different key in each of its three sessions

Adding the line below the screen turned up a bug in the previous follow-up: the first redraw did
not clear and set up the terminal unless the view differed from the default, so on a terminal of
25 rows or more nothing was cleared at the start. The first redraw now always does.

Whether Ctrl-] itself failed to reach g86m in that terminal, or was simply not known, is not
established.

## E006: Boot FreeDOS to a prompt (M3, 2026-11-12)

- **Hypothesis**: With the BIOS keyboard path completed (the INT 09h handler tracking Shift, Ctrl
  and Alt and filling the BIOS queue; INT 16h waiting idle for a key), FreeDOS 1.4
  (`fd14boot.img`, the image rustx86 boots) reaches its boot menu, starts FreeCOM, and runs `ver`
  and `dir` at the `A:\>` prompt. Unlike ELKS, FreeDOS does its screen, keyboard and disk work
  through the BIOS, so this exercises the paths E004 listed as untested.
- **What changed since last time**: The BIOS keyboard handler only handled unshifted keys and INT 16h
  spun in a loop while waiting. The script gains `\kNN` to press a key by scancode (F5 is `\k3F`).
- **Next move for each result**:
  - Reaches `A:\>` and `ver` prints a FreeDOS version → fix the script as a regression test, open
    a PR
  - Stops on an unimplemented BIOS call, port or opcode → implement it and run again
  - Stops on a 386 instruction → find out why FreeDOS thinks this is a 386 (the CPU detection
    reads the top bits of FLAGS and tries PUSH SP), fix the detection result, not the instruction
  - Hangs with no stop → compare the trace with rustx86's from the start of the disk boot
- **Cut-off**: The same day. The FreeDOS installer (which rustx86 reaches through 32-bit
  instructions) is out of scope: it needs M4.

### Result

2026-11-12. **FreeDOS reaches `A:\>` and runs commands. Next move: open a PR.**

The session presses F5 when the kernel banner appears, answers `\FREEDOS\BIN\COMMAND.COM` when
the kernel asks for the shell, and runs three commands. The screen at the end:

```
 Enter the full shell command line: \FREEDOS\BIN\COMMAND.COM
FreeCom version 0.86 - WATCOMC - XMS_Swap [Dec 30 2024 22:10:51]
A:\>ver /r
FreeCom version 0.86 - WATCOMC - XMS_Swap [Dec 30 2024 22:10:51]
DOS version 7.10
FreeDOS kernel 2043 (build 2043 OEM:0xfd) [compiled May 13 2021]
A:\>dir /w
 Volume in drive A is FD14-BOOT
 Volume Serial Number is BB79-CEB9
 Directory of A:\
KERNEL.SYS     FDAUTO.BAT     FDCONFIG.SYS   [FREEDOS]      SETUP.BAT
         4 file(s)         87,913 bytes
         1 dir(s)         807,936 bytes free
A:\>echo Done-%COMSPEC%
Done-A:\FREEDOS\BIN\COMMAND.COM
```

- It passes on the debug and release builds as a script, and through the console on a
  pseudo-terminal, where F5 is sent as the escape sequence a terminal sends for it. Both are in
  `tools/difftest.sh`, which now has 21 checks
- The M1 traces, the ELKS script and the ELKS console sessions still pass
- bench.bin: 3526–3795 ms, about 100–105 MIPS. Not distinguishable from before on three runs

As with ELKS, the kernel came up on the first run: the boot menu appeared without the machine
stopping on anything unimplemented. Two things did have to be fixed, both about keys arriving
faster than the guest takes them:

| Symptom | Cause | Fix |
|---|---|---|
| The shell path stopped at `\FREEDOS\BIN\CO` in the script | The script queued every key at once. FreeDOS reads keys through the BIOS, whose queue holds 15 | The script types one key per poll, and only once the guest has taken the last one |
| The same in the console when the path arrived in one write, as a paste does | The console passed everything it read straight on | The console keeps what it read and hands it over one key at a time |

The console change makes typing slightly slower to arrive: `sleep 3` measured from the moment the
line is written now takes 3.25 s instead of 3.04 s, because its 21 characters go in at one per
hundredth of a second.

What happens without F5, for the record:

- Enter at the language menu starts FreeCOM, which runs `FDAUTO.BAT`. That stops g86m at
  `unimplemented opcode 66 at 22c8:0759`: a 386 operand-size prefix. rustx86 gets past this point
  through its 32-bit instructions. Whether that program checks the CPU first was not looked into;
  the card's "why does FreeDOS think this is a 386" question is still open, and belongs with M4
- The menu screen shows `Singlestepping (F8) is:` with nothing after it. Not looked into

Not tested: any DOS program other than the shell's built-in commands. `dir`, `ver` and `echo` are
all inside FreeCOM.

## E007: FreeDOS without F5 (2026-11-12)

First try by hand: "FreeDOS goes down at once". Without F5 the normal startup stops g86m, and in
the console the reason is printed while the alternate screen is up, so it is never seen.

The stop is at `66 53 66 9C 66 9C 66 58 66 0D ...`: PUSH EBX, PUSHFD, PUSHFD, POP EAX, OR EAX — the
usual test for CPUID. A program only runs that after deciding the CPU is at least a 386.

- **Hypothesis**: g86m answers the two standard CPU tests inconsistently. FLAGS bits 12–15 read as
  ones, which is an 8086; but PUSH SP pushes the value from before the decrement, which is a 286 or
  later. A program that tests PUSH SP first and then finds bits 12–14 stuck at one concludes "386".
  If PUSH SP pushes the decremented value, as a real 8086 does, the program takes its 8086 path and
  FreeDOS's normal startup gets past this point.
- **What changed since last time**: E006 always pressed F5. This runs the normal startup, with PUSH
  SP changed to the 8086 behaviour. M1 followed rustx86 here (rustx86 has the same mix but
  survives because it implements the 386 instructions).
- **Next move for each result**:
  - The startup gets past the stop and reaches a prompt or the installer's first question → keep
    the 8086 PUSH SP until M4 makes the machine a real 386, move the PUSH SP case from the trace
    test to the self-check, and test the normal startup
  - It still stops on a 386 instruction → the program does not test the CPU, or tests it another
    way. Read the code before the stop to see which, and record it; the real fix is then M4
  - It stops on something else → fix that if it is small, record it if not
- **Whatever the result**: the console must show why the machine stopped after it closes.
- **Cut-off**: The same day.

### Result

2026-11-12. **The hypothesis held. FreeDOS's normal startup now reaches `A:\>` without F5.**

With PUSH SP pushing the decremented value, the program that stopped g86m takes its 8086 path:

```
Welcome to the FreeDOS 1.4 installation program.
...
Do you want to proceed [Y,N]?N
The installation of FreeDOS 1.4 has been aborted.
A:\>dir /w
 Volume in drive A is FD14-BOOT
 Volume Serial Number is BB79-CEB9
 Directory of A:\
[FREEDOS]      FDAUTO.BAT     FDCONFIG.SYS   KERNEL.SYS     SETUP.BAT
         4 file(s)         87,913 bytes
         1 dir(s)         807,936 bytes free
```

- The session is: Enter at the language menu, `n` and Enter at the installer's question, then
  `dir /w`. It is in `tools/difftest.sh` on both builds, next to the F5 session; 23 checks, all pass
- This is the first DOS program other than the shell to run: the installer front end draws its
  banner and prompt through INT 10h AH=02h/08h/09h (about 3,500, 1,000 and 1,100 calls)
- PUSH SP left the trace test (`t_misc`), because g86m no longer agrees with rustx86 there, and went
  into the self-check, which now expects the 8086 result. The other ten expected traces were
  regenerated from the oracle and came out byte for byte the same
- The console now repeats the reason the machine stopped after it closes. Nothing tests that

One wrong turn on the way: after `n` the installer seemed to hang. It was waiting for Enter. Finding
that out took a memory dump of the text screen (`--dump`, new), which showed the screen was drawn
correctly and the cursor sat right after the `N`. The stop message now also includes the bytes at
the stopping address, and `--ports` reports how often each BIOS service was called.

What this does not settle:

- Whether "goes down at once" by hand was this stop. It fits (Enter at the menu, then a stop within
  a second of guest time), but the session that failed was not captured
- PUSH SP is now the 8086 behaviour on purpose. M4 has to turn it back when the machine becomes a
  386, together with the FLAGS bits, or the same inconsistency returns the other way round
- The installer was declined. Going on with `y` was not tried

## E008: Make the machine a 386 in real mode (M4a, 2026-11-13)

M4 is split in three: (a) the 386 instruction set in real mode, (b) protected mode, (c) paging and
test386. This card is (a).

- **Hypothesis**: With 32-bit registers, the 66h/67h prefixes, 32-bit addressing with SIB bytes, FS
  and GS, and the 0Fh instructions, g86m matches rustx86's 32-bit profile line for line on the full
  32-bit state (EIP, the eight 32-bit registers, six segment registers, EFLAGS) for the existing
  eight 16-bit test programs and for new 32-bit ones. ELKS and FreeDOS still boot, and FreeDOS's
  normal startup, which now sees a 386 and takes its 32-bit path, still reaches the installer.
- **What changed since last time**: Until now g86m was an 8086 to software that asked (E007). It
  becomes a 386 without an FPU and without CPUID: FLAGS bits 12–14 are writable, PUSH SP pushes
  the value from before the decrement, and the 386 instructions exist. The oracle changes with it,
  from rustx86's default 8086 profile to its 32-bit profile, and the trace gains the upper halves
  of the registers. The expected traces are all regenerated.
- **Next move for each result**:
  - Every trace matches and both systems boot → open a PR, go on to protected mode (M4b)
  - A trace differs → fix the first line that differs. rustx86's 32-bit profile has an FPU and
    CPUID and g86m does not, so a difference in FPU instructions, CPUID, or the AC and ID bits of
    EFLAGS is expected: keep those out of the trace tests rather than following the oracle
  - FreeDOS stops on an instruction → implement it if it is a 386 instruction; if it is a 486 or
    later one, find out which CPU test said so
  - ELKS or FreeDOS behaves differently as a 386 without stopping → compare the screen with the
    8086 run and record what changed
- **Cut-off**: The same day for the instruction set. Entering protected mode stops the machine with
  a message; that is M4b.

### Result

2026-11-13. **Every trace matches and both systems boot. Next move: open a PR, then protected mode (M4b).**

`tools/difftest.sh` has 31 checks and all pass on the debug and release builds.

| Test | Lines | Contents |
|---|---:|---|
| The eleven 16-bit traces from M1 | as before | Regenerated on the 32-bit oracle; they matched on the first run, before any 32-bit test existed |
| u_alu | 590 | The 8 operations and TEST on 32-bit registers, memory and immediates; INC / DEC / NEG / NOT |
| u_shift | 1393 | 32-bit rotates and shifts; SHLD / SHRD at 16 and 32 bits × 11 counts |
| u_muldiv | 328 | 32-bit MUL / IMUL / DIV / IDIV with divide errors; two- and three-operand IMUL; CWDE / CDQ |
| u_addr | 75 | Every ModR/M and SIB shape through LEA; default segments of the 32-bit forms |
| u_misc | 365 | MOVZX / MOVSX, 16 SETcc × 10 flag words, near Jcc, BT / BTS / BTR / BTC, BSF / BSR, FS / GS, LSS / LFS / LGS |
| u_stack | 114 | PUSHAD / POPAD, PUSHFD / POPFD, 32-bit ENTER / LEAVE, string instructions with either size prefix, LOOP / JECXZ by address size, 32-bit CALL / RET, XLAT, SMSW, SIDT |
| s_386 | - | Self-check for three cases where g86m follows the Intel manual and rustx86 does not |

ELKS and FreeDOS need no change to their scripts: the ELKS shell session, FreeDOS's normal startup,
the F5 path and all four console sessions pass as before. FreeDOS's normal startup now runs the code
that stopped g86m in E007 (PUSHFD and friends) instead of avoiding it.

Of the six new tests, three matched on the first run (u_alu, u_addr, u_muldiv). The other three:

| Mismatch | Cause | Fixed in |
|---|---|---|
| OF after SHLD / SHRD | A real 386 leaves OF alone; g86m set it on a count of 1 | g86m |
| EBP after a 32-bit ENTER | With a 16-bit stack the frame pointer is BP: only the low half of EBP is written | g86m |
| CR0 read by SMSW | g86m started CR0 with the ET bit set; with no coprocessor it is clear | g86m |

The tests had one bug: `o32 call label` in NASM adds the prefix but keeps a 16-bit displacement, so
the call went into data. `call dword label` is the form that works.

Where g86m and rustx86 disagree and g86m was not changed (all three are in `s_386` instead of a
trace, and listed in [goose-notes.md](goose-notes.md)):

- BT-family instructions with an immediate bit offset above the operand size, on memory
- BT-family instructions with a negative 16-bit register bit offset
- IRETD in real mode

Speed: bench.bin takes 4613–4764 ms on the release build = **about 78 MIPS**, down from about 105.
Every instruction now resets and tests the operand and address sizes, and register and memory
access go through a width that can be 8, 16 or 32.

What was not done:

- **The screens were not compared.** The card said to compare ELKS's and FreeDOS's screens as a 386
  against the 8086 run. Only the scripted waits were checked; they pass, but a message that changed
  would not be noticed
- **No CPUID and no FPU.** rustx86's 32-bit profile has both; g86m answers as a 386
  without them, so instructions that touch them are kept out of the traces
- **Real mode is not checked for limits.** Offsets above FFFFh and a 32-bit EIP do not fault
- **Protected mode stops the machine.** Setting CR0.PE by MOV CR0 or LMSW prints a message and
  stops. LGDT and LIDT only store their operand
- **Instructions in the two-byte range that no test reaches**: MOV to and from debug registers, CLTS,
  INS / OUTS

## E009: Run test386 (M4b, 2026-11-13)

test386.asm is a ROM that replaces the BIOS, tests a 386 instruction by instruction, reports
progress as codes on a diagnostic port, and halts at the first failure. Its last stage prints
44,926 lines of results, to be compared with a reference taken from real hardware.

Reading its README changed the plan: it enters protected mode with paging already on (code 08h),
and goes on to ring 3, virtual-8086 mode, page faults and task switches. So "protected mode" and
"paging" cannot be separate steps for this test; M4b and M4c are one piece of work, measured by how
far the codes get.

- **Hypothesis**: (1) With a ROM boot mode and the diagnostic and serial ports, the real-mode stages
  (codes 00h–06h) pass on the M4a build as it is. (2) With protected mode, paging, faults with error
  codes, privilege changes, virtual-8086 mode and task switching added, the ROM reaches code FFh and
  its serial output matches the reference on every line.
- **What changed since last time**: M4a stopped the machine when CR0.PE was set. The ROM is built
  from barotto/test386.asm at commit cfd052d with `COM_PORT equ 1`, as rustx86's fetch script
  does. It is not in the repository (GPL-3.0).
- **Next move for each result**:
  - A real-mode stage fails → that is an M4a bug the traces did not catch. Find the instruction
    from the listing file and the last trace lines, fix it, add the case to a trace test
  - Stops at 08h on "protected mode is not implemented" → the expected starting point. Implement
    in the order the ROM needs: descriptor loading and CR0.PE, then paging, then interrupts through
    the IDT, then privilege changes, then virtual-8086 mode
  - Halts at a later code → read that stage's source, compare the trace with rustx86's from the
    same ROM, fix the first difference
  - Reaches FFh but the output differs from the reference → fix by the first differing line; the
    reference masks undefined flags, so every difference is a real one
- **Cut-off**: Each code reached is recorded. If the day ends before FFh, the PR says which code
  it stops at and why.

### Result

2026-11-13. **Both halves of the hypothesis held. test386 reaches code FFh and its output matches the
reference on every byte.**

```
post 00 01 02 03 04 05 06 08 09 20 21 22 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c e0 ee ff
```

- The serial output is 44,926 lines, 3,548,969 bytes, and `cmp` finds no difference from
  `test386-EE-reference.txt`. The debug and the release build give the same result
- 104,513,187 instructions; 3.2 s on the release build, 31 s on the debug build
- It is in `tools/difftest.sh` on both builds, which now has 33 checks; all pass. A missing ROM is
  reported as skipped
- ELKS, FreeDOS and the seventeen traces still pass

How it went, by the code the ROM stopped at:

| Stopped at | Cause | Fix |
|---|---|---|
| 08 | Expected: protected mode did not exist | Descriptor caches with limits and rights, CR0.PE, paging, fault delivery, privilege changes, virtual-8086 mode (`src/prot.goose`, and most of `src/state.goose`) |
| 09 | A timer interrupt arrived as soon as the ROM ran STI. The ROM replaces the BIOS, so nothing had set up the interrupt controller, but g86m started it as the BIOS leaves it | In ROM mode the controller starts fully masked and the timer stopped |
| 12 | `LOCK MOV` must be an invalid opcode. g86m ignored the LOCK prefix | LOCK is accepted only on the instructions that may take it, with a memory destination |
| 1A | `ENTER` with a 32-bit operand on a 16-bit stack: the frame pointer pushed for nested levels is the raw ESP, upper half included, and the new top of stack is probed for writing | Followed rustx86, which had worked both out against this same stage |
| FF, output one byte long | The serial port's baud-rate divisor was recorded as a byte sent | The data register is the divisor while the divisor latch is open |

Stages 09, 20 (ring 3), 21 (virtual-8086 mode), 0B–11 (including page faults) and 13–19 passed the
first time they were reached. The trace comparison against rustx86 that the card planned for a halt
was not needed: each stop was found from the listing file and the last lines of g86m's own trace.

How faults are done: a fault abandons the instruction from wherever it is found. `raise` records
the fault and uses Goose's long-distance return (`return false from exec_one`) to leave every
frame in between; `step` then restores the registers saved at the start of the instruction and
delivers the fault. The compiler checks that every function that can fault is only ever called
inside `exec_one`. That check caught one real mistake in the design before it ran: interrupts were
delivered from the run loop, outside `exec_one`, where a fault in the delivery had nowhere to go.
Delivery moved inside. (Notes on this are in [goose-notes.md](goose-notes.md).)

One of g86m's own tests had to change. `u_stack` used a repeat count above FFFFh with a 32-bit
address size in real mode, which runs past the 64 KB segment. rustx86 allows it; g86m now raises a
general protection fault, as a 386 does. The count was reduced.

Speed: bench.bin takes 6966–7156 ms on the release build = **about 52 MIPS**, down from about 78.
Each instruction now copies the CPU state for a possible fault, each memory access checks its
segment's limit and rights, and every call that can fault tests a flag on return. Nothing was done
to win any of it back.

What this does not cover:

- **Task switching.** A task gate, a jump or call to a task segment, and IRET with NT set stop the
  machine with a message. test386 only tests them in its 128 KB build, which was not used; code
  22h appears in the trail above because the 64 KB build passes through that stage without testing
- **There is no TLB.** Every access walks the page tables. Software that depends on a stale
  translation surviving until it reloads CR3 would see different behaviour; test386 does not
- **Memory is still 1 MB** and physical addresses wrap there. test386 stays inside it
- **Debug registers, the single-step trap, and the resume flag** are not implemented
- **Hardware interrupts in protected mode** go through the same delivery code but no test raises one

## E010: Where the interpreter's time goes (2026-11-13)

Speed fell from about 105 MIPS (M3) to about 78 (M4a) to about 52 (M4b) with nothing done to win it
back, and Linux will need on the order of a billion instructions to boot.

Baseline on the release build, median of five runs:

| Benchmark | What it is | Time | Speed |
|---|---|---:|---:|
| bench.bin | 369,095,178 instructions, a 10-instruction loop in 16-bit real mode | 6934 ms | about 53 MIPS |
| test386 | 104,513,187 instructions, mostly 32-bit protected mode with paging | 3160 ms | about 33 MIPS |

- **Hypothesis**: Most of the time is in a few fixed costs paid on every instruction or every memory
  access, not in the instructions themselves. The candidates, in the order I expect them to matter:
  (1) copying the whole CPU state at the start of every instruction for a possible fault,
  (2) fetching code one byte at a time through the limit check and the paging check,
  (3) writing six flags to memory after every arithmetic instruction,
  (4) the page-table walk on every access when paging is on (test386 only).
- **What changed since last time**: Nothing in the code. This card profiles before changing
  anything, because E002 guessed at a cause and never confirmed it.
- **Next move for each result**:
  - The profile shows one of the candidates on top → fix that one first, measure both benchmarks,
    run the whole suite, then profile again
  - The profile is flat (no function above about 15%) → the cost is spread through the main
    dispatch function and a profile by function cannot split it; switch to removing one candidate
    at a time and measuring the difference
  - A fix gives less than 5% on both benchmarks → take it out again unless it makes the code simpler
- **Cut-off**: The same day. The goal is not a number; it is to know what the fixed costs are and to
  remove the ones that are cheap to remove. Every change must leave `tools/difftest.sh` at 33 of 33.

### Result

2026-11-13. **The hypothesis was half right: the time is in fixed per-instruction costs, but not the
ones I listed first.** Release build, median of five runs:

| Benchmark | Before | After | Change |
|---|---:|---:|---:|
| bench.bin (real mode) | 6934 ms, about 53 MIPS | 5531 ms, about 67 MIPS | 20% less time |
| test386 (protected mode, paging) | 3160 ms, about 33 MIPS | 1946 ms, about 54 MIPS | 38% less time |

`tools/difftest.sh` is at 33 of 33 after the changes, and test386's output is still byte for byte
the reference.

What the measurements said, in the order they were taken:

| Step | bench | test386 | Kept |
|---|---:|---:|---|
| Baseline | 6934 | 3160 | |
| Ablation: no state copy per instruction (not correct) | 6829 | - | no: 1.5%. Candidate (1) was wrong |
| Ablation: arithmetic sets only ZF and CF (not correct) | 6754 | - | no: 2.6%. Lazy flags would not pay; candidate (3) was wrong |
| Code page cache: translate once per page of code, read bytes directly | 6744 | 2388 | yes |
| Two-level opcode dispatch | 5866 | 2059 | yes |
| Big arrays declared last; three tests before the prefix loop | 5423 | 2089 | yes |
| One-entry caches for data reads and writes | 5559 | 1925 | yes: 8% on test386, within noise on bench |

The profile by function was the flat case the card allowed for: 53% in `exec_one` itself, which a
function profile cannot split. What broke it open was counting host instructions. A loop of NOPs
ran at 16 ns per instruction, and `/usr/bin/time -l` reported 104 billion host instructions for 400
million NOPs: **261 host instructions per NOP**. Stepping one NOP in the debugger and listing what
ran showed a long straight line of code, no loop, and three causes:

- **Goose compiles an integer `match` to a chain of comparisons**, and clang turns such a chain
  into a jump table only when the arms are plain values. The opcode `match` had ranges
  (`0x40..0x48`), so it stayed a chain: an opcode near the end paid for every arm before it.
  Matching first on `op >> 4` (sixteen plain values, which does become a jump table) and then
  within the row cut that to a dozen comparisons at most
- **Every instruction byte went through four calls** (`fetch8`, `lin_read`, `translate`, and a
  checked division by 8 for the width). Each call that can fault also tests a flag on return
- **Globals after the 1 MB RAM array were more than a megabyte from the start of the block**, so
  each access to the CPU state took three instructions instead of one. Goose lays globals out in
  the order their files are first imported; moving the big arrays to a file imported last put the
  state near the start

After the changes a NOP costs 209 host instructions in all, 146 of them inside `exec_one`.

What this leaves:

- **The fixed cost is still about 200 host instructions per guest instruction.** What remains is
  the per-instruction prologue (saving a dozen registers, resetting the decode state, the checks
  for a pending fault, an interrupt and a BIOS entry), about 58 instructions in the run loop
  (the state copy, the timer countdown, the trace and script checks), and the opcode body
- **The lasting fix is not to decode every time.** rustx86 got its speed from a cache of decoded
  instructions; g86m decodes from bytes on every execution. That is a design change, not a tweak
- **E002's question is still open**: nothing here tested whether byte writes to RAM make the
  compiler reload the CPU state
- The caches were checked by test386 and the two operating systems, but no test changes a page
  table entry and then relies on the old translation, which is what a cache makes possible

## E011: Load a Linux kernel and see how far it gets (M5a, 2026-11-13)

M5 is the last stage: 32-bit Linux with a busybox shell. rustx86's record of the same stage says it
took five things: memory beyond 1 MB, a boot path that loads the kernel directly instead of going
through a BIOS, a CPU that answers as an i686 (CPUID, TSC, CMPXCHG8B, CMOV and the 486's
instructions), an x87 FPU (the kernel will not start without one), and a serial port for the
console. The FPU is the largest.

This card is the first three that need no CPU work: memory, the boot path and the serial port.

- **Hypothesis**: With 128 MB of RAM, the Linux boot protocol's 32-bit entry (kernel at 1 MB, zero
  page with the memory map, command line and initramfs, flat segments, ESI pointing at the zero
  page) and a 16550 serial port, the kernel (Alpine's Linux 6.18, `vmlinuz-lts`, the one rustx86
  boots) decompresses itself and starts. It then stops at the first thing a 386 without an FPU
  lacks, and the stop names it.
- **What changed since last time**: Until now memory was 1 MB and wrapped there. The machine keeps
  its 16-bit behaviour (wrap at 1 MB, BIOS services) for boot sectors, floppies and ROMs; a Linux
  kernel image gets the 32-bit machine.
- **Next move for each result**:
  - Stops on an unimplemented opcode or an invalid-opcode fault in the kernel → list what it
    needed; that list is the work for the CPU step (M5b)
  - The kernel prints that the CPU is too old or has no FPU → the same, and the message goes in
    the record
  - Hangs or faults before printing anything → the decompressor ran wrong. It is plain 386 code,
    so that is a bug test386 did not catch: compare the trace with rustx86's from the entry point
  - Reaches user space → not expected; if it happens, measure the instruction count and the time
- **Cut-off**: The same day. The PR records where it stops; it does not have to boot.

### Result

2026-11-13. **The hypothesis held. The kernel decompresses itself, starts, and stops at the first
486 instruction.**

```
g86m: fault 6 at 0060:c4a53859  bytes: f0 0f b1 13 75 11 8b 5d fc c9
g86m: fault 6 at 0060:c412ccf6  bytes: f0 0f b1 73 0c 0f 85 47 02 00
steps 393939741 halted true fault false ms 8809 at 0060:c409aeba
```

- `F0 0F B1` is `LOCK CMPXCHG`, an instruction the 486 added. g86m raises an invalid-opcode fault,
  as a 386 would; the kernel's early fault handler uses the same instruction and faults again,
  then halts
- By then the kernel has run 393,939,741 instructions: the decompressor, and the kernel proper at
  virtual address C0000000h and up with paging on. Nothing in those 394 million instructions
  stopped on something unimplemented or went visibly wrong, though with no output there is no
  proof it went right either
- It printed nothing, even with `earlyprintk=serial`: it stopped before the serial console was
  set up
- 8.8 s on the release build, about 45 MIPS for this stretch
- `tools/difftest.sh` is still at 33 of 33; bench.bin is unchanged at about 5.4 s

Two debugging options were added on the way and are staying: `--trace-after N` starts the trace
late in a run (the first attempt to see why the kernel halted would have written 394 million trace
lines), and `--faults` reports every fault except page faults.

What this leaves for the CPU step (M5b), from rustx86's record and this run:

- `CMPXCHG` first, then the rest of what a kernel built for i686 uses: `XADD`, `BSWAP`, `INVLPG`,
  `WBINVD`, the WP bit in CR0, the AC and ID bits in EFLAGS, `CPUID`, `RDTSC`, `CMPXCHG8B`, `CMOVcc`,
  and `RDMSR` / `WRMSR` answering with a general protection fault
- After that the FPU (M5c)

Not looked at: memory use. A run now holds about 270 MB resident, for 128 MB of guest RAM.

## E012: Make the 32-bit machine an i686, and see what the kernel wants next (M5b, 2026-11-13)

- **Hypothesis**: With the instructions the 486, the Pentium and the P6 added (`CMPXCHG`, `XADD`,
  `BSWAP`, `INVLPG`, `WBINVD`, `CPUID`, `RDTSC`, `CMPXCHG8B`, `CMOVcc`, the long NOP), the WP bit
  in CR0, the AC and ID bits in EFLAGS, and `RDMSR` / `WRMSR` answering with a general protection
  fault, the kernel gets past `LOCK CMPXCHG`, sets up its serial console, and prints. It then
  stops for want of an FPU, and says so.
- **What changed since last time**: E011's machine was a 386. The identity now depends on what is
  booted: a Linux kernel gets an i686 (CPUID family 6, with TSC, CX8 and CMOV, and not yet FPU);
  boot sectors, floppies and ROMs keep the 386, so that FreeDOS and ELKS see what they saw
  before (E007 is what happens when the answers to CPU tests do not agree). The 32-bit machine
  also runs its timer at 64 instructions per tick, rustx86's ratio, instead of 4.
- **Next move for each result**:
  - The kernel prints and stops asking for an FPU → open a PR; the FPU is the next step (M5c)
  - It stops on another instruction → add it if it belongs to these CPU generations, and note it
  - It prints but then hangs or panics for a reason that is not the FPU → read the message; if it
    is about time (calibration, a clock source), look at the timer ratio and the TSC first
  - Output looks wrong (garbled, repeated) → the serial port's interrupts; check with rustx86's
    output for the same kernel
- **Cut-off**: The same day. The new instructions get trace or self-check tests before the PR,
  whatever the kernel does.

### Result

2026-11-13. **The hypothesis held. The kernel prints its log on the serial console and stops for
want of an FPU, saying so.**

```
[    0.000000] Linux version 6.18.35-0-lts (buildozer@build-3-24-x86) (cc (Alpine 15.2.0) 15.2.0, ...
[    0.000000] BIOS-e820: [mem 0x0000000000100000-0x0000000007ffffff] usable
[    0.000000] 128MB LOWMEM available.
[    0.000000] Checking if this processor honours the WP bit even in supervisor mode...Ok.
[    0.000000] printk: legacy console [ttyS0] enabled
[    2.756672] APIC: Keep in PIC mode(8259)
[    2.757181] Calibrating delay loop (skipped), value calculated using timer frequency.. 152.72 BogoMIPS (lpj=76362)
[    2.760411] x86/fpu: Giving up, no FPU found and no math emulation present
```

About a hundred lines of kernel log come out before it gives up. `tools/difftest.sh` now has 37
checks, all passing: a trace test for the new instructions (`v_686`, 386 lines, matched rustx86 on
the first run), a self-check for what the i686 says about itself (`s_686`), CPUID being an invalid
opcode on the 386 (added to `s_386`), and the kernel reaching its version line.

It stopped once on the way, and not where the card expected:

| Symptom | Cause | Fix |
|---|---|---|
| The log stopped after `APIC: Keep in PIC mode(8259)` and the kernel ran on to the instruction limit | It was calibrating the TSC against timer channel 2: it loads a count, then polls port 61h for the channel's output bit. g86m had no channel 2 and that bit never came on | Channel 2 counts from the virtual time it was loaded at; port 61h reports its output |

The card's guess for a hang was "the timer ratio and the TSC", which pointed at the right
neighbourhood; the listing of what the kernel does at that point (from its source, `pit_calibrate_tsc`)
named the port.

What the log shows that is not right yet, none of it stopping the boot:

- `unchecked MSR access error: WRMSR to 0x8b` and `RDMSR from 0x8b`, twice, with call traces: the
  microcode-revision probe. g86m answers with a general protection fault, as rustx86 does; the
  kernel reports it and carries on
- `x86 CPU feature dependency check failure: CPU0 has 'cmov' enabled but 'fxsr' disabled`: the
  feature set claimed (TSC, CX8, CMOV) is not one any real CPU had
- `tsc: Fast TSC calibration failed`: expected; the slow method then works
- `Unable to read current time from RTC`: there is no CMOS clock

Not done: nothing here measures whether the instructions run correctly inside the kernel beyond
the kernel's own behaviour. `v_686` covers them in real mode only.

## E013: An x87 FPU backed by f64, and boot Linux to a shell (M5c, 2026-11-14)

- **Hypothesis**: The FPU is the last thing between the kernel and user space. With an x87
  whose registers are `f64` (what rustx86 did), the FPU bit claimed in CPUID and the ET bit set
  in CR0, the 6.18 kernel gets through its FPU set-up, unpacks the initramfs, and busybox gives
  a shell prompt on the serial console.
- **What changed since last time**: E012's machine skipped the operand of every escape opcode
  (D8 to DF) and said it had no FPU. Now the i686 executes them: the register stack, the control,
  status and tag words, loads and stores in the three real and three integer formats, arithmetic
  and comparison, the transcendental instructions through libm, and FNSAVE/FRSTOR. Device-not-
  available (vector 7) is raised when CR0 has EM or TS set. The 386 machine is left as it was.
  Rounding control is honoured: directed rounding is made from the sign of the exact residual, as
  rustx86 does. Extended precision is not: a register holds 53 bits of mantissa, not 64, except
  that an 80-bit value loaded and stored again untouched keeps all its bits.
- **Next move for each result**:
  - A shell prompt → run `echo`, `ls`, `uname -a`, and the two commands rustx86's history says an
    absent FPU breaks (`sleep 3` taking three seconds of guest time, `printf '%f' 3`); add a
    scripted session to `tools/difftest.sh`; open a PR
  - The kernel stops on an instruction g86m does not have (FXSAVE, an SSE one, a missing x87
    one) → add it if a P6 without SSE would have it; if the kernel wants FXSR, read why it thinks
    the CPU has it before adding anything
  - The kernel panics or hangs before user space → read the message; the candidates in order are
    the FPU self-test (`fpu__init_check_bugs`, the FDIV check), the missing CMOS clock, and the
    interrupt controller
  - User space starts but a program misbehaves → trace the escape opcodes it runs, compare the
    same sequence against rustx86 with a trace test
- **Cut-off**: The same day. Whatever the kernel does, the FPU gets trace tests against rustx86
  (results stored to memory and loaded into integer registers, since the trace has no FPU
  state) and a self-check before the PR.

### Result

2026-11-14. **The hypothesis held on the first boot. The kernel finishes, unpacks the initramfs,
and busybox gives a shell on the serial console.** About 1.9 billion instructions and 41 seconds
of host time from the kernel's first instruction to the prompt.

```
[    2.760645] x86/fpu: x87 FPU will use FSAVE
[   11.082721] Run /init as init process
~ # uname -a
Linux (none) 6.18.35-0-lts #1-Alpine SMP PREEMPT_DYNAMIC 2026-06-09 12:34:47 i686 Linux
~ # cat /proc/uptime; sleep 3; cat /proc/uptime
13.69 0.07
16.72 3.06
~ # grep flags /proc/cpuinfo
flags		: fpu tsc cx8 cmov cpuid
```

No instruction was missing: the kernel is content with FSAVE and never asked for FXSAVE or SSE.

What was added besides the FPU, because a shell that cannot be typed at proves little:

- A serial console. Started from a terminal with a kernel image, g86m puts the terminal in raw
  mode and connects it to the guest's serial port, paced against real time; Ctrl-] leaves
- `--wait` and `--type` act on the serial port when the guest's console is one. A wait looks only
  at output that came after the previous wait matched

`tools/difftest.sh` now has 43 checks, all passing. New: three trace tests of the FPU against
rustx86 (`v_fpu1` to `v_fpu3`, 363 lines; the first two matched on their first run), a self-check
for what rustx86 cannot judge (`s_fpu`), a scripted Linux session (uname, `printf '%f' 3`, awk's
square root and arctangent, `sleep 3` taking three seconds of guest time), and the serial console
driven through a pseudo-terminal (`sleep 3` took 3.06 s of real time).

Two things were wrong on the way:

| Symptom | Cause | Fix |
|---|---|---|
| awk printed `atan2(1,1)*4` as 0 | For the D9 F0 to FF instructions the r/m field is part of the opcode; the code took it as a register number and used ST(3) where FPATAN means ST(1). The same slip was in FYL2X, FYL2XP1, FPREM, FPREM1 and FSCALE | They read ST(1) |
| `v_fpu3` differed from rustx86 at one line | `FLD ST(0)` of an 80-bit value: g86m copies all 64 mantissa bits, rustx86 keeps 53. g86m is the one that matches real hardware | The test stores the value without copying it; the copy is checked in `s_fpu` |

**What is wrong, and known: floats are printed truncated, not rounded.**

```
~ # printf '%f %g %e\n' 3 0.1 12345.678
3.000000 0.0999999 1.234567e+04
```

The right answers are `0.1` and `1.234568e+04`. musl's printf decides whether to round the last
digit up by adding a small number to 2^64 and seeing whether the sum changed. With the 64-bit
mantissa of a real x87 it changes; with the 53 bits of an f64 it never does, so nothing is ever
rounded up. This is the cost of the f64 registers that the card accepted, and it is larger than
the card thought: not "the last bits of a long double" but the last digit of every printed float.
rustx86 has the same registers and by the same reasoning the same answer; that was not run.
The fix is arithmetic on the 80-bit format itself (add, subtract, multiply, divide, square root
in integers, 64 bits of mantissa), with f64 kept only for the functions that go through libm.

Not done, and not needed to get here: FBLD and FBSTP (the machine stops and says so if one is
met), floating-point exceptions (none is ever raised), the instruction and operand pointers in
the saved environment (written as zero), FXSAVE and SSE, a disk, a network card, a clock chip.
Whether FCOMI on real hardware clears OF, SF and AF was not checked; g86m leaves them, as
rustx86 does.

## E014: Arithmetic on the 80-bit format, so that printf rounds (M5d, 2026-11-14)

- **Hypothesis**: The truncated floats of E013 come from one thing only: results of FPU
  arithmetic are cut to the 53 mantissa bits of an f64. If add, subtract, multiply and divide are
  done in integers on the 80-bit format (64 bits of mantissa, rounded as the control word says),
  comparison looks at all 80 bits, and conversion to and from 64-bit integers is exact, then
  `printf '%g %e' 0.1 12345.678` in the guest prints `0.1 1.234568e+04`.
- **What changed since last time**: E013 computed every result as an f64. Now a result of the four
  operations is an 80-bit value; f64 is used only where an operand is not an ordinary number (zero
  times something, infinity, NaN, a denormal), where the result leaves the exponent range, for the
  square root, and for the functions that go through libm. The trace tests set the precision
  control to 53 bits, where rustx86's f64 arithmetic is the right answer, so they stay comparable.
- **Next move for each result**:
  - printf prints both numbers rounded → add them to the scripted Linux session, add a self-check
    for 64-bit results (1/3, 1 + 2^-63, 2^64 + 1.5, a 64-bit integer through the stack), open a PR
  - Still truncated → trace the escape opcodes of that printf (a `--trace-after` run filtered to
    D8-DF) and find which instruction in musl's rounding test still loses bits; the candidates
    are the comparison and the load of the `2/LDBL_EPSILON` constant
  - Rounded, but another program's output changes for the worse → compare that sequence at 53-bit
    precision against rustx86 to tell a new bug from a precision difference
- **Cut-off**: The same day. If the integer arithmetic cannot be made to agree with rustx86 at
  53-bit precision on the existing three trace tests, it does not go in.

### Result

2026-11-14. **The hypothesis held. printf rounds.**

```
~ # printf '%f %g %e %.17g\n' 3 0.1 12345.678 0.1
3.000000 0.1 1.234568e+04 0.10000000000000001
~ # awk 'BEGIN{print 1/3, sqrt(2), exp(1), atan2(1,1)*4, 2^0.5, int(-3.7), 1e300*1e10, 0.1+0.2}'
0.333333 1.41421 2.71828 3.14159 1.41421 -3 inf 0.3
```

It worked on the first build that compiled; nothing had to be traced.

At 53-bit precision the integer arithmetic agrees with rustx86 on all three trace tests (365
lines), including the three directed rounding modes and 24-bit precision, which rustx86 gets from
the residual and g86m now gets from the bits themselves. To make the comparison fair the tests
set the precision control to 53 bits and no longer do arithmetic on the built-in constants.

`tools/difftest.sh` has 45 checks, all passing. New: `s_fpu80`, a self-check for results that
need 64 bits (1/3 to nearest, rounded down, and at 53 bits; (1/3) * 3 = 1; 1 + 2^-63; 2^64 + 1.5
against 2^64 at both precisions; a 64-bit integer through the stack), and the two printf answers
in the scripted Linux session. Boot time is unchanged (41.5 s to the shell).

What still goes through f64, with 53 bits: the square root, the functions computed by libm
(sine, cosine, tangent, arctangent, the logarithms, 2^x - 1), FPREM and FPREM1, the built-in
constants (pi and the logarithms are loaded as f64 values, 11 bits short), a store to a 32-bit
real (rounded twice: to f64, then to f32), and arithmetic on denormals or with a result outside
the exponent range. No guest program was seen to depend on any of these.

## E015: Where the Linux boot spends its time (2026-11-14)

- **Hypothesis**: Under Linux the three one-entry translation caches of E010 miss far more often
  than under test386, and each miss walks the two-level page table (two memory reads, four
  checks, two possible writes). test386 runs in a handful of pages; a kernel alternates between
  its code, its stack and data spread over many pages, and a one-entry cache keeps only the last.
  If so, more than one translation per ten instructions is a miss, and a real TLB (a few hundred
  entries, direct-mapped, separate for reads and writes) removes most of them.
- **What changed since last time**: E010 measured bench.bin and test386. This measures the
  workload that matters now: the boot to the busybox prompt (about 1.9 billion instructions,
  41 s, about 46 MIPS, where test386 runs at 54). First with counters, not with a fix: misses per
  instruction for code, reads and writes, and a host profile by function of the same run.
- **Next move for each result**:
  - Misses are above 0.1 per instruction → build the TLB; flush it where the one-entry caches are
    flushed now; measure the boot again
  - Misses are rare (below 0.02 per instruction) → the hypothesis is wrong; go by the host
    profile: if a function other than `exec_one` holds more than 15%, look there; if it is flat,
    count host instructions per guest instruction on the hottest guest loop, as E010 did
  - The boot spends a large share of its instructions waiting (calibration loops, delay loops,
    the idle loop not halting) → that is not interpreter speed; look at how virtual time advances
    (the 64 instructions per timer tick) before touching the interpreter
  - A fix gives less than 5% on the boot → take it out again unless it makes the code simpler
- **Cut-off**: The same day. `tools/difftest.sh` stays at 45 of 45, and test386's output byte for
  byte the reference, after every change that is kept. No decoded-instruction cache in this
  round: that is a design change and gets its own card.

### Result

2026-11-14. **The hypothesis was wrong about the cost. The page-table walks were as frequent as
predicted and nearly free; the time was in calls.** Release build, same machine, same day:

| Benchmark | Before (main) | After | Change |
|---|---:|---:|---:|
| Linux boot to the shell prompt, 1,651,240,001 instructions | 43.3 s, 750 billion host instructions | 32.3 s, 584 billion | 25% less time |
| test386 | 2284 ms, about 46 MIPS | 1511 ms, about 69 MIPS | 34% less time |
| bench.bin (real mode) | 5919 ms, about 62 MIPS | 4449 ms, about 83 MIPS | 25% less time |

The boot runs the same number of guest instructions before and after, to the last one: none of
this changed what the guest sees. `tools/difftest.sh` is at 45 of 45 and test386's output is
byte for byte the reference.

What was measured, in order:

| Step | Linux boot | Kept |
|---|---:|---|
| Baseline, with counters: 0.12 page-table walks per instruction | 44.3 s | |
| A TLB: 256 entries each for reads and writes, for supervisor and user. Walks fell from 197 million to 4.9 million | 44.0 s | yes, see below |
| 16- and 32-bit memory accesses and instruction operands taken at once, not byte by byte | 41.9 s | yes |
| Globals reordered and padded so that the CPU state is aligned (tried eight paddings) | 1.5% fewer host instructions on a micro-benchmark | no |
| The run loop works out the next event (timer, script, limit) and runs to it, instead of testing for each after every instruction | 39.4 s | yes |
| `inline fn` on the small helpers of the instruction path | 32.0 s | yes, all but one |

- **The TLB was what the card predicted would help, and at first it did nothing**: forty times
  fewer walks, the same time. A walk is two memory reads and a few tests; 0.12 of them per
  instruction is about ten host instructions out of 450. Measured again at the end, with the
  other costs down, the TLB is worth 2.6% of the host instructions and about 4% of the time. It
  stays: it is small, and it removes the flush of every cached translation at each change of
  privilege level
- **What broke it open was the same thing as in E010: counting.** `/usr/bin/time -l` said 447
  host instructions per guest instruction for the boot. A loop of one instruction in 32-bit
  protected mode (`probe/bench32.asm`) said about 230 of those are there for a NOP: the fixed
  cost. Stepping one guest instruction in the debugger and listing what ran gave 227 host
  instructions: 101 in `exec_one`, 56 in the run loop, 48 in `fetch8` for one byte, 22 in the
  two register accessors
- **The small helpers were not being inlined**, neither by Goose nor by clang, which stops once
  the caller is as big as `exec_one`. Every `fetch8`, `regw`, `seg_read` was a call: registers
  saved and restored, and after each call that can fault, a test of the fault flag. `inline fn`
  on 57 helpers took the guest instruction above from 227 host instructions to 156 and the boot
  from 678 to 554 billion
- **Inlining everything costs build time.** With `decode_modrm` inlined too the binary is 859 KB
  and a release build takes 15 s, against 199 KB and 1.4 s before. Leaving that one function as
  a call gives 413 KB and 4.7 s, and the boot is within 2% (32.3 s against 32.0 s). That is
  what was kept
- **Alignment was a wrong guess.** Goose packs globals with no padding, so 32-bit fields sit at
  odd addresses and arm64 needs a separate add to reach each one. Lining them up changed the
  count by 1.5%: the add is there, but it is one instruction among hundreds

What this leaves: a NOP still costs about 150 host instructions. What remains is spread thin:
saving and restoring registers around `exec_one` (14), the checks for a pending fault, an
interrupt and a BIOS entry (12), resetting the decode state (14), fetching the opcode byte
(about 35), the prefix and LOCK tests (10), the dispatch (10), and the copy of the CPU state in
the run loop (13). The next step that is not thin is the one this card excluded: not decoding
the same instruction again every time it runs.

### Addendum: with build time no object

2026-11-14. The owner's answer to the build-time trade-off above was to ignore it: pick what runs
fastest. So the options that had been held back, or not tried because they cost build time, were
measured. Median of three runs each; the kept configuration is the first row.

| Variant | Binary | bench.bin | test386 | Linux boot |
|---|---:|---:|---:|---:|
| Kept: 57 helpers inline, `decode_modrm` a call | 413 KB | 4423 ms | 1521 ms | 32.2 s |
| `decode_modrm` inline as well | 859 KB | 5677 ms | 1418 ms | 31.9 s |
| `decode_modrm` inline for 32-bit addressing, a call for 16-bit | 760 KB | 5769 ms | 1493 ms | 33.1 s |
| Kept, compiled with `-O3` | 428 KB | 4471 ms | 1419 ms | 32.2 s |
| Kept, with `-O3 -mcpu=native` | 428 KB | 4533 ms | 1537 ms | 32.7 s |
| Kept, with a profile of the Linux boot (`-fprofile-instr-use`) | 424 KB | 4952 ms | 1517 ms | 32.5 s |

**Nothing here is faster where it counts.** Inlining `decode_modrm` is 1% on the boot, which is
inside the run-to-run spread, and costs 28% on the real-mode benchmark; splitting it was worse on
all three. The compiler's own options do nothing: `-O3`, tuning for this CPU and a profile of the
boot all land within the noise on the boot, and the profile makes the real-mode benchmark slower.
(The two `-O3` rows are the same size; test386 differs by 8% between them, which is the size of
the noise on that benchmark and the reason the boot is the one to go by.)

The flags were passed through `goose build --cc` with a wrapper script that appends them after
Goose's own `-O2`. The wrapper is not kept, since none of its uses was.

So the configuration stays as it was. Being allowed to spend build time buys nothing at this
point; the interpreter's remaining cost is in what it does for each instruction, not in how well
that is compiled.

## E016: Check the instruction bytes once per instruction, not once per byte (2026-11-14)

- **Hypothesis**: After E015 a guest instruction still pays for each byte it fetches: a segment
  limit test, a page comparison, a physical-address mask and a RAM range test, and a wrap test on
  the instruction pointer, about 35 host instructions for the opcode byte alone, and an
  instruction has two to six bytes. One test at the start of the instruction ("the next 16 bytes
  lie in the page already translated, inside the segment and inside RAM") makes every fetch in
  that instruction a plain load. On the Linux boot that should remove more than a tenth of the
  host instructions.
- **What changed since last time**: E015 named a decoded-instruction cache as the next step.
  This is a smaller step toward the same cost, taken first because it cannot go stale: nothing is
  remembered from one execution to the next, so code that modifies itself needs no handling.
  What the cache would add on top (not fetching at all) is measured against this, not against
  E015.
- **Next move for each result**:
  - More than 10% fewer host instructions on the boot → keep; then list what a NOP still costs
    and decide whether the cache is worth its invalidation logic
  - Less than 5% → the fetches were not where the cost was; take it out, and go by the listing of
    one instruction again before building anything larger
  - A test fails → the window is wrong at an edge (page end, segment limit, 64 KB wrap in 16-bit
    code, an instruction of more than 15 bytes); fix the condition, not the test
- **Cut-off**: The same day. `tools/difftest.sh` at 45 of 45, test386 byte for byte, and the boot
  must still take exactly 1,651,240,001 instructions to the prompt.

### Result

2026-11-14. **The hypothesis was wrong. One check per instruction instead of one per byte removed
2.2% of the host instructions on the boot (584 to 571 billion, 32.3 s to 31.6 s), under the 5% the
card set, and it was taken out.** The boot still took 1,651,240,001 instructions and test386 was
byte for byte the reference with it in.

The estimate behind the card was stale. The 35 host instructions for an opcode byte were counted
before E015 inlined `fetch8`; after it, a fetch on the fast path is already short, and the page
comparison and limit test that the window removes are a few instructions each.

With the card's own next move ("go by the listing of one instruction again") the debugger stopped
responding in this environment, three times, so the question was put differently: is the average
high because of something other than ordinary instructions? Three things were measured instead.

| Question | Measurement | Answer |
|---|---|---|
| Do repeated string instructions hide many iterations in one step? | Counted them on the boot: 14.5 million string instructions, 78 million iterations, against 1,651 million instructions | No. About 3% of the work at most |
| Is the boot waiting, in loops that run until time has passed? | Booted with 8, 16, 32, 64, 128 and 256 instructions per timer tick | No. See below |
| Is a memory instruction much dearer than a NOP? | `probe/bench32.asm`, after E015: NOP 197, `mov eax, [ebx+8]` 264, `add [ebx+8], eax` 307 host instructions per guest instruction, each averaged with the loop's DEC and JNZ | Dearer, not by a multiple |

Instructions to the prompt, by instructions per timer tick:

| Per tick | 8 | 16 | 32 | 64 | 128 | 256 |
|---|---:|---:|---:|---:|---:|---:|
| Millions of instructions | 2171 | 1768 | 1639 | 1651 | 1767 | 2055 |
| Seconds | 45.4 | 35.9 | 32.3 | 31.8 | 33.5 | 38.1 |

The count has a minimum between 32 and 64. Below it the timer interrupts more often for the same
work; above it the kernel's time-based loops run for more instructions. If the boot were mostly
waiting, the count would keep falling as the tick got shorter. It does not: the boot is work, and
the 64 that rustx86 chose is already at the bottom. (The `--tick` option used for this was not
kept.)

So both sides of "guest instructions times host instructions each" have been looked at. The left
side is at its minimum. The right side is about 350 on the boot: about 150 that every instruction
pays, and about 200 for what the instruction does, spread over decoding the operand, checking the
segment, translating the address and the access itself, none of which stands out.

What is left is not a tweak. A cache of decoded instructions would remove the opcode fetch, the
prefix tests, the reset of the decode state and the operand decode on every execution but the
first, and add a lookup and the handling of code that is written to. From the listing of a NOP
that is roughly 60 host instructions saved and 20 added, and somewhat more for instructions with
a memory operand: an estimate of 10 to 20% on the boot, for rewriting how `exec_one` gets its
operands. Not started; it needs its own card.

## E017: Remember how an instruction decodes (2026-11-14)

- **Hypothesis**: Decoding is a large share of what an instruction costs, and it is the same
  every time the instruction runs. Measured before starting, in host instructions per guest
  instruction (`probe/bench32.asm`, the loop's own cost subtracted): NOP 161; `mov eax, edx` 250;
  `lea eax, [ebx+8]` 300; `lea eax, [ebx+edx*4+8]` 344; `mov eax, [ebx+8]` 382; the same with an
  FS override 442; `mov ax, dx` (an operand-size prefix) 308. So a ModRM byte costs about 90, a
  displacement or SIB byte 50 to 90 more, and each prefix about 60. A cache that keeps, per
  instruction address, the prefixes, the opcode and the decoded operand, and replays them when
  the bytes are still the same, should take the boot below 500 billion host instructions (it is
  584 billion).
- **What changed since last time**: E016 estimated this from a listing taken before E015 and
  was wrong; this estimate is from measurements on the current build. The design is the smallest
  one that could work in Goose, which has no function pointers, so the opcode is still dispatched
  by `match`: only the parsing is skipped. An entry is validated by comparing the instruction's
  first eight bytes with the bytes it was made from, so nothing has to watch writes to memory,
  and code that modifies itself simply misses. Immediate operands are not cached; they are
  fetched as before.
- **Next move for each result**:
  - Below 500 billion → keep; measure what a cached NOP and a cached `mov eax, [ebx+8]` cost now,
    and say what the dispatch itself costs
  - Between 500 and 555 billion (5 to 15%) → keep only if the micro-benchmarks show where the
    rest went (a slow lookup can be fixed; a cache that mostly misses cannot)
  - Above 555 billion (under 5%) → take it out
  - A test fails → compare the trace with the cache switched off; the first differing line names
    the instruction whose replay is wrong
- **Cut-off**: The same day. `tools/difftest.sh` at 45 of 45, test386 byte for byte, the boot at
  exactly 1,651,240,001 instructions, and a new self-check in which code overwrites an
  instruction that has already run and runs it again.

### Result

2026-11-14. **The hypothesis held in the end, by a small margin: 501 billion host instructions on
the boot, against a target of 500. The first version made things worse.** Release build, median
of three, against main after E015:

| Benchmark | Before | After | Change |
|---|---:|---:|---:|
| Linux boot to the shell prompt | 32.3 s, 584 billion host instructions | 29.6 s, 501 billion | 8% less time, 14% fewer instructions |
| test386 | 1511 ms | 1376 ms | 9% less time |
| bench.bin (real mode) | 4449 ms | 4523 ms | no change (2% slower, inside the spread) |

The boot still runs 1,651,240,001 instructions; `tools/difftest.sh` is at 47 of 47 (two more: the
new `s_smc` on both builds); test386 is byte for byte the reference.

Host instructions per guest instruction, before and after (`probe/bench32.asm`):

| Instruction | Before | After |
|---|---:|---:|
| `nop` | 161 | 169 |
| `mov eax, edx` | 250 | 213 |
| `lea eax, [ebx+8]` | 300 | 236 |
| `lea eax, [ebx+edx*4+8]` | 344 | 246 |
| `mov eax, [ebx+8]` | 382 | 288 |
| `mov eax, [fs:ebx+8]` | 442 | 302 |
| `mov ax, dx` | 308 | 213 |
| `mov eax, 0x12345678` | 215 | 193 |
| `add eax, 5` | 369 | 318 |
| `mov [ebx+8], eax` | 378 | 290 |

A prefix is now free, and a memory operand costs about 25 to decode instead of 50 to 90. A NOP
is slightly dearer: looking it up costs as much as decoding it did.

How it got there, on the boot:

| Step | Host instructions |
|---|---:|
| Before | 584 billion |
| The cache as first written | 603 billion |
| Eight byte loads made one (see below) | 572 billion |
| The decode state as one 8-byte struct, copied whole; the two code sizes in separate halves of the table; "the page is in RAM" worked out once per page | 558 billion |
| The cached operand replayed inline; only the parser is a call | 523 billion |
| An instruction that has an entry fetches its remaining bytes without checks | 512 billion |
| A short path for a flat 4 GB data segment in the segment check | 501 billion |

- **The first version was slower than no cache.** The lookup compared eight bytes of the
  instruction with eight bytes in the entry, and reading those eight bytes was sixteen host
  instructions with eight bounds checks. Two things were wrong. The range test was in the
  caller, as a boolean, where Goose's bounds-check analysis could not use it; moved into the
  function, against the constant, the checks went. And the index was a `u32`: `ram[p + 1]` with
  32-bit wrapping arithmetic does not provably follow `ram[p]`, so clang would not merge the
  loads. With an `i64` index the eight loads are one. The same mistake was in E015's 16- and
  32-bit memory accesses, and was fixed there too
- **At 558 billion the card said to take it out** (under 5%). What decided otherwise was the
  table above: the register form of `mov` was still 71 over a NOP, for an operand that is three
  fields to load. The replay was a call; inlining it is what made the cache pay
- **Code that changes itself**: `s_smc` runs an instruction twice, overwrites its opcode, its
  ModRM byte, a displacement, a prefix, a SIB byte or an immediate, and runs it again. It passes
  with the cache on and off. With the byte comparison deliberately removed it fails, so it does
  test what it is there to test

What is not cached, and why the dispatch is the next cost: the opcode is still found by `match`,
immediates are still fetched, and a NOP still costs 169. Goose has no function pointers, so an
entry cannot hold "what to run"; it can only hold "what was parsed".

`--no-decode-cache` switches the cache off, for finding a fault in it.

### Addendum: small gains kept

2026-11-14. The cards so far said to take a change out when it gained less than 5%. The owner's
view is that small gains add up and should be kept, and the numbers bear it out. From now on a
change stays if it measurably reduces the work, and "measurably" means the host instruction count
of the Linux boot, which repeats to within 0.01% from run to run, where the time varies by a few
percent. Four changes, each of which the old rule would have dropped or never tried:

| Change | Host instructions on the boot |
|---|---:|
| After the decode cache (above) | 501.4 billion |
| The globals of `state.goose` and `exec.goose` declared widest first, `Cpu` made 128 bytes | 491.4 billion |
| At the BIOS-entry test, `bios_on` tested first instead of last | 481.5 billion |
| The arithmetic flags gathered and written to EFLAGS once per operation; shifts done in one step instead of one bit at a time | 466.3 billion |

- **The aligned globals are E015's rejected idea.** There it was 1.5% on a micro-benchmark and
  was taken out. Here it is 2% on the boot. Padding in front of the block was tried again at
  every size from 0 to 7; the odd sizes and none were equally good, so there is none
- **One reordered condition is 2%.** `cpu.ip < 256 && bios_on && ...` loaded the instruction
  pointer and compared it on every instruction; under Linux `bios_on` is false and nothing else
  needs to be looked at. Six host instructions per guest instruction
- **The flags**: each of six `set_flag` calls read EFLAGS, changed one bit and wrote it back
- **The shifts** looped once per bit position with a `match` inside the loop. SHL, SHR and SAR
  are now one step; the rotates still loop. The 4,317 lines of the two shift trace tests match
  rustx86 as before

Where that leaves the three benchmarks, against main after E015:

| Benchmark | After E015 | Now | Change |
|---|---:|---:|---:|
| Linux boot to the shell prompt | 32.3 s, 584 billion | 27.3 s, 466 billion | 15% less time, 20% fewer instructions |
| test386 | 1511 ms | 1285 ms | 15% less time |
| bench.bin (real mode) | 4449 ms | 4220 ms | 5% less time |

47 of 47; test386 byte for byte; the boot at 1,651,240,001 instructions.

### Addendum: against rustx86, on the same machine

2026-11-14. rustx86 (commit 64aba23, release build) and g86m (this branch) run the same three
workloads from the same image files. Host instructions are from `/usr/bin/time -l`.

| Workload | | rustx86 | g86m |
|---|---|---:|---:|
| bench.bin, 369 million instructions, 16-bit real mode | time | 6.8 s (54 MIPS) | 4.2 s (87 MIPS) |
| | host instructions per guest instruction | 389 | 244 |
| test386, 104.5 million instructions | time | 1.68 s | 1.29 s |
| | host instructions per guest instruction | 280 | 247 |
| Linux boot to "busybox shell" | guest instructions | 1,500 million | 1,647 million |
| | time, interpreter | 16.1 s (93 MIPS) | 27.3 s (60 MIPS) |
| | host instructions per guest instruction | 171 | 282 |
| | time, rustx86 with its JIT | 11.4 s | - |

**g86m is faster where rustx86 has no decode cache, and slower where it has one.** rustx86's
cache covers 32-bit code only and leaves 16-bit code, prefixed instructions and the less common
opcodes to its ordinary path; that is why it is at 389 and 280 on the first two and 171 on the
third. g86m is between 244 and 282 on all three.

The two caches are not the same kind. g86m's remembers how an instruction parses, and then goes
through the same `match` on the opcode and the same general code as before. rustx86's turns the
most frequent instructions (the two MOVs, the arithmetic grid, the conditional jumps, LEA, the
shifts, MOVZX, TEST: chosen by counting opcodes over a Linux boot) into a small operation each
with its own short executor, and the rest fall back. The difference between 282 and 171 is what
that buys.

The guest instruction counts differ (rustx86 runs 256 instructions per timer tick, g86m 64) and
rustx86's count is rounded up to its 10-million-instruction check, so the times are comparable
and the per-instruction figures slightly favour neither.
