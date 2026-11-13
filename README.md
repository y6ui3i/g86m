# g86m

An x86 emulator written in [Goose](https://github.com/aardappel/goose).
It is a rewrite of [rustx86](https://github.com/y6ui3i/rustx86) from scratch, not a port of its code.

What carries over from rustx86 is only what does not depend on the language: test binaries such as
boot sectors, expected values, and the record of pitfalls. rustx86 itself serves as the oracle:
its per-instruction trace is compared with g86m's.

## Status

M4 is under way. Its first part is done: g86m is now a 386 in real mode, with 32-bit registers,
the operand- and address-size prefixes, 32-bit addressing and the 386's new instructions. Protected
mode and paging are next. FreeDOS 1.4 (M3) and ELKS 0.9.1 (M2) boot and can be used by hand in the
terminal console, or driven by a script.
Seventeen instruction tests match rustx86 line for line on the full 32-bit state at every
instruction boundary. The history and the numbers are in
[docs/experiments.md](docs/experiments.md); what Goose did that cost time is in
[docs/goose-notes.md](docs/goose-notes.md).

How the first day went is written up in a blog post (in Japanese):
[Goose で x86 エミュレータを書き直す](https://pocraft.net/?p=957).

| Stage | Goal | State |
|---|---|---|
| M0 | Check that the core of an emulator can be written in Goose | done |
| M1 | The 16-bit real-mode instruction set; a boot sector prints Hello, World | done |
| M2 | The ELKS shell | done |
| M3 | FreeDOS to the `A:\>` prompt | done (the installer was declined, not run) |
| M4 | 386 protected mode and paging; pass test386 | in progress: the 386 instruction set in real mode is done |
| M5 | 32-bit Linux and busybox | not started |

## Technology choices

Goose is the only new technology in the project. The rest is a C compiler (clang) and, once a screen
is needed, SDL2.

Choosing Goose decides three things:

- **It does not run in a browser.** Goose's wasm output is a proposal and is not implemented. For now
  g86m runs natively in a terminal.
- **There is no JIT.** Goose has no function pointers, so code generated at run time cannot be called.
  Speed has to come from the interpreter.
- **Dispatch and the device bus are `enum` and `match`.** There is nothing like a trait or a vtable.

## Build

Goose is pinned to **v2026.4** ([release](https://github.com/aardappel/goose/releases/tag/v2026.4)).
One C compiler is needed (`goose toolchain` shows which one is found).

```bash
goose build -o build/g86m src/g86m.goose
```

```bash
./build/g86m testdata/hello.bin
```

With `--trace`, g86m prints the state at every instruction boundary, one line each.

An image that is not 512 bytes is booted as floppy drive A. Started from a terminal, it opens the
console: the guest's 80x25 text screen is drawn in the terminal, the keyboard goes to the guest,
and guest time is paced against real time. **Ctrl-]**, **F12** or **Ctrl-\\** leaves it. In a terminal smaller than 80
columns by 25 rows, the console shows the part of the screen around the guest's cursor.

```bash
./build/g86m images/fd2880.img
```

For FreeDOS, press Enter at the language menu, then `n` and Enter when the installer asks whether
to proceed. That leaves you at `A:\>`.

```bash
./build/g86m images/fd14boot.img
```

If the machine stops on something it does not implement, the console closes and says what it was.

`--wait` and `--type` script a session instead: each `--wait` runs until its text is on the screen,
each `--type` types at the keyboard. A scripted run is not paced and skips idle time.

```bash
./build/g86m --wait "login:" --type "root\n" --wait "# " --type "uname -a\n" --wait "i8086" images/fd2880.img
```

Disk images are not in the repository. `images/fd2880.img` is the ELKS 0.9.1 2.88 MB floppy
(`fd2880-minix.img` from the [ELKS releases](https://github.com/ghaerr/elks/releases/tag/v0.9.1)),
and `images/fd14boot.img` is the FreeDOS 1.4 boot floppy from [freedos.org](https://www.freedos.org/).

## Tests

```bash
tools/difftest.sh
```

With the images in `images/`, it also runs scripted ELKS and FreeDOS sessions and drives the
console through a pseudo-terminal ([tools/console_test.py](tools/console_test.py)). A session whose
image is missing is reported as skipped.

It assembles one boot sector per instruction group (`tests/asm/`) with NASM, runs each, and compares
the trace with the expected one in `tests/expected/`. The expected traces come from trace32
([tools/oracle/trace32.rs](tools/oracle/trace32.rs)), a small example added to rustx86.
To regenerate them, run `ORACLE=/path/to/trace32 tools/difftest.sh`.

## Layout

| File | Contents |
|---|---|
| [src/state.goose](src/state.goose) | Registers, flags, 1 MB of RAM, the stack, interrupts |
| [src/alu.goose](src/alu.goose) | Arithmetic and flags, shifts and rotates |
| [src/exec.goose](src/exec.goose) | Instruction decode and execution |
| [src/bios.goose](src/bios.goose) | Power-on setup and the BIOS services the emulator performs: screen, disk, keyboard, time |
| [src/dev.goose](src/dev.goose) | Interrupt controllers, timer, keyboard controller, I/O port dispatch |
| [src/console.goose](src/console.goose), [src/console.c](src/console.c) | The terminal console: drawing the screen, translating keys; raw terminal mode in C |
| [src/g86m.goose](src/g86m.goose) | The run loop, interrupt delivery, pacing, the session script, the command line |

The boot sectors in `testdata/` are copied from rustx86's `asm/` as they are, including the Japanese
comments in their sources. `probe/` holds the M0 probes.

## License

[MIT](LICENSE). The disk images g86m boots are not part of this repository and have licenses of
their own.
