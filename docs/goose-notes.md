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

## 3. Small things

- `args`, `write_stderr` and `exit` need `import os;`
- A variable that holds a string literal is a `const u8[:]`
- Serialization (`to_bytes` / `from_bytes`) works on arrays. A single struct goes in a one-element array
- `--debug` is about 10 times slower. Tests run on both debug and release builds; measurements use release

# Found in rustx86

Behaviour of rustx86 (8086 profile) that turned up while comparing g86m's tests with it. g86m does
not follow it in these cases.

- **IDIV of -32768 by -1 panics.** `attempt to divide with overflow` at `core/src/cpu/group.rs:79`.
  Reproduced with the 8-bit form (`AX=8000h`, divisor `FFh`). The specified behaviour is a divide
  error (#DE). `tests/asm/s_selfcheck.asm` checks what g86m does
- **SALC (D6) leaves AL unchanged.** The specified behaviour is `AL = CF ? FFh : 00h`. It is an
  undocumented instruction, so the practical effect is small
