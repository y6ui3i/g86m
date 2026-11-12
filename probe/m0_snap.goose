// M0 (c): CPU 状態と RAM を to_bytes / from_bytes で往復できるか。
import std;

struct Cpu { regs: u16[8], segs: u16[4], ip: u16, flags: u16, halted: bool }

let RAM_SIZE = 1048576;
var ram: u8[>..];

fn main() {
    var cpus: Cpu[>..] = [];
    cpus.push(Cpu { regs: [1, 2, 3, 4, 5, 6, 7, 8], segs: [0, 0x7C0, 0, 0], ip: 0x1234, flags: 0x46, halted: true });
    for i in RAM_SIZE { ram.push((i * 7) as! u8); }

    var image: u8[>..] = [];
    to_bytes(cpus, image);
    let cpu_bytes = image.len;
    to_bytes(ram, image);
    print("image ", image.len, " bytes (cpu part ", cpu_bytes, ")");

    var back, ok = from_bytes<Cpu[>..]>(image[..cpu_bytes]);
    var ram2, ok2 = from_bytes<u8[>..]>(image[cpu_bytes..]);
    print(ok, " ", ok2, " ", back[0] == cpus[0], " ", ram2.len, " ", ram2[123456] == ram[123456]);

    image[0] = 99;
    var bad, bok = from_bytes<Cpu[>..]>(image[..cpu_bytes]);
    print("tampered: ", bok, " ", bad.len);
}
