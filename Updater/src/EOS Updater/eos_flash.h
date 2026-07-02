// eos_flash.h -- Eos flash command driver (host side of the 0xEC/0xED contract).
//
// The Eos FPGA exposes a floor-guarded flash engine behind a two-port index/data
// register block: write port 0xEC = INDEX, then read/write port 0xED = DATA.
// The host never sees a physical flash address -- it passes a BANK number and a
// PAGE within that bank, and the FPGA computes phys = 0x200000 + bank_base +
// page*256, so it is impossible to address below the bitstream floor.
//
//   erase a bank   : OP=ERASE, BANK=n, GO, poll STATUS
//   program a page : fill 256-byte page buffer, OP=PROGRAM, BANK=n, PAGE=p, GO, poll
//
// All calls block until the engine reports the operation complete (the FPGA
// runs the real flash WIP poll). Return 0 on success.
//
// RXDK / MSVC2003 / C89: declarations before statements, file-scope statics,
// no CRT, inline __asm port I/O.
#pragma once

#define EOS_FLASH_OK        0
#define EOS_FLASH_REFUSED  -1   // engine rejected the op (bad op/bank, below floor)
#define EOS_FLASH_TIMEOUT  -2   // engine never reported done (bus/FPGA fault)

// bankEf: the bank's 0xEF value; only the low nibble (bank number) is used.
int Flash_EraseBank(int bankEf);
int Flash_ProgramPage(int bankEf, int page, const unsigned char* data256);

// Read one 256-byte page from a bank back into out256 (config read-back, and
// verify-after-flash). The FPGA reads flash into its page buffer, then the host
// streams it out the 0xED port. Returns 0 on success.
int Flash_ReadPage(int bankEf, int page, unsigned char* out256);

// Erase the bank, then program the image as 256-byte pages (tail padded 0xFF),
// then SYNC so the served SDRAM copy matches flash. len may be any size up to
// the bank's capacity. Returns 0 on success.
int Flash_WriteImage(int bankEf, const unsigned char* data, int len);

// Reload a bank's flash contents into the served SDRAM copy. WriteImage calls
// this for you; exposed for a standalone "refresh after flashing" action.
int Flash_Sync(int bankEf);

// Raw register reads (diagnostics / progress UI).
unsigned char Flash_RawStatus(void);    // {.., refused, done, busy}
unsigned char Flash_LastFlashSR(void);  // flash status register from the last poll