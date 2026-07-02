// eos_flash.cpp -- Eos flash command driver (host side of the 0xEC/0xED contract).
// See eos_flash.h. Self-contained: own port-I/O, no kernel imports.
#include "eos_flash.h"

// --- command interface ports ------------------------------------------------
#define EOS_PORT_INDEX   0x00EC
#define EOS_PORT_DATA    0x00ED

// --- register indices (select via 0xEC, then r/w via 0xED) ------------------
#define IDX_OP           0x00
#define IDX_BANK         0x01
#define IDX_PAGELO       0x02
#define IDX_PAGEHI       0x03
#define IDX_PBUF         0x04
#define IDX_GO           0x05
#define IDX_STATUS       0x06
#define IDX_LASTSTAT     0x07

// --- ops --------------------------------------------------------------------
#define OP_ERASE         0
#define OP_PROGRAM       1
#define OP_READ          2
#define OP_SYNC          3   // reload the whole selected bank flash->SDRAM

// --- STATUS bits ------------------------------------------------------------
#define ST_BUSY          0x01
#define ST_DONE          0x02
#define ST_REFUSED       0x04
#define ST_RELOAD        0x08   // SDRAM reload in progress (post-flash)

// Bound on the busy-poll. Each iteration is an LPC I/O read (~1us); a worst-case
// 1MB bank erase is a few seconds, so this is generous headroom, not a tuned value.
#define POLL_LIMIT       60000000L

// --- low-level port I/O (x86 IN/OUT) ----------------------------------------
// Ports 0xEC/0xED are unclaimed by the MCPX and forwarded to the LPC bus, where
// the Eos FPGA decodes them. Identical pattern to eos_bank.cpp's 0xEF access.
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

// --- register helpers -------------------------------------------------------
static void regw(unsigned char idx, unsigned char val)
{
    io_out8(EOS_PORT_INDEX, idx);
    io_out8(EOS_PORT_DATA, val);
}

static unsigned char regr(unsigned char idx)
{
    io_out8(EOS_PORT_INDEX, idx);
    return io_in8(EOS_PORT_DATA);
}

// Wait for the engine to finish the in-flight op.
// GO clears the sticky 'done', so we wait for (!busy && done); 'refused' is
// sticky until the next GO, so it is safe to test here too.
static int waitDone(void)
{
    volatile long t;
    unsigned char st;

    io_out8(EOS_PORT_INDEX, IDX_STATUS);   // park index on STATUS; poll DATA
    for (t = 0; t < POLL_LIMIT; ++t) {
        st = io_in8(EOS_PORT_DATA);
        if (st & ST_REFUSED) return EOS_FLASH_REFUSED;
        if (!(st & ST_BUSY) && (st & ST_DONE)) return EOS_FLASH_OK;
    }
    return EOS_FLASH_TIMEOUT;
}

// After a SYNC, wait for the backend's flash->SDRAM reload to actually finish.
// 'done' only means the command was accepted -- the reload runs on in the
// backend and is visible as STATUS bit3. A full-bank reload holds that bit high
// for many milliseconds, so phase 1 reliably catches the rising edge; if it
// never rises (nothing to copy) we simply fall through as already-current.
static int waitReload(void)
{
    volatile long t;
    unsigned char st;
    int started = 0;

    io_out8(EOS_PORT_INDEX, IDX_STATUS);
    for (t = 0; t < POLL_LIMIT; ++t) {        // phase 1: reload begins
        st = io_in8(EOS_PORT_DATA);
        if (st & ST_REFUSED) return EOS_FLASH_REFUSED;
        if (st & ST_RELOAD) { started = 1; break; }
        if (t > 100000L) break;               // never started -> nothing to reload
    }
    if (!started) return EOS_FLASH_OK;
    for (t = 0; t < POLL_LIMIT; ++t) {        // phase 2: reload completes
        st = io_in8(EOS_PORT_DATA);
        if (!(st & ST_RELOAD)) return EOS_FLASH_OK;
    }
    return EOS_FLASH_TIMEOUT;
}

int Flash_EraseBank(int bankEf)
{
    regw(IDX_OP, (unsigned char)OP_ERASE);
    regw(IDX_BANK, (unsigned char)(bankEf & 0x0F));
    regw(IDX_GO, 1);
    return waitDone();
}

int Flash_ProgramPage(int bankEf, int page, const unsigned char* data256)
{
    int i;

    // Selecting PBUF resets the engine's page-buffer pointer; 256 DATA writes
    // then fill the page (auto-incrementing).
    io_out8(EOS_PORT_INDEX, IDX_PBUF);
    for (i = 0; i < 256; ++i)
        io_out8(EOS_PORT_DATA, data256[i]);

    regw(IDX_OP, (unsigned char)OP_PROGRAM);
    regw(IDX_BANK, (unsigned char)(bankEf & 0x0F));
    regw(IDX_PAGELO, (unsigned char)(page & 0xFF));
    regw(IDX_PAGEHI, (unsigned char)((page >> 8) & 0x0F));
    regw(IDX_GO, 1);
    return waitDone();
}

int Flash_ReadPage(int bankEf, int page, unsigned char* out256)
{
    int rc, i;

    regw(IDX_OP, (unsigned char)OP_READ);
    regw(IDX_BANK, (unsigned char)(bankEf & 0x0F));
    regw(IDX_PAGELO, (unsigned char)(page & 0xFF));
    regw(IDX_PAGEHI, (unsigned char)((page >> 8) & 0x0F));
    regw(IDX_GO, 1);
    rc = waitDone();
    if (rc != EOS_FLASH_OK) return rc;

    // Engine has the page in its buffer; selecting PBUF resets the read pointer,
    // then each DATA read streams the next byte (auto-incrementing).
    io_out8(EOS_PORT_INDEX, IDX_PBUF);
    for (i = 0; i < 256; ++i)
        out256[i] = io_in8(EOS_PORT_DATA);

    return EOS_FLASH_OK;
}

int Flash_Sync(int bankEf)
{
    int rc;
    regw(IDX_OP, (unsigned char)OP_SYNC);
    regw(IDX_BANK, (unsigned char)(bankEf & 0x0F));
    regw(IDX_GO, 1);
    rc = waitDone();                 // command accepted
    if (rc != EOS_FLASH_OK) return rc;
    return waitReload();             // SDRAM copy now matches flash
}

int Flash_WriteImage(int bankEf, const unsigned char* data, int len)
{
    int           rc, pages, page, off, i;
    unsigned char pg[256];

    rc = Flash_EraseBank(bankEf);
    if (rc != EOS_FLASH_OK) return rc;

    pages = (len + 255) / 256;
    for (page = 0; page < pages; ++page) {
        off = page * 256;
        for (i = 0; i < 256; ++i)
            pg[i] = (off + i < len) ? data[off + i] : 0xFF;   // pad tail with 0xFF

        rc = Flash_ProgramPage(bankEf, page, pg);
        if (rc != EOS_FLASH_OK) return rc;
    }

    // Programs write flash but no longer self-refresh SDRAM (per-page reloads
    // were dropped back-to-back). One full-bank SYNC makes the served copy match.
    return Flash_Sync(bankEf);
}

unsigned char Flash_RawStatus(void) { return regr(IDX_STATUS); }
unsigned char Flash_LastFlashSR(void) { return regr(IDX_LASTSTAT); }