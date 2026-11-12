# Goose で書いていて踏んだこと

Goose は v2026.4 に固定している。ここには、言語やコンパイラの癖で実際に時間を取られたものだけを残す。

## 1. 狭い型を返す関数の結果を、広い型と直接演算すると幅が落ちる (コンパイラのバグ)

`-O2` (既定) で、`u16` を返す関数の呼び出しを `u32` の値と直接掛けると、16bit で計算される。
変数に受けてから掛ければ正しい。`-O0` では直接掛けても正しいので、インライン展開が暗黙の拡張を落としていると見ている。

```goose
import std;
fn narrow() -> u16 { return 0xFFFF; }
fn main() {
    let wide: u32 = 0xFFFF;
    let a: u16 = 0xFFFF;
    print(narrow() * wide, " ", a * wide);   // 期待: 4294836225 が 2 つ
}
```

| 実行方法 | 出力 |
|---|---|
| `goose run` / `goose build` / `goose build --debug` | `1 4294836225` |
| `goose run -O0` | `4294836225 4294836225` |

見つけた経緯: `MUL DI` (FFFFh × FFFFh) の上位語が 0 になり、rustx86 とのトレース差分で出た。

回避: 幅の違う値と演算する前に、狭い側を型付きのローカルに受ける (`let a: u32 = r16(AX);`)。
`src/exec.goose` の乗除算はこの形にしてある。上流への報告はまだしていない。

## 2. `%` は切り捨てではなく床に寄せる

符号付きの `%` は除数の符号に合う余りを返す (`-32767 % 255` は `128`)。`/` はゼロ方向への切り捨て。
x86 の IDIV の余りは被除数の符号なので、`n - q * d` で求める。標準ライブラリの `rem` も被除数の符号を返す。

## 3. 細かいこと

- `args` / `write_stderr` / `exit` は `import os;` が要る
- 文字列リテラルを入れる変数は `const u8[:]`
- 直列化 (`to_bytes` / `from_bytes`) は配列単位。struct 単体は 1 要素の配列に入れる
- `--debug` は約 10 倍遅い。テストは debug と release の両方、測定は release で行う

# rustx86 側で見つけたこと

g86m のテストを rustx86 と突き合わせる途中で分かった、rustx86 (8086 プロファイル) の挙動。g86m は合わせていない。

- **IDIV で -32768 ÷ -1 を踏むと panic する。** `core/src/cpu/group.rs:79` の `attempt to divide with overflow`。
  8bit 形 (`AX=8000h`, 除数 `FFh`) で再現。仕様は除算例外 (#DE)。`tests/asm/s_selfcheck.asm` が g86m 側の挙動を確かめている
- **SALC (D6) で AL が変わらない。** 仕様は `AL = CF ? FFh : 00h`。未公開命令なので実害は小さい
