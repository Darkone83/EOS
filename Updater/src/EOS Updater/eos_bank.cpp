// eos_bank.cpp -- Eos bank table + selection/launch.
//
// Bank select is the OpenXenium-compatible I/O port 0xEF: writing a byte whose
// low nibble is the bank number tells the Eos FPGA which virtual region to map.
// The FPGA bank register persists across a warm reset, so to boot a bank we:
//     out 0xEF, <bank>           ; select (survives the warm reset)
//     raw nForce SMBus write 0x10/0x02/0x01     ; SMC warm reset -> reboot into bank
// 0x01 is the reliable SMC warm-reset command (0x40 is honored on fewer boxes).
//
// RXDK / MSVC2003 constraints: declarations before statements, file-scope
// statics, no CRT string funcs.
#include "eos_bank.h"
#include "eos_flash.h"

struct EosBank {
    unsigned char ef;
    char          name[EOS_BANK_NAMELEN];
    char          defname[EOS_BANK_NAMELEN];   // factory label, restored on clear
    unsigned char occupied;
    unsigned char size_code;
    unsigned char locked;      // 1 = system bank: no user delete / flash / rename
};

static EosBank s_banks[EOS_BANK_MAX];
static int     s_count = 0;

static void copyName(char* dst, const char* src)
{
    int i = 0;
    for (; src[i] && i < EOS_BANK_NAMELEN - 1; ++i) dst[i] = src[i];
    dst[i] = 0;
}

static void addBank(unsigned char ef, const char* nm, unsigned char occ, unsigned char sz,
    unsigned char lock)
{
    if (s_count >= EOS_BANK_MAX) return;
    s_banks[s_count].ef = ef;
    copyName(s_banks[s_count].name, nm);
    copyName(s_banks[s_count].defname, nm);   // remember the factory label
    s_banks[s_count].occupied = occ;
    s_banks[s_count].size_code = sz;
    s_banks[s_count].locked = lock;
    ++s_count;
}

static void ensureInit(void)
{
    if (s_count) return;
    // Default bank set. Config_Load overrides names/occupancy/size from the Eos
    // flash config bank when a valid record is present.
    addBank(0x1, "EOS Loader", 1, EOS_BANK_SIZE_256K, 1);  // boot bank (this menu)
    addBank(0x3, "Bank 1", 0, EOS_BANK_SIZE_256K, 0);  // user 256K @ virtual 0x000000
    addBank(0x4, "Bank 2", 0, EOS_BANK_SIZE_256K, 0);  // user 256K @ virtual 0x040000
    addBank(0x5, "Bank 3", 0, EOS_BANK_SIZE_256K, 0);  // user 256K @ virtual 0x080000
    addBank(0x6, "Bank 4", 0, EOS_BANK_SIZE_256K, 0);  // user 256K @ virtual 0x0C0000
    addBank(0xA, "Recovery", 1, EOS_BANK_SIZE_256K, 1);  // recovery   @ virtual 0x1C0000
    addBank(0xD, "XbDiag Lite", 0, EOS_BANK_SIZE_256K, 1); // XbDiag slot (locked, occupied set by stamp)
}

void Bank_ResetToFactory(void)
{
    s_count = 0;     // drop the live table, re-add the default bank set
    ensureInit();
}

int Bank_Count(void) { ensureInit(); return s_count; }

const char* Bank_Name(int idx)
{
    ensureInit();
    if (idx < 0 || idx >= s_count) return "";
    return s_banks[idx].name;
}

unsigned char Bank_Ef(int idx)
{
    ensureInit();
    if (idx < 0 || idx >= s_count) return 0x1;
    return s_banks[idx].ef;
}

void Bank_SetName(int idx, const char* name)
{
    ensureInit();
    if (idx < 0 || idx >= s_count) return;
    copyName(s_banks[idx].name, name);
}

int Bank_Occupied(int idx)
{
    ensureInit();
    if (idx < 0 || idx >= s_count) return 0;
    return s_banks[idx].occupied ? 1 : 0;
}

int Bank_SizeCode(int idx)
{
    ensureInit();
    if (idx < 0 || idx >= s_count) return EOS_BANK_SIZE_256K;
    return s_banks[idx].size_code;
}

