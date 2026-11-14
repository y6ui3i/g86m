#!/usr/bin/env python3
"""Drives the interactive console through a pseudo-terminal, the way a person at a terminal would.

    tools/console_test.py build/g86m images

With images/fd2880.img: logs in to ELKS, runs a command, checks that `sleep 3` takes about 3
seconds of real time, leaves with Ctrl-], and checks that the terminal modes are put back; then
repeats a shorter session on two terminals smaller than 80x25.

With images/fd14boot.img: boots FreeDOS, presses F5 as a real function key, answers where the
shell is, and runs `dir`.

With images/vmlinuz-lts and images/initramfs-mini: boots Linux with the terminal as its serial
console, runs a command, checks that `sleep 3` takes about 3 seconds, and leaves with Ctrl-].

An image that is not there is reported as skipped. Exits 0 when nothing failed.

The console only sends the cells that changed, so its output cannot be read as a stream of text.
The test keeps its own 80x25 grid and applies the cursor moves and characters to it.
"""
import os
import pty
import re
import select
import sys
import termios
import time

TOKEN = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])|\x1b.|([^\x1b])", re.S)


class Screen:
    """A terminal of the given size: the grid, the cursor, and whether anything aimed outside it."""

    def __init__(self, rows=25, cols=80):
        self.rows, self.cols = rows, cols
        self.cells = [[" "] * cols for _ in range(rows)]
        self.row = self.col = 0
        self.pending = b""
        self.out_of_bounds = None

    def feed(self, data):
        data = self.pending + data
        # Keep an unfinished escape sequence or UTF-8 character for the next read.
        cut = len(data)
        esc = data.rfind(b"\x1b")
        if esc >= 0 and not re.match(rb"\x1b\[[0-9;?]*[A-Za-z]", data[esc:]):
            cut = esc
        text = data[:cut].decode("utf-8", errors="ignore")
        self.pending = data[cut:]
        for params, final, char in TOKEN.findall(text):
            if final == "H":
                parts = (params.split(";") + ["1", "1"])[:2]
                row, col = int(parts[0] or 1), int(parts[1] or 1)
                if row > self.rows or col > self.cols:
                    self.out_of_bounds = (row, col)
                self.row = min(max(row - 1, 0), self.rows - 1)
                self.col = min(max(col - 1, 0), self.cols - 1)
            elif final == "J":
                self.cells = [[" "] * self.cols for _ in range(self.rows)]
            elif char and char >= " ":
                if self.col < self.cols:
                    self.cells[self.row][self.col] = char
                    self.col += 1
                else:
                    self.out_of_bounds = (self.row + 1, self.col + 1)

    def lines(self):
        return ["".join(row).rstrip() for row in self.cells]

    def at_prompt(self):
        """The cursor sits right after a `# ` prompt at the start of its line."""
        return self.col == 2 and "".join(self.cells[self.row][:2]) == "# "


