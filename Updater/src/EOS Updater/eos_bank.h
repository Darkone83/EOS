// eos_bank.h -- Eos bank table + selection/launch.
//
// A "bank" is a virtual region the FPGA serves, selected by the low nibble of
// I/O port 0xEF (the OpenXenium-compatible bank register the Eos FPGA decodes).
// Launching a bank writes 0xEF then fires an SMC warm reset; the FPGA bank
// register persists across the warm reset, so the Xbox reboots into the chosen
// bank. A cold power-on clears the FPGA back to the boot bank (this loader).
//
// 0xEF low-nibble -> FPGA virtual base (see eos_sdram_backend.v xlate):
//   0x1 boot/kernel @0x180000 (this loader)   0x3 user @0x000000   0x4 @0x040000
//   0x5 user @0x080000   0x6 user @0x0C0000   0xA recovery @0x1C0000
#pragma once
#include <xtl.h>

#define EOS_BANK_MAX 8
#define EOS_BANK_NAMELEN 24

// BIOS size codes (persisted in config; mirrors the FPGA bank geometry).
#define EOS_BANK_SIZE_256K 0
#define EOS_BANK_SIZE_512K 1
#define EOS_BANK_SIZE_1MB  2

void          Bank_ResetToFactory(void);  // reset live table to factory defaults
int           Bank_Count(void);
const char* Bank_Name(int idx);
unsigned char Bank_Ef(int idx);            // 0xEF value for this bank (low nibble = bank)
int           Bank_IndexForEf(unsigned char ef);  /* reverse: table index for EF, -1 if none */
void          Bank_SetName(int idx, const char* name);  // rename (persisted via Config_Save)

// Occupancy + size (drives populated-only launch list vs all-banks management).
int  Bank_Occupied(int idx);               // 1 = bank holds a BIOS
int  Bank_SizeCode(int idx);               // EOS_BANK_SIZE_*
void Bank_SetOccupied(int idx, int occupied, int sizeCode);

// Clear a slot after erasing its flash: empty + default size + factory name.
void Bank_ClearEntry(int idx);

// Launch list = populated banks, excluding the boot/loader bank we're in.
int  Bank_IsBoot(int idx);                 // 1 = this is the boot/loader bank (0x1)
int  Bank_IsLocked(int idx);               // 1 = system bank (boot/recovery/diag): no user manage
int  Bank_LaunchCount(void);               // # of launchable (occupied, non-boot) banks
int  Bank_LaunchIndex(int n);              // table index of the nth launchable bank, -1 if none

// Physical slot capacity in bytes (matches the FPGA bank_size map). A flashed
// image must fit within this.
int  Bank_CapacityBytes(int idx);

// Write the boot bank (0x01) to 0xEF as the safe "resting" selection, so an
// UNEXPECTED warm reset (a crash, not a deliberate launch) lands back in this
// loader's menu instead of a half-mapped region. Call once at startup.
void Bank_SetResting(void);

// Select the bank in the FPGA (0xEF write) then SMC warm-reset into it.
// Does not return on real hardware.
void Bank_Launch(int idx);

// Release D0 (set the FPGA stock-boot bit at flash-cmd index 0x08) then SMC
// warm-reset so the console boots the onboard TSOP instead of Eos. The bit
// survives the warm reset; a COLD power cycle clears it and returns to Eos.
// Does not return on real hardware.
void Eos_TsopBoot(void);

// XbDiag Lite (bank 0xD): shown in the launch menu only when installed. Launched
// via a flash sync (page it into SDRAM) then select + warm reset -- not the plain
// select a real bank uses.
int  Bank_XbDiagPresent(void);             // 1 = XbDiag Lite installed in slot 0xD
void Eos_LaunchXbDiag(void);               // sync 0xD -> select -> warm reset (no return)

// --- diagnostics ---
// Write a bank's 0xEF value WITHOUT resetting (so the FPGA bank reg + readback
// update live), and read 0xEF back. If read == written, the 0xEF I/O path to
// the FPGA is working; if not, the write isn't reaching the FPGA.
void          Bank_TestWrite(int idx);
unsigned char Bank_ReadEf(void);