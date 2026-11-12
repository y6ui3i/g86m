#include <stdint.h>
#include <unistd.h>

typedef struct { const uint8_t *data; int64_t len; } g86m_slice;

int32_t g86m_isatty(int32_t fd) { return isatty(fd); }

uint32_t g86m_sum(g86m_slice s) {
    uint32_t t = 0;
    for (int64_t i = 0; i < s.len; i++) t += s.data[i];
    return t;
}