def session(exe, image, rows, cols, full, quit_key=b"\x1d"):
    """One console session on a terminal of rows by cols. full runs every check; otherwise only
    the ones that show the screen fits the terminal."""
    master, slave = pty.openpty()
    termios.tcsetwinsize(slave, (rows, cols))
    before = termios.tcgetattr(slave)
    pid = os.fork()
    if pid == 0:
        os.setsid()
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.close(master)
        os.execv(exe, [exe, image])

    screen = Screen(rows, cols)
    raw = b""

    def pump(seconds):
        nonlocal raw
        ready, _, _ = select.select([master], [], [], seconds)
        if ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                return
            raw += data
            screen.feed(data)

    def fail(message):
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        print(f"FAIL  console {cols}x{rows}:", message)
        for line in screen.lines():
            if line:
                print("    |" + line)
        sys.exit(1)

    def wait(what, condition, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return
            pump(0.02)
        fail(f"timed out after {timeout}s waiting for {what}")

    def has_line(text):
        return lambda: any(line == text for line in screen.lines())

    def contains(text):
        return lambda: any(text in line for line in screen.lines())

    t0 = time.monotonic()
    wait("the login prompt", contains("login:"), 90)
    boot_seconds = time.monotonic() - t0
    os.write(master, b"root\r")
    wait("the shell prompt", screen.at_prompt, 30)
    os.write(master, b"uname -a\r")
    # The start of the line: on a terminal narrower than the line, its end is cut off.
    wait("uname output", contains("ELKS elks 0.9.1"), 30)
    wait("the prompt after uname", screen.at_prompt, 30)

    # Scroll the guest's screen well past the height of the terminal, then check a command still
    # shows up where the prompt is.
    os.write(master, b"ls /bin\r")
    wait("the prompt after ls", lambda: screen.at_prompt() and contains("vi")(), 30)
    os.write(master, b"echo vi''ew\r")
    wait("output after scrolling", has_line("view"), 30)
    wait("the prompt after scrolling", screen.at_prompt, 30)
    if screen.out_of_bounds:
        fail(f"the console addressed row {screen.out_of_bounds[0]}, column {screen.out_of_bounds[1]}")

    slept = interrupted = 0.0
    if full:
        slept, interrupted = timing_and_keys(master, screen, wait, has_line, pump, fail)

    # Checked before leaving: on exit g86m prints the screen as plain text, which is not console
    # output and does not go through the grid's rules.
    if screen.out_of_bounds:
        fail(f"the console addressed row {screen.out_of_bounds[0]}, column {screen.out_of_bounds[1]}")
    if rows > 25 and not contains("to quit")():
        fail("no hint on how to quit below the screen")
    if b"to quit" not in raw.split(b"\x1b[?1049h")[0]:
        fail("no hint on how to quit before the console opened")
    os.write(master, quit_key)
    deadline = time.monotonic() + 10
    status = None
    while time.monotonic() < deadline:
        pump(0.02)
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            break
    else:
        fail(f"did not exit within 10s of the quit key {quit_key!r}")
    if os.waitstatus_to_exitcode(status) != 0:
        fail(f"exit status {os.waitstatus_to_exitcode(status)}")
    if b"\x1b[?1049l" not in raw:
        fail("did not leave the alternate screen")
    if termios.tcgetattr(slave) != before:
        fail("terminal modes were not restored")
    os.close(master)
    os.close(slave)
    return boot_seconds, slept, interrupted


def timing_and_keys(master, screen, wait, has_line, pump, fail):
    # The quotes keep the word out of the echoed command line, so only the command's own output
    # can be a line that reads exactly `slept`.
    os.write(master, b"sleep 3; echo sl''ept\r")
    t1 = time.monotonic()
    wait("sleep 3 to finish", has_line("slept"), 30)
    slept = time.monotonic() - t1
    if not 2.5 <= slept <= 3.5:
        fail(f"`sleep 3` took {slept:.2f}s of real time")
    wait("the prompt after sleep", screen.at_prompt, 30)

    # Control keys: erase part of a line with Backspace, then interrupt a long sleep with Ctrl-C.
    os.write(master, b"echo wrongXX\x7f\x7f\x7f\x7f\x7f\x7f\x7fba''cksp\r")
    wait("the backspace line", has_line("backsp"), 30)
    wait("the prompt after backspace", screen.at_prompt, 30)

    os.write(master, b"sleep 30\r")
    wait("sleep 30 to start", lambda: not screen.at_prompt(), 10)
    until = time.monotonic() + 1.0
    while time.monotonic() < until:
        pump(0.02)
    if screen.at_prompt():
        fail("sleep 30 returned by itself within a second")
    os.write(master, b"\x03")
    t2 = time.monotonic()
    wait("Ctrl-C to interrupt sleep 30", screen.at_prompt, 5)
    interrupted = time.monotonic() - t2

    return slept, interrupted


def start(exe, image, rows, cols, options=()):
    """Starts g86m on a new pseudo-terminal. Returns (pid, master, slave, modes before)."""
    master, slave = pty.openpty()
    termios.tcsetwinsize(slave, (rows, cols))
    before = termios.tcgetattr(slave)
    pid = os.fork()
    if pid == 0:
        os.setsid()
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.close(master)
        os.execv(exe, [exe, *options, image])
    return pid, master, slave, before


def dos_session(exe, image):
    """FreeDOS through the console: F5 as the escape sequence a terminal sends, then `dir`."""
    rows, cols = 30, 100
    pid, master, slave, before = start(exe, image, rows, cols)
    screen = Screen(rows, cols)

    def fail(message):
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        print("FAIL  console freedos:", message)
        for line in screen.lines():
            if line:
                print("    |" + line)
        sys.exit(1)

    def wait(what, text, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if any(text in line for line in screen.lines()):
                return
            ready, _, _ = select.select([master], [], [], 0.02)
            if ready:
                try:
                    screen.feed(os.read(master, 65536))
                except OSError:
                    break
        fail(f"timed out after {timeout}s waiting for {what}")

    wait("the kernel banner", "FreeDOS kernel", 60)
    os.write(master, b"\x1b[15~")                       # F5
    wait("the question about the shell", "full shell command line", 60)
    os.write(master, b"\\FREEDOS\\BIN\\COMMAND.COM\r")
    wait("the prompt", "A:\\>", 60)
    os.write(master, b"dir /w\r")
    wait("the directory listing", "bytes free", 60)
    if screen.out_of_bounds:
        fail(f"the console addressed row {screen.out_of_bounds[0]}, column {screen.out_of_bounds[1]}")
    os.write(master, b"\x1b[24~")                       # F12
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        # Keep reading: g86m waits for its last output to be taken before it restores the terminal.
        ready, _, _ = select.select([master], [], [], 0.02)
        if ready:
            try:
                os.read(master, 65536)
            except OSError:
                pass
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            break
    else:
        fail("did not exit within 10s of F12")
    if os.waitstatus_to_exitcode(status) != 0:
        fail(f"exit status {os.waitstatus_to_exitcode(status)}")
    if termios.tcgetattr(slave) != before:
        fail("terminal modes were not restored")
    os.close(master)
    os.close(slave)


def linux_session(exe, kernel, initramfs):
    """Linux through the serial console: the terminal is the guest's serial port, as a stream."""
    pid, master, slave, before = start(exe, kernel, 30, 100, ("--initrd", initramfs))
    seen = b""

    def fail(message):
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        print("FAIL  console linux:", message)
        for line in seen.decode("utf-8", errors="replace").splitlines()[-12:]:
            print("    |" + line)
        sys.exit(1)

    def wait(what, text, timeout):
        """Waits for text to arrive after what has been seen so far; returns how long it took."""
        nonlocal seen
        start_at, t0 = len(seen), time.monotonic()
        while time.monotonic() - t0 < timeout:
            if text in seen[start_at:]:
                return time.monotonic() - t0
            ready, _, _ = select.select([master], [], [], 0.02)
            if ready:
                try:
                    seen += os.read(master, 65536)
                except OSError:
                    break
        fail(f"timed out after {timeout}s waiting for {what}")

    boot = wait("the shell prompt", b"~ # ", 240)
    os.write(master, b"echo hi-$((6*7))\r")
    wait("the answer to echo", b"hi-42", 30)
    wait("the prompt", b"~ # ", 30)
    os.write(master, b"sleep 3; echo slept\r")
    slept = wait("the end of sleep 3", b"\nslept", 30)
    if not 2.5 <= slept <= 4.5:
        fail(f"sleep 3 took {slept:.2f}s of real time")
    os.write(master, b"\x1d")                           # Ctrl-]
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.02)
        if ready:
            try:
                os.read(master, 65536)
            except OSError:
                pass
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            break
    else:
        fail("did not exit within 10s of Ctrl-]")
    if os.waitstatus_to_exitcode(status) != 0:
        fail(f"exit status {os.waitstatus_to_exitcode(status)}")
    if termios.tcgetattr(slave) != before:
        fail("terminal modes were not restored")
    os.close(master)
    os.close(slave)
    return boot, slept


def main():
    exe, images = sys.argv[1], sys.argv[2]
    elks = os.path.join(images, "fd2880.img")
    freedos = os.path.join(images, "fd14boot.img")
    if os.path.exists(elks):
        boot, slept, interrupted = session(exe, elks, 30, 100, True)
        print(f"ok    console elks 100x30 (boot to login {boot:.1f}s, sleep 3 took {slept:.2f}s, "
              f"Ctrl-C ended sleep 30 after {interrupted:.2f}s)")
        # Terminals smaller than the guest's 80x25 screen, each left by a different key.
        for rows, cols, quit_key, name in ((10, 80, b"\x1c", "Ctrl-\\"), (12, 60, b"\x1b[24~", "F12")):
            session(exe, elks, rows, cols, False, quit_key)
            print(f"ok    console elks {cols}x{rows} (the view follows the cursor; {name} quits)")
    else:
        print("skip  console elks (fd2880.img is not there)")
    if os.path.exists(freedos):
        dos_session(exe, freedos)
        print("ok    console freedos 100x30 (F5 as a function key, shell path, dir)")
    else:
        print("skip  console freedos (fd14boot.img is not there)")
    kernel = os.path.join(images, "vmlinuz-lts")
    initramfs = os.path.join(images, "initramfs-mini")
    if os.path.exists(kernel) and os.path.exists(initramfs):
        boot, slept = linux_session(exe, kernel, initramfs)
        print(f"ok    console linux (serial; boot to shell {boot:.1f}s, sleep 3 took {slept:.2f}s, Ctrl-] quits)")
    else:
        print("skip  console linux (vmlinuz-lts and initramfs-mini are not there)")


main()
