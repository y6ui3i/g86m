# g86m

An x86 emulator written in [Goose](https://github.com/aardappel/goose).
It is a rewrite of [rustx86](https://github.com/y6ui3i/rustx86) from scratch, not a port of its code.

What carries over from rustx86 is only what does not depend on the language: test binaries such as
boot sectors, expected values, and the record of pitfalls. rustx86 itself serves as the oracle:
its per-instruction trace is compared with g86m's.

## Status

M1 (the 16-bit real-mode instruction set) is done. Eleven tests match rustx86 line for line on the
state at every instruction boundary. The history and the numbers are in
[docs/experiments.md](docs/experiments.md); what Goose did that cost time is in
[docs/goose-notes.md](docs/goose-notes.md).

| Stage | Goal | State |
|---|---|---|
| M0 | Check that the core of an emulator can be written in Goose | done |
| M1 | The 16-bit real-mode instruction set; a boot sector prints Hello, World | done |
| M2 | The ELKS shell | not started |
| M3 | FreeDOS | not started |
| M4 | 386 protected mode and paging; pass test386 | not started |
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

## Tests

```bash
tools/difftest.sh
```

It assembles one boot sector per instruction group (`tests/asm/`) with NASM, runs each, and compares
the trace with the expected one in `tests/expected/`. The expected traces come from trace16
([tools/oracle/trace16.rs](tools/oracle/trace16.rs)), a small example added to rustx86.
To regenerate them, run `ORACLE=/path/to/trace16 tools/difftest.sh`.

## Layout

| File | Contents |
|---|---|
| [src/state.goose](src/state.goose) | Registers, flags, 1 MB of RAM, the stack, interrupts |
| [src/alu.goose](src/alu.goose) | Arithmetic and flags, shifts and rotates |
| [src/exec.goose](src/exec.goose) | Instruction decode and execution |
| [src/bios.goose](src/bios.goose) | BIOS services handled by the emulator, I/O ports |
| [src/g86m.goose](src/g86m.goose) | Startup and the command line |

The boot sectors in `testdata/` are copied from rustx86's `asm/` as they are, including the Japanese
comments in their sources. `probe/` holds the M0 probes.
