// eos_stage.cpp -- see eos_stage.h. Host side of the IDX_SCR_* scratch contract.
#include <xtl.h>
#include "eos_stage.h"

#define EOS_PORT_INDEX   0x00EC
#define EOS_PORT_DATA    0x00ED

/* scratch registers in eos_flash_cmd (index via 0xEC, r/w via 0xED) */
#define IDX_STATUS       0x06     /* bit4 = scr_busy */
#define IDX_SCR_ALO      0x09     /* scratch addr [7:0]   */
#define IDX_SCR_AMID     0x0A     /* scratch addr [15:8]  */
#define IDX_SCR_AHI      0x0B     /* scratch addr [20:16] */
#define IDX_SCR_DATA     0x0C     /* write a byte, auto-increment */

#define STATUS_SCR_BUSY  0x10     /* STATUS bit4 */
#define DRAIN_POLL_EVERY 64       /* let the backend catch up every N bytes */

/* ---- port I/O (self-contained, mirrors the loader's per-module pattern) ---- */
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

/* wait for the scratch port to drain; bounded. TRUE if idle, FALSE on timeout. */
static BOOL wait_scr_idle(void)
{
    volatile int t;
    io_out8(EOS_PORT_INDEX, IDX_STATUS);      /* park index on STATUS */
    for (t = 0; t < 200000; ++t) {
        if (!(io_in8(EOS_PORT_DATA) & STATUS_SCR_BUSY)) return TRUE;
    }
    return FALSE;
}

/* ---- public --------------------------------------------------------------- */
void Stage_Begin(DWORD scratch_offset)
{
    regw(IDX_SCR_ALO, (unsigned char)(scratch_offset & 0xFF));
    regw(IDX_SCR_AMID, (unsigned char)((scratch_offset >> 8) & 0xFF));
    regw(IDX_SCR_AHI, (unsigned char)((scratch_offset >> 16) & 0x1F));
}

BOOL Stage_Write(const unsigned char* data, int len)
{
    int i;
    if (!data || len <= 0) return TRUE;
    if (!wait_scr_idle()) return FALSE;
    io_out8(EOS_PORT_INDEX, IDX_SCR_DATA);        /* park index once */
    for (i = 0; i < len; ++i) {
        io_out8(EOS_PORT_DATA, data[i]);          /* data-only; FPGA auto-increments addr */
        if (((i + 1) % DRAIN_POLL_EVERY) == 0) {
            if (!wait_scr_idle()) return FALSE;    /* (re-parks index on STATUS to poll) */
            io_out8(EOS_PORT_INDEX, IDX_SCR_DATA); /* re-park on DATA after the poll */
        }
    }
    return wait_scr_idle();
}

BOOL Stage_Image(const unsigned char* data, int len)
{
    Stage_Begin(0);
    return Stage_Write(data, len);
}

BOOL Stage_Busy(void)
{
    io_out8(EOS_PORT_INDEX, IDX_STATUS);
    return (io_in8(EOS_PORT_DATA) & STATUS_SCR_BUSY) ? TRUE : FALSE;
}

DWORD Stage_Pointer(void)
{
    DWORD p;
    p = (DWORD)regr(IDX_SCR_ALO);
    p |= (DWORD)regr(IDX_SCR_AMID) << 8;
    p |= (DWORD)(regr(IDX_SCR_AHI) & 0x1F) << 16;
    return p;
}