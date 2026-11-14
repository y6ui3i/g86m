#!/bin/sh
# Runs the instruction tests and compares the per-instruction traces with the expected ones.
#
#   tools/difftest.sh                 compare with tests/expected/*.trace.gz
#   ORACLE=/path/to/trace32 tools/difftest.sh
#                                     regenerate the expected traces with rustx86's trace32 first
#
# To build trace32, put tools/oracle/trace32.rs in rustx86's core/examples/ and run
#   cargo build --release -p rustx86-core --example trace32
# GOOSE names the compiler when it is not on PATH.
set -u
cd "$(dirname "$0")/.."
GOOSE="${GOOSE:-goose}"
mkdir -p build tests/expected

"$GOOSE" build --debug -o build/g86m-debug src/g86m.goose >/dev/null || exit 2
"$GOOSE" build -o build/g86m src/g86m.goose >/dev/null || exit 2

fail=0
for asm in tests/asm/t_*.asm tests/asm/u_*.asm tests/asm/v_*.asm tests/asm/s_*.asm; do
    name=$(basename "$asm" .asm)
    nasm -w-other -I tests/asm/ -f bin -o "build/$name.bin" "$asm" || exit 2
done
cp testdata/hello.bin testdata/interrupt.bin testdata/vram.bin build/

for bin in build/t_*.bin build/u_*.bin build/v_*.bin build/hello.bin build/interrupt.bin build/vram.bin; do
    name=$(basename "$bin" .bin)
    # Tests named v_ use instructions newer than the 386: they run on the i686.
    case "$name" in v_*) cpu="--cpu i686" ;; *) cpu="" ;; esac
    exp="tests/expected/$name.trace.gz"
    if [ -n "${ORACLE:-}" ]; then
        "$ORACLE" "$bin" 2>/dev/null | gzip -9n > "$exp"
    fi
    build/g86m-debug $cpu --trace --max 2000000 "$bin" > "build/$name.trace" 2> "build/$name.err"
    gunzip -c "$exp" > "build/$name.expected"
    # The release build must produce the same trace: optimization must not change behaviour.
    if ! build/g86m $cpu --trace --max 2000000 "$bin" 2>/dev/null | cmp -s - "build/$name.expected"; then
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
    case "$name" in s_686|s_fpu|s_fpu80) cpu="--cpu i686" ;; *) cpu="" ;; esac
    for exe in build/g86m-debug build/g86m; do
        out=$("$exe" $cpu --max 2000000 "$bin" 2>/dev/null)
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

# FreeDOS, twice: the normal startup (language menu, decline the installer, prompt), and the F5
# path (skip CONFIG.SYS, tell the kernel where the shell is, prompt).
if [ -f images/fd14boot.img ]; then
    for exe in build/g86m-debug build/g86m; do
        out=$("$exe" --headless --max 3000000000 \
            --wait "Select from Menu" --type '\n' \
            --wait "[Y,N]?" --type 'n\n' \
            --wait 'A:\>' --type 'dir /w\n' --wait "bytes free" \
            images/fd14boot.img 2>"build/freedos.err")
        if [ $? -eq 0 ] && echo "$out" | grep -q "has been aborted"; then
            echo "ok    freedos startup ($(basename "$exe"))"
        else
            fail=1
            echo "FAIL  freedos startup ($(basename "$exe")): $(tail -1 build/freedos.err)"
        fi
        out=$("$exe" --headless --max 900000000 \
            --wait "FreeDOS kernel" --type '\k3F' \
            --wait "full shell command line" --type '\FREEDOS\BIN\COMMAND.COM\n' \
            --wait 'A:\>' --type 'ver /r\n' --wait "DOS version" \
            --type 'dir /w\n' --wait "bytes free" \
            --type 'echo Done-%COMSPEC%\n' --wait 'Done-A:\FREEDOS\BIN\COMMAND.COM' \
            images/fd14boot.img 2>"build/freedos.err")
        if [ $? -eq 0 ] && echo "$out" | grep -q "FreeDOS kernel 2043"; then
            echo "ok    freedos with F5 ($(basename "$exe"))"
        else
            fail=1
            echo "FAIL  freedos with F5 ($(basename "$exe")): $(tail -1 build/freedos.err)"
        fi
    done
else
    echo "skip  freedos startup and freedos with F5 (images/fd14boot.img is not there)"
fi

# test386: a ROM that tests a 386 instruction by instruction in real, protected and virtual-8086
# mode, with paging. It must reach diagnostic code FF, and what it prints on the serial port must
# be the reference taken from real hardware, byte for byte.
if [ -f images/test386.bin ] && [ -f images/test386-EE-reference.txt ]; then
    for exe in build/g86m-debug build/g86m; do
        "$exe" --headless --max 3000000000 --com build/test386.out images/test386.bin >/dev/null 2>build/test386.err
        last=$(sed -n 's/.* post \(.*\) com .*/\1/p' build/test386.err | awk '{print $NF}')
        if [ "$last" != "ff" ]; then
            fail=1
            echo "FAIL  test386 ($(basename "$exe")): stopped at code ${last:-none}"
        elif ! cmp -s build/test386.out images/test386-EE-reference.txt; then
            fail=1
            echo "FAIL  test386 ($(basename "$exe")): reached FF but the output differs from the reference"
        else
            echo "ok    test386 ($(basename "$exe")): code FF, $(wc -l < build/test386.out | tr -d ' ') lines match the reference"
        fi
    done
else
    echo "skip  test386 (images/test386.bin and its reference are not there)"
fi

# Linux: the kernel is loaded directly and must get as far as printing its banner on the serial
# console. Release build only: this is half a billion instructions.
if [ -f images/vmlinuz-lts ] && [ -f images/initramfs-mini ]; then
    out=$(build/g86m --max 8000000000 --initrd images/initramfs-mini \
        --wait "~ # " --type "uname -m\n" --wait "~ # " \
        --type "printf '%f' 3; echo\n" --wait "~ # " \
        --type "printf '%g %e' 0.1 12345.678; echo\n" --wait "~ # " \
        --type "awk 'BEGIN{print sqrt(2), atan2(1,1)*4, int(-3.7)}'\n" --wait "~ # " \
        --type "a=\$(cut -d. -f1 /proc/uptime); sleep 3; b=\$(cut -d. -f1 /proc/uptime); echo slept-\$((b-a))\n" --wait "~ # " \
        images/vmlinuz-lts 2>"build/linux.err" | tr -d '\r')
    status=$?
    if echo "$out" | grep -q "^i686$" && echo "$out" | grep -q "^3\.000000$" \
        && echo "$out" | grep -q "^0\.1 1\.234568e+04$" \
        && echo "$out" | grep -q "^1\.41421 3\.14159 -3$" && echo "$out" | grep -Eq "^slept-[34]$"; then
        echo "ok    linux shell (g86m): $(echo "$out" | grep -c '') lines; uname, printf %f %g %e, awk, sleep 3"
    else
        fail=1
        echo "FAIL  linux shell (g86m): the session did not give the expected answers"
        echo "$out" | tail -12 | sed 's/^/    |/'
        tail -1 "build/linux.err" | sed 's/^/  stderr:   /'
    fi
else
    echo "skip  linux shell (images/vmlinuz-lts and images/initramfs-mini are not there)"
fi

# The interactive console, driven through a pseudo-terminal. It takes the images that are there.
if command -v python3 >/dev/null; then
    python3 -I tools/console_test.py build/g86m images 2>/dev/null || fail=1
else
    echo "skip  console (python3 is not there)"
fi
exit $fail
