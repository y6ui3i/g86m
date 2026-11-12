# g86m

[Goose](https://github.com/aardappel/goose) で書く x86 エミュレータ。
[rustx86](https://github.com/y6ui3i/rustx86) のコードは移さず、ゼロから書き直す。

rustx86 から引き継ぐのは言語に依らないものだけ: ブートセクタなどの検証用バイナリ、
期待値、罠の記録。rustx86 そのものは、命令ごとのトレースを突き合わせる正解器として使う。

## 現在地

M0 (Goose の導入と言語適合の確認) が済んだところ。結果は [docs/experiments.md](docs/experiments.md) の E001。

| 段 | 到達点 | 状態 |
|---|---|---|
| M0 | Goose でエミュレータの核が書けるか確かめる | 済 |
| M1 | 8086 リアルモードでブートセクタの Hello, World | 未着手 |
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
goose build -o build/m0 probe/m0.goose
```

```bash
./build/m0 testdata/hello.bin
```

```bash
./build/m0 testdata/bench.bin
```

`testdata/` のブートセクタは rustx86 の `asm/` から持ってきたもの。
