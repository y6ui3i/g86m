# g86m

[Goose](https://github.com/aardappel/goose) で書く x86 エミュレータ。
[rustx86](https://github.com/y6ui3i/rustx86) のコードは移さず、ゼロから書き直す。

rustx86 から引き継ぐのは言語に依らないものだけ: ブートセクタなどの検証用バイナリ、
期待値、罠の記録。rustx86 そのものは、命令ごとのトレースを突き合わせる正解器として使う。

## 現在地

M1 (16bit リアルモードの命令一式) が済んだところ。rustx86 と命令境界ごとの状態を突き合わせ、テスト 11 本が全行一致している。
経緯と数字は [docs/experiments.md](docs/experiments.md)、Goose の癖は [docs/goose-notes.md](docs/goose-notes.md)。

| 段 | 到達点 | 状態 |
|---|---|---|
| M0 | Goose でエミュレータの核が書けるか確かめる | 済 |
| M1 | 16bit リアルモードの命令一式、ブートセクタの Hello, World | 済 |
| M2 | ELKS のシェル | 未着手 |
| M3 | FreeDOS | 未着手 |
| M4 | 386 プロテクトモードとページング、test386 合格 | 未着手 |
| M5 | 32bit Linux と busybox | 未着手 |

## 技術選定

新技術の枠は Goose だけに使う。ほかは C コンパイラ (clang) と、必要になった段で SDL2。

Goose を選ぶと決まること:

- **ブラウザでは動かない。** Goose の wasm 出力は提案段階で未実装。当面はネイティブのターミナルで動かす
- **JIT は作らない。** 関数ポインタがなく、実行時に生成したコードを呼べない。速度はインタプリタで出す
- **ディスパッチもデバイスバスも `enum` と `match`。** trait や vtable に当たるものがない

## ビルド

Goose は **v2026.4** に固定する ([リリース](https://github.com/aardappel/goose/releases/tag/v2026.4))。
C コンパイラが 1 つ要る (`goose toolchain` で確認できる)。

```bash
goose build -o build/g86m src/g86m.goose
```

```bash
./build/g86m testdata/hello.bin
```

`--trace` を付けると、命令境界ごとの状態を 1 行ずつ出す。

## テスト

```bash
tools/difftest.sh
```

命令群ごとのブートセクタ (`tests/asm/`) を NASM で組み、トレースを `tests/expected/` の期待値と比べる。
期待値は rustx86 に足した trace16 ([tools/oracle/trace16.rs](tools/oracle/trace16.rs)) で作ったもの。
作り直すときは `ORACLE=/path/to/trace16 tools/difftest.sh`。

## 構成

| ファイル | 中身 |
|---|---|
| [src/state.goose](src/state.goose) | レジスタ、フラグ、1MB の RAM、スタック、割り込み |
| [src/alu.goose](src/alu.goose) | 演算とフラグ、シフトと回転 |
| [src/exec.goose](src/exec.goose) | 命令のデコードと実行 |
| [src/bios.goose](src/bios.goose) | BIOS サービスの代行、I/O ポート |
| [src/g86m.goose](src/g86m.goose) | 起動とコマンドライン |

`testdata/` のブートセクタは rustx86 の `asm/` から持ってきたもの。`probe/` は M0 の試し書き。
