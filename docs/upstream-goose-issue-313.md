<!-- Posted 2026-11-12 as https://github.com/aardappel/goose/issues/313 -->

**Title:** [BUG] Inlined call with a narrower result type loses its implicit widening as the left operand (`u16 * u32` is computed at 16 bits at -O1/-O2)

model-id: claude-fable-5-2
effort: medium
prompt: (none asking for a bug — it surfaced as a wrong result while writing a Goose program; the model then reduced it to the repro below and checked it against main)

## Summary

When a call to a small function that returns a narrower integer is the **left** operand of a mixed-width binary operation, the operation is carried out at the narrower width at `-O1` and `-O2`. At `-O0`, or with the same value held in a variable, it is carried out at the wider width as the reference describes (a `u16` converts to `u32` implicitly).

## Reproduction

```goose
import std;
import os;

var regs: u16[8] = [0; 8];

fn reg(i: u8) -> u16 { return regs[i & 7]; }

fn main() {
    regs[0] = (arg_count() + 0xFFFE) as! u16;      // 0xFFFF at run time, not a constant
    let wide: u32 = regs[0];
    let a: u16 = reg(0);
    print(reg(0) * wide, " ", a * wide, " ", wide * reg(0));
}
```

Expected: `4294836225 4294836225 4294836225`

| Build | Output |
|---|---|
| `goose build -O0` | `4294836225 4294836225 4294836225` |
| `goose build -O1` | `1 4294836225 4294836225` |
| `goose build -O2` (default) | `1 4294836225 4294836225` |

`goose run` and `goose build --debug` give the same wrong first value as `-O2`.

## What the generated C shows

`goose -O0 -o out.c`:

```c
int64_t t3 = gs_fmt_i64(t11, (int64_t)(gs_mul_u32((gs_u32)(t4), wide_g)));
```

`goose -O2 -o out.c`:

```c
int64_t t2 = gs_fmt_i64(t7, (int64_t)(gs_mul_u16((gs_u16)(GS_GL->regs_g.e[0]), wide_g)));
```

After inlining, the multiply is emitted as `gs_mul_u16` instead of `gs_mul_u32`. The other two expressions in the same program stay `gs_mul_u32` at both levels.

## Scope observed

With the narrow call on the left:

| Expression | Got | Expected |
|---|---|---|
| `u16 call * u32` | 1 | 4294836225 |
| `u16 call + u32` | 65534 | 131070 |
| `u8 call * u16` | 1 | 65025 |
| `u16 call * u64` | 1 | 281470681677825 |
| `let x: u32 = u16 call * u32;` | 1 | 4294836225 |

Not affected: the narrow call as the **right** operand (`u32 * u16 call`), and a narrow **variable** on either side.

A function that returns a constant (`fn narrow() -> u16 { return 0xFFFF; }`) shows the same behaviour, so it does not depend on the callee reading memory.

## Workaround

Bind the call to a typed local before mixing widths: `let a: u32 = reg(0);`.

## Environment

- Goose v2026.4 release (macos-arm64), and `main` at d5ae5bb built from source
- macOS on Apple Silicon, Apple clang 21.0.0
