#!/usr/bin/env python3
"""Drives the interactive console through a pseudo-terminal, the way a person at a terminal would.

    tools/console_test.py build/g86m images/fd2880.img

Logs in to ELKS, runs a command, checks that `sleep 3` takes about 3 seconds of real time, leaves
with Ctrl-], and checks that the terminal modes are put back. Exits 0 when all of that holds.

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
    def __init__(self):
        self.cells = [[" "] * 80 for _ in range(25)]
        self.row = self.col = 0
        self.pending = b""

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
                self.row = min(max(int(parts[0] or 1) - 1, 0), 24)
                self.col = min(max(int(parts[1] or 1) - 1, 0), 79)
            elif final == "J":
                self.cells = [[" "] * 80 for _ in range(25)]
            elif char and char >= " ":
                if self.col < 80:
                    self.cells[self.row][self.col] = char
                    self.col += 1

    def lines(self):
        return ["".join(row).rstrip() for row in self.cells]

    def at_prompt(self):
        """The cursor sits right after a `# ` prompt at the start of its line."""
        return self.col == 2 and "".join(self.cells[self.row][:2]) == "# "


def main():
    exe, image = sys.argv[1], sys.argv[2]
    master, slave = pty.openpty()
    termios.tcsetwinsize(slave, (30, 100))
    before = termios.tcgetattr(slave)
    pid = os.fork()
    if pid == 0:
        os.setsid()
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.close(master)
        os.execv(exe, [exe, image])

    screen = Screen()
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
        print("FAIL  console:", message)
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
    wait("uname output", contains("ibmpc i8086"), 30)
    wait("the prompt after uname", screen.at_prompt, 30)

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

    os.write(master, b"\x1d")
    deadline = time.monotonic() + 10
    status = None
    while time.monotonic() < deadline:
        pump(0.02)
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            break
    else:
        fail("did not exit within 10s of Ctrl-]")
    if os.waitstatus_to_exitcode(status) != 0:
        fail(f"exit status {os.waitstatus_to_exitcode(status)}")
    if b"\x1b[?1049l" not in raw:
        fail("did not leave the alternate screen")
    if termios.tcgetattr(slave) != before:
        fail("terminal modes were not restored")
    print(f"ok    console (boot to login {boot_seconds:.1f}s, sleep 3 took {slept:.2f}s, "
          f"Ctrl-C ended sleep 30 after {interrupted:.2f}s)")


main()
