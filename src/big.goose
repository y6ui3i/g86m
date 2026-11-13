// The large arrays. Nothing imports this file except g86m.goose, which imports it last, and that
// is the point: Goose lays globals out in the order their files are first imported, and generated
// code reaches a global by its offset from the start of that block. With 1 MB of RAM in the
// middle, everything declared after it sat more than a megabyte away, which costs extra
// instructions on every access to the CPU state. Declared here, the big arrays come last and the
// state every instruction touches stays near the start. (Names are visible program-wide, so the
// other files use these without importing this one.)

import state;

var ram: u8[RAM_SIZE];

// Ports nothing answers: counted per port so a run can report what the guest probed.
var unknown_ports: u8[65536] = [0; 65536];

// How often each BIOS service was called, by interrupt number and AH. Reported by --ports.
var bios_calls: u32[65536] = [0; 65536];

// What the terminal currently shows, for the console; FFh forces a redraw.
var shown: u8[4000] = [0xFF; 4000];
