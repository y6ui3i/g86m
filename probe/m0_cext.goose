// M0 (d): can our own C be called through extern fn? (Glue for things like terminal raw mode.)
import std;

extern fn g86m_isatty(fd: i32) -> i32;
extern fn g86m_sum(xs: const u8[:]) -> u32;

fn main() {
    let bytes: u8[4] = [1, 2, 3, 250];
    print("isatty(0) = ", g86m_isatty(0), "  sum = ", g86m_sum(bytes[..]));
}
