#!/bin/sh
# Runs the instruction tests and compares the per-instruction traces with the expected ones.
#
#   tools/difftest.sh                 compare with tests/expected/*.trace.gz
#   ORACLE=/path/to/trace16 tools/difftest.sh
#                                     regenerate the expected traces with rustx86's trace16 first
#
# To build trace16, put tools/oracle/trace16.rs in rustx86's core/examples/ and run
#   cargo build --release -p rustx86-core --example trace16
# GOOSE names the compiler when it is not on PATH.
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
    # The release build must produce the same trace: optimization must not change behaviour.
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

# Self-checking tests, for what the oracle cannot judge. A test passes when the console says OK and nothing else.
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

# Operating-system boots. The disk images are not in the repository; a missing image is skipped
# and reported, never counted as a pass.
if [ -f images/fd2880.img ]; then
    for exe in build/g86m-debug build/g86m; do
        out=$("$exe" --max 600000000 \
            --wait "login:" --type "root\n" --wait "# " \
            --type "uname -a\n" --wait "ibmpc i8086" \
            --type "ls /bin | head -3; echo done-\$?\n" --wait "done-0" \
            images/fd2880.img 2>"build/elks.err")
        if [ $? -eq 0 ] && echo "$out" | grep -q "ELKS elks 0.9.1"; then
            echo "ok    elks shell ($(basename "$exe"))"
        else
            fail=1
            echo "FAIL  elks shell ($(basename "$exe")): $(tail -1 build/elks.err)"
        fi
    done
else
    echo "skip  elks shell (images/fd2880.img is not there)"
fi
exit $fail
