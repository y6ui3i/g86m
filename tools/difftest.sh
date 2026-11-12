#!/bin/sh
# 命令テストを走らせ、命令境界ごとのトレースを期待値と比べる。
#
#   tools/difftest.sh                 期待値 (tests/expected/*.trace.gz) と比べる
#   ORACLE=/path/to/trace16 tools/difftest.sh
#                                     rustx86 の trace16 で期待値を作り直してから比べる
#
# trace16 は tools/oracle/trace16.rs を rustx86 の core/examples/ に置いて
#   cargo build --release -p rustx86-core --example trace16
# で作る。GOOSE でコンパイラの場所を変えられる。
set -u
cd "$(dirname "$0")/.."
GOOSE="${GOOSE:-goose}"
mkdir -p build tests/expected

"$GOOSE" build --debug -o build/g86m-debug src/g86m.goose >/dev/null || exit 2
"$GOOSE" build -o build/g86m src/g86m.goose >/dev/null || exit 2

fail=0
for asm in tests/asm/t_*.asm tests/asm/s_*.asm; do
    name=$(basename "$asm" .asm)
    nasm -w-other -I tests/asm/ -f bin -o "build/$name.bin" "$asm" || exit 2
done
cp testdata/hello.bin testdata/interrupt.bin testdata/vram.bin build/

for bin in build/t_*.bin build/hello.bin build/interrupt.bin build/vram.bin; do
    name=$(basename "$bin" .bin)
    exp="tests/expected/$name.trace.gz"
    if [ -n "${ORACLE:-}" ]; then
        "$ORACLE" "$bin" 2>/dev/null | gzip -9n > "$exp"
    fi
    build/g86m-debug --trace --max 2000000 "$bin" > "build/$name.trace" 2> "build/$name.err"
    gunzip -c "$exp" > "build/$name.expected"
    # release ビルドも同じトレースを出すこと (最適化で挙動が変わらないことの確認)。
    if ! build/g86m --trace --max 2000000 "$bin" 2>/dev/null | cmp -s - "build/$name.expected"; then
        fail=1
        echo "FAIL  $name: release build differs from the expected trace"
    fi
    if cmp -s "build/$name.trace" "build/$name.expected"; then
        echo "ok    $name ($(wc -l < "build/$name.trace" | tr -d ' ') lines)"
    else
        fail=1
        line=$(cmp "build/$name.trace" "build/$name.expected" 2>&1 | sed -n 's/.*line \([0-9][0-9]*\).*/\1/p')
        if [ -z "$line" ]; then line=$(($(wc -l < "build/$name.trace") + 1)); fi
        echo "FAIL  $name: first difference at line $line"
        echo "  before:   $(sed -n "$((line - 1))p" "build/$name.expected")"
        echo "  expected: $(sed -n "${line}p" "build/$name.expected")"
        echo "  got:      $(sed -n "${line}p" "build/$name.trace")"
        tail -1 "build/$name.err" | sed 's/^/  stderr:   /'
    fi
done

# 自己判定テスト: 正解器と比べられないもの。コンソールに OK とだけ出れば合格。
for bin in build/s_*.bin; do
    name=$(basename "$bin" .bin)
    for exe in build/g86m-debug build/g86m; do
        out=$("$exe" --max 2000000 "$bin" 2>/dev/null)
        if [ "$out" = "OK" ]; then
            echo "ok    $name ($(basename "$exe"))"
        else
            fail=1
            echo "FAIL  $name ($(basename "$exe")): console was \"$out\""
        fi
    done
done
exit $fail