void Bank_SetOccupied(int idx, int occupied, int sizeCode)
{
    ensureInit();
    if (idx < 0 || idx >= s_count) return;
    s_banks[idx].occupied = (unsigned char)(occupied ? 1 : 0);
    s_banks[idx].size_code = (unsigned char)sizeCode;
}

// Fully clear a slot after its flash is erased: mark empty, drop to the default
// size, and restore the factory label so the deleted bank's name doesn't linger.
void Bank_ClearEntry(int idx)
{
    ensureInit();
    if (idx < 0 || idx >= s_count) return;
    s_banks[idx].occupied = 0;
    s_banks[idx].size_code = EOS_BANK_SIZE_256K;
    copyName(s_banks[idx].name, s_banks[idx].defname);
}

int Bank_IsBoot(int idx)
{
    ensureInit();
    if (idx < 0 || idx >= s_count) return 0;
    return (s_banks[idx].ef == 0x1) ? 1 : 0;
}

int Bank_IsLocked(int idx)
{
    ensureInit();
    if (idx < 0 || idx >= s_count) return 1;   // out-of-range treated as locked (safe)
    return s_banks[idx].locked ? 1 : 0;
}

int Bank_LaunchCount(void)
{
    int i, n;
    ensureInit();
    n = 0;
    for (i = 0; i < s_count; ++i)
        if (s_banks[i].occupied && s_banks[i].ef != 0x1) ++n;
    return n;
}

int Bank_LaunchIndex(int n)
{
    int i, k;
    ensureInit();
    k = 0;
    for (i = 0; i < s_count; ++i) {
        if (s_banks[i].occupied && s_banks[i].ef != 0x1) {
            if (k == n) return i;
            ++k;
        }
    }
    return -1;
}

int Bank_CapacityBytes(int idx)
{
    unsigned char ef;
    ensureInit();
    if (idx < 0 || idx >= s_count) return 256 * 1024;
    ef = s_banks[idx].ef;
    if (ef == 0x2) return 512 * 1024;           // 512K bank
    if (ef == 0x9) return 1024 * 1024;          // 1MB bank
    return 256 * 1024;                          // 256K (default user/recovery/loader)
}

// --- low-level I/O port access (x86 IN/OUT) ---------------------------------
// Port 0xEF is unclaimed by the MCPX and forwarded to the LPC bus, where the
// Eos FPGA decodes it (the loader generates ef_wr on this write).
static void io_out8(unsigned short port, unsigned char val)
{
    __asm
    {
        mov dx, port
        mov al, val
        out dx, al
    }
}

static unsigned char io_in8(unsigned short port)
{
    unsigned char v;
    __asm
    {
        mov dx, port
        in  al, dx
        mov v, al
    }
    return v;
}

// --- raw nForce SMBus byte write (self-contained; no kernel import) ----------
// HalWriteSMBusValue is not resolvable by the RXDK linker for this project
// (same issue XbDiag hit), so we drive the nForce SMBus controller directly,
// the way Cromwell / the Xbox 2BL does. Register block base 0xC000:
//   0xC000 status (W1C)   0xC002 control/protocol   0xC004 address (7-bit<<1|RW)
//   0xC006 data           0xC008 command
// Protocol 0x0A = byte-data transaction + start.
static void smbus_write_byte(unsigned char addr7, unsigned char cmd, unsigned char val)
{
    volatile int t;

    // wait until not busy (bit3), bounded
    for (t = 0; t < 100000; ++t) { if (!(io_in8(0xC000) & 0x08)) break; }

    io_out8(0xC000, io_in8(0xC000));        // clear status (write-1-to-clear readback)
    io_out8(0xC004, (unsigned char)(addr7 << 1)); // slave address, write (RW=0)
    io_out8(0xC008, cmd);                    // command / register
    io_out8(0xC006, val);                    // data byte
    io_out8(0xC002, 0x0A);                   // byte-data protocol + start

    // poll for completion (bit4) or error, bounded
    for (t = 0; t < 100000; ++t) {
        unsigned char st = io_in8(0xC000);
        if (st & 0x10) break;                // cycle complete
        if (st & 0x24) break;                // error/abort
    }
}

