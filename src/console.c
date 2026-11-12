// Host terminal glue for the interactive console: raw mode, non-blocking reads, sleeping.
// Everything else about the console is in console.goose.

#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static struct termios saved;
static int raw_on = 0;

// Leaves the alternate screen, shows the cursor and resets colours. Only async-signal-safe calls,
// since it also runs from the signal handler.
static void restore(void) {
    if (!raw_on) return;
    raw_on = 0;
    static const char leave[] = "\x1b[0m\x1b[?25h\x1b[?1049l";
    ssize_t r = write(STDOUT_FILENO, leave, sizeof leave - 1);
    (void)r;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved);
}

static void on_signal(int sig) {
    restore();
    _exit(128 + sig);
}

int32_t con_is_tty(void) { return isatty(STDIN_FILENO) && isatty(STDOUT_FILENO); }

// Puts the terminal in raw mode and switches to the alternate screen. Returns 0 if it cannot.
int32_t con_open(void) {
    if (!con_is_tty() || tcgetattr(STDIN_FILENO, &saved) != 0) return 0;
    struct termios raw = saved;
    cfmakeraw(&raw);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) return 0;
    raw_on = 1;
    atexit(restore);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);
    static const char enter[] = "\x1b[?1049h\x1b[2J\x1b[H";
    ssize_t r = write(STDOUT_FILENO, enter, sizeof enter - 1);
    (void)r;
    return 1;
}

void con_close(void) { restore(); }

// One byte from the keyboard, or -1 when nothing is waiting.
int32_t con_read(void) {
    unsigned char c;
    return read(STDIN_FILENO, &c, 1) == 1 ? c : -1;
}

void con_sleep_us(int32_t us) {
    if (us <= 0) return;
    struct timespec ts = { us / 1000000, (long)(us % 1000000) * 1000 };
    nanosleep(&ts, NULL);
}
