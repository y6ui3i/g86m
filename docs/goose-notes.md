# Things Goose did that cost time

Goose is pinned to v2026.4. This file records only the language and compiler behaviour that actually
cost time.

## 1. A call that returns a narrower type, used as the left operand with a wider type, loses its width (compiler bug)

When a call to a function that returns a narrower integer is the **left** operand of a mixed-width
binary operation, the operation is carried out at the narrower width at `-O1` and `-O2` (the default).
It is correct when the call is the right operand, when the value is held in a variable, and at `-O0`.
Addition is affected as well as multiplication. The generated C has `gs_mul_u32` at `-O0` and
`gs_mul_u16` at `-O2`, so inlining drops the implicit widening.

Reported upstream: [aardappel/goose#313](https://github.com/aardappel/goose/issues/313)
(2026-11-12; reproduced on v2026.4 and on main at d5ae5bb).
The text that was sent is in [upstream-goose-issue-313.md](upstream-goose-issue-313.md).

```goose
import std;
fn narrow() -> u16 { return 0xFFFF; }
fn main() {
    let wide: u32 = 0xFFFF;
    let a: u16 = 0xFFFF;
    print(narrow() * wide, " ", a * wide);   // expected: 4294836225 twice
}
```

| How it is run | Output |
|---|---|
| `goose run` / `goose build` / `goose build --debug` | `1 4294836225` |
| `goose run -O0` | `4294836225 4294836225` |

How it was found: the high word of `MUL DI` (FFFFh × FFFFh) came out as 0, and the trace diff against
rustx86 showed it.

Workaround: before mixing widths, bind the narrow value to a typed local (`let a: u32 = r16(AX);`).
The multiply and divide code in `src/exec.goose` is written this way. Once the bug is fixed, the
workaround can go when the pinned Goose version is raised.

## 2. `%` floors; it does not truncate

Signed `%` returns a remainder with the sign of the divisor (`-32767 % 255` is `128`), while `/`
truncates toward zero. The remainder of x86 IDIV has the sign of the dividend, so it is computed as
`n - q * d`. The standard library's `rem` also returns the sign of the dividend.

## 3. Long-distance return makes CPU faults simple, with two conditions

A fault (a page fault, a protection fault) has to abandon the instruction from deep inside a memory
access. Goose's `return E from f` does exactly that: `raise` in `src/state.goose` ends with
`return false from exec_one`, and every frame between it and `exec_one` returns at once. No error
value is threaded through the callers.

The compiler checks that each call of a function that does this lies inside a call of `exec_one`.
Two things follow, and both produced errors on the way:

- **An unused function that can fault is an error.** A function nobody calls is not inside a call
  of `exec_one`, so `push16`, `pop16` and a `raise_ud` helper that had lost their last callers were
  rejected. Delete such helpers instead of keeping them around
- **Everything that can fault must run under the one function.** Delivering an interrupt pushes on
  the stack and so can fault; it could not stay in the run loop. This is the check doing its job

Related: files may import each other in a cycle, but globals are initialized imported file first.
`var saved: Cpu = cpu;` in the file that the file declaring `cpu` imports was rejected ("may be used
before it is assigned"). The global went into the file that declares `cpu`.

## 4. What generated code costs: things that were not obvious

They were found by counting host instructions for one guest instruction (`/usr/bin/time -l`
for the total, a debugger stepping one instruction for the detail). See E010 and E015 in
[experiments.md](experiments.md).

- **An integer `match` is a chain of comparisons.** There is no `switch` in the generated C. The C
  compiler rebuilds a jump table from the chain when every arm is a plain value; a range arm
  (`0x40..0x48`) stops it. For a big dispatch, match on a few bits first so that level has only
  plain values, then match within
- **Globals are laid out in the order their files are first imported**, in one block, and code
  reaches each by its offset. A large array early in that order pushes everything after it far
  away, and far offsets cost extra instructions on every access. Names are visible program-wide
  without an import, so a file of large arrays can be imported once, last, by the root file
  (`src/big.goose`)
- **Mark the small functions of a hot path `inline fn`.** The helpers of g86m's instruction path
  were all calls in the generated code: Goose had not inlined them, and the C compiler stops
  inlining into a function once it is large, which an interpreter's main function is. Each call saves and restores registers, and each call to something that can fault
  is followed by a test of the fault flag. Marking the helpers of the instruction path `inline fn`
  cut a quarter of the host instructions (E015). It costs build time: inlining one large function
  that is called from many places tripled it
- **Index with `i64`, and test the range where the indexes are.** Reading eight bytes as
  `ram[p]`, `ram[p + 1]`, ... with a `u32` `p` stayed eight loads: in 32-bit wrapping arithmetic
  `p + 1` does not provably follow `p`, so the C compiler will not merge them. With an `i64`
  index it is one load. And a range test passed in from the caller as a boolean does not remove
  the bounds checks; `if p < SIZE - 8 { ... }` around the indexing does. `goose build
  --bce-lines` says which checks are left (E017)
- **Globals and struct fields are packed, with no alignment.** A 32-bit field can sit at an odd
  address. On arm64 that costs one extra instruction per access, which turned out not to matter
  (1.5%, E015)
- **`/` is checked for a zero divisor**, by a call, even when the divisor is the literal 8. Use a
  shift on hot paths. Mind the precedence when replacing: `a + w >> 3` is not `a + (w >> 3)`

## 5. Small things

- `args`, `write_stderr` and `exit` need `import os;`
- A variable that holds a string literal is a `const u8[:]`
- Serialization (`to_bytes` / `from_bytes`) works on arrays. A single struct goes in a one-element array
- `--debug` is about 10 times slower. Tests run on both debug and release builds; measurements use release

# Found in rustx86

Behaviour of rustx86 that turned up while comparing g86m's tests with it. g86m does not follow it in
these cases. The first two were found on its 8086 profile, the rest on its 32-bit profile.

- **IDIV of -32768 by -1 panics.** `attempt to divide with overflow` at `core/src/cpu/group.rs:79`.
  Reproduced with the 8-bit form (`AX=8000h`, divisor `FFh`). The specified behaviour is a divide
  error (#DE). `tests/asm/s_selfcheck.asm` checks what g86m does
- **SALC (D6) leaves AL unchanged.** The specified behaviour is `AL = CF ? FFh : 00h`. It is an
  undocumented instruction, so the practical effect is small
- **BT, BTS, BTR and BTC on memory do not wrap an immediate bit offset.** `bts dword [m], 40`
  should act on bit 8 of the dword (the offset is taken modulo the operand size); rustx86 acts on
  bit 0 of the byte at `m+5`. With a 16-bit register offset it also treats the offset as unsigned,
  where the manual has it signed
- **IRETD in real mode pops 16-bit values.** The operand-size prefix is ignored on that path, so
  three words are popped instead of three dwords
- **FLD ST(i), FXCH and FSTP ST(i) drop the low 11 bits of an 80-bit value.** A value loaded with
  `FLD m80` keeps its 64 mantissa bits only until it is copied to another register; the copy has
  the 53 of an f64. Storing the copy with `FSTP m80` shows it. Real hardware copies all 80 bits.
  Seen for `FLD ST(0)`; its code does the same for the other two
- **Expected, not run: printf rounds floats down.** musl's printf asks whether `2^64 + small`
  differs from `2^64`, which needs a 64-bit mantissa. With f64 registers it never differs, so
  `printf '%g' 0.1` gives `0.0999999`. g86m did this with f64 registers (E013) and stopped when
  its arithmetic moved to the 80-bit format (E014); rustx86 has f64 registers.