void Bank_SetResting(void)
{
    io_out8(0x00EF, 0x01);   // boot bank = safe resting selection
}

void Bank_Launch(int idx)
{
    unsigned char ef;
    volatile int  s;

    ensureInit();
    ef = Bank_Ef(idx);

    // 1) select the bank in the FPGA (persists across the warm reset)
    io_out8(0x00EF, ef);

    // 2) small settle so the 0xEF write completes on the LPC bus before reset
    for (s = 0; s < 200000; ++s) {}

    // 3) SMC warm reset (PIC 7-bit 0x10, cmd 0x02 power, 0x01 = reliable warm
    //    reset) -> Xbox reboots and the FPGA serves the selected bank.
    smbus_write_byte(0x10, 0x02, 0x01);

    // SMC pulls the reset within ~ms; spin so we never fall through
    for (;;) {}
}

// Eos_TsopBoot -- release D0 and warm-reset so the box boots the onboard TSOP.
// Sets the FPGA's persistent stock-boot bit (flash-cmd index 0x08 via 0xEC/0xED,
// data bit0 = 1). That bit lives in the FPGA cold-reset domain, so it survives
// the warm reset; D0 is released before the MCPX re-samples it and the console
// boots stock instead of Eos. A COLD power cycle reconfigures the FPGA, clears
// the bit, and Eos boots again -- one-shot and self-recovering. Does not return.
void Eos_TsopBoot(void)
{
    volatile int s;

    // 1) persistent stock-boot bit: 0xEC = index 0x08 (BOOT), 0xED = 0x01 (bit0)
    io_out8(0x00EC, 0x08);
    io_out8(0x00ED, 0x01);

    // 2) settle so the LPC writes commit before the reset
    for (s = 0; s < 200000; ++s) {}

    // 3) same SMC warm reset Bank_Launch uses (PIC 0x10, cmd 0x02, 0x01 = warm)
    smbus_write_byte(0x10, 0x02, 0x01);

    for (;;) {}
}

// Bank_XbDiagPresent -- 1 if XbDiag Lite is installed in bank 0xD. Probes page 0
// of the slot ONCE (cached): an all-0xFF page means blank / not installed. Gates
// whether the launch menu shows XbDiag at all. If the FPGA bitstream lacks 0xD
// support the read is refused and this returns 0 (XbDiag stays hidden).
static int s_diagChecked = 0;
static int s_diagPresent = 0;
int Bank_XbDiagPresent(void)
{
    unsigned char pg[256];
    int i, rc;
    if (s_diagChecked) return s_diagPresent;
    s_diagChecked = 1;
    rc = Flash_ReadPage(0xD, 0, pg);
    if (rc == EOS_FLASH_OK) {
        for (i = 0; i < 256; ++i) {
            if (pg[i] != 0xFF) { s_diagPresent = 1; break; }
        }
    }
    return s_diagPresent;
}

// Eos_LaunchXbDiag -- page XbDiag Lite (bank 0xD) into the served SDRAM copy, then
// select + SMC warm-reset into it. Flash_Sync blocks until the flash->SDRAM reload
// finishes, so the image is resident before the MCPX reads it. Real banks skip this
// (they live in the resident preload); XbDiag sits past it and is paged in on demand.
// Does not return on hardware.
void Eos_LaunchXbDiag(void)
{
    volatile int s;

    Flash_Sync(0xD);                      // reload 0xD flash -> SDRAM, waits for done
    io_out8(0x00EF, 0xD);                 // select for serve (persists across warm reset)
    for (s = 0; s < 200000; ++s) {}
    smbus_write_byte(0x10, 0x02, 0x01);   // SMC warm reset -> boots XbDiag
    for (;;) {}
}

void Bank_TestWrite(int idx)
{
    ensureInit();
    io_out8(0x00EF, Bank_Ef(idx));   // select, but do NOT reset
}

unsigned char Bank_ReadEf(void)
{
    return io_in8(0x00EF);           // FPGA echoes the last 0xEF write
}