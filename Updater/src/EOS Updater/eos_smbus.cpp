// eos_smbus.cpp -- see eos_smbus.h.
// Direct nForce SMBus master, mirroring the loader's eos_bank/eos_console
// primitives (HalRead/WriteSMBusValue don't resolve under RXDK here).
//
// nForce SMBus register block base 0xC000:
//   0xC000 status (W1C)   0xC002 control/protocol   0xC004 address (7-bit<<1|RW)
//   0xC006 data           0xC008 command
//   status: bit3 busy, bit4 complete, 0x24 = error/abort
//   protocol 0x0A = byte-data transaction + start
#include <xtl.h>
#include "eos_smbus.h"
#include "xboxinternals.h"     /* KeStallExecutionProcessor */

#define SMB_STATUS   0xC000
#define SMB_CONTROL  0xC002
#define SMB_ADDRESS  0xC004
#define SMB_DATA     0xC006
#define SMB_COMMAND  0xC008
#define SMB_PROTO_BYTE 0x0A

/* ---- port I/O (mirror of the loader) -------------------------------------- */
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

/* ---- raw nForce byte write ------------------------------------------------ */
static BOOL smbus_write_byte_once(unsigned char addr7, unsigned char cmd, unsigned char val)
{
    volatile int  t;
    unsigned char st;

    for (t = 0; t < 100000; ++t) { if (!(io_in8(SMB_STATUS) & 0x08)) break; }

    io_out8(SMB_STATUS, io_in8(SMB_STATUS));                 /* clear status (W1C) */
    io_out8(SMB_ADDRESS, (unsigned char)(addr7 << 1));       /* write (RW=0) */
    io_out8(SMB_COMMAND, cmd);
    io_out8(SMB_DATA, val);
    io_out8(SMB_CONTROL, SMB_PROTO_BYTE);                    /* byte-data + start */

    for (t = 0; t < 100000; ++t) {
        st = io_in8(SMB_STATUS);
        if (st & 0x10) return TRUE;                          /* complete */
        if (st & 0x24) return FALSE;                         /* error/abort */
    }
    return FALSE;                                            /* timeout */
}

/* ---- raw nForce byte read (RW=1) ------------------------------------------ */
static BOOL smbus_read_byte_once(unsigned char addr7, unsigned char cmd, unsigned char* val)
{
    volatile int  t;
    unsigned char st;

    for (t = 0; t < 100000; ++t) { if (!(io_in8(SMB_STATUS) & 0x08)) break; }

    io_out8(SMB_STATUS, io_in8(SMB_STATUS));                 /* clear status (W1C) */
    io_out8(SMB_ADDRESS, (unsigned char)((addr7 << 1) | 1)); /* read (RW=1) */
    io_out8(SMB_COMMAND, cmd);
    io_out8(SMB_CONTROL, SMB_PROTO_BYTE);                    /* byte-data + start */

    for (t = 0; t < 100000; ++t) {
        st = io_in8(SMB_STATUS);
        if (st & 0x10) { *val = io_in8(SMB_DATA); return TRUE; }   /* complete */
        if (st & 0x24) return FALSE;                               /* error/abort */
    }
    return FALSE;                                                  /* timeout */
}

/* ---- retry wrappers -------------------------------------------------------
   The Xbox SMBus is shared (SMC, sensors, EEPROM...). A long VALIDATE polls
   status ~hundreds of times; an occasional transaction abort from bus
   contention is normal and must NOT fail the operation. Retry a few times
   with a short settle before giving up, so only a persistently dead bus
   returns failure. */
#define SMB_RETRIES 8

static BOOL smbus_write_byte(unsigned char addr7, unsigned char cmd, unsigned char val)
{
    int a;
    for (a = 0; a < SMB_RETRIES; ++a) {
        if (smbus_write_byte_once(addr7, cmd, val)) return TRUE;
        KeStallExecutionProcessor(150);          /* let the shared bus settle */
    }
    return FALSE;
}

static BOOL smbus_read_byte(unsigned char addr7, unsigned char cmd, unsigned char* val)
{
    int a;
    for (a = 0; a < SMB_RETRIES; ++a) {
        if (smbus_read_byte_once(addr7, cmd, val)) return TRUE;
        KeStallExecutionProcessor(150);
    }
    return FALSE;
}

/* ---- verified register write ---------------------------------------------
   The Eos FPGA echoes every ARG/CMD register on read, so we can confirm a
   write actually landed rather than trusting a possibly-lost bus ack. This is
   the core of the command queue: ARG registers are idempotent (writing the
   same value twice is harmless), so we retry-with-verify freely. The CMD
   register (0x10) pulses cmd_stb on EVERY write, so it must be strobed exactly
   ONCE -- never inside a blind retry. */
static BOOL smb_write_verified(unsigned char reg, unsigned char val)
{
    int a; unsigned char rb;
    for (a = 0; a < SMB_RETRIES; ++a) {
        if (smbus_write_byte_once(EOS_SMB_ADDR, reg, val)) {
            /* confirm by reading it back */
            if (smbus_read_byte_once(EOS_SMB_ADDR, reg, &rb) && rb == val) return TRUE;
        }
        KeStallExecutionProcessor(150);
    }
    return FALSE;
}

/* Strobe the CMD register exactly once, no retry (cmd_stb pulses per write).
   A single lost ack here is tolerated by the caller confirming the engine
   state (ARMED/CRCSET/BUSY) transitioned, rather than re-strobing. */
static BOOL smb_strobe_cmd(unsigned char cmd)
{
    return smbus_write_byte_once(EOS_SMB_ADDR, EOS_REG_CMD, cmd);
}

/* ---- register access ------------------------------------------------------ */
BOOL Smb_ReadReg(BYTE reg, BYTE* val) { return smbus_read_byte(EOS_SMB_ADDR, reg, val); }
BOOL Smb_WriteReg(BYTE reg, BYTE val) { return smbus_write_byte(EOS_SMB_ADDR, reg, val); }

/* ---- presence / identity -------------------------------------------------- */
BOOL Smb_Present(void)
{
    BYTE v;
    if (!Smb_ReadReg(EOS_REG_MAGIC, &v)) return FALSE;
    return (v == EOS_MAGIC);
}

BOOL Smb_ReadVersion(BYTE* maj, BYTE* min, BYTE* pat)
{
    BYTE a, b, c;
    if (!Smb_ReadReg(EOS_REG_VER_MAJ, &a)) return FALSE;
    if (!Smb_ReadReg(EOS_REG_VER_MIN, &b)) return FALSE;
    if (!Smb_ReadReg(EOS_REG_VER_PAT, &c)) return FALSE;
    if (maj) *maj = a;
    if (min) *min = b;
    if (pat) *pat = c;
    return TRUE;
}

BYTE Smb_Status(void)
{
    BYTE v;
    if (!Smb_ReadReg(EOS_REG_ESTAT, &v)) return 0xFF;
    return v;
}

BYTE Smb_ArmedRegion(void)
{
    BYTE v;
    if (!Smb_ReadReg(EOS_REG_REGION, &v)) return 0xFF;
    return (BYTE)(v & 0x0F);
}

BOOL Smb_ReadCrc(DWORD* crc)
{
    BYTE b0, b1, b2, b3;
    if (!Smb_ReadReg(EOS_REG_CRC0 + 0, &b0)) return FALSE;
    if (!Smb_ReadReg(EOS_REG_CRC0 + 1, &b1)) return FALSE;
    if (!Smb_ReadReg(EOS_REG_CRC0 + 2, &b2)) return FALSE;
    if (!Smb_ReadReg(EOS_REG_CRC0 + 3, &b3)) return FALSE;
    if (crc) *crc = ((DWORD)b3 << 24) | ((DWORD)b2 << 16) | ((DWORD)b1 << 8) | (DWORD)b0;
    return TRUE;
}

/* ---- command choreography ------------------------------------------------- */
/* Each SMBus write is a complete transaction, so writing ARG0..3 before CMD
   guarantees the args are latched when the CMD write pulses cmd_stb. */
BOOL Smb_Command(BYTE cmd)
{
    unsigned char rb;
    if (smb_strobe_cmd(cmd)) return TRUE;
    if (smbus_read_byte_once(EOS_SMB_ADDR, EOS_REG_CMD, &rb) && rb == cmd) return TRUE;
    return FALSE;
}

BOOL Smb_CommandArgs(BYTE cmd, BYTE a0, BYTE a1, BYTE a2, BYTE a3)
{
    unsigned char rb;
    /* Args first, each verified by readback (idempotent -- safe to retry). */
    if (!smb_write_verified(EOS_REG_ARG0, a0)) return FALSE;
    if (!smb_write_verified(EOS_REG_ARG1, a1)) return FALSE;
    if (!smb_write_verified(EOS_REG_ARG2, a2)) return FALSE;
    if (!smb_write_verified(EOS_REG_ARG3, a3)) return FALSE;
    /* CMD strobe: exactly once. If the ack is lost we do NOT re-strobe
       (that would double-pulse cmd_stb and desync the engine). Instead we
       read CMD back -- the FPGA latched it into its cmd register -- and
       accept success if it reflects our opcode. A genuinely-dropped strobe
       leaves the old cmd there and the caller retries the whole sequence. */
    if (smb_strobe_cmd(cmd)) return TRUE;
    if (smbus_read_byte_once(EOS_SMB_ADDR, EOS_REG_CMD, &rb) && rb == cmd) return TRUE;
    return FALSE;
}

/* ---- high-level update ops ------------------------------------------------ */
BOOL Smb_Arm(BYTE region, DWORD len, BYTE bank)
{
    if (region == EOS_RGN_BANK) {
        /* bank ARM: ARG0 = target bank ef, ARG1..3 = length (LE, 21-bit) */
        return Smb_CommandArgs(EOS_CMD(EOS_RGN_BANK, EOS_ACT_ARM),
            (BYTE)(bank & 0x0F),
            (BYTE)(len & 0xFF),
            (BYTE)((len >> 8) & 0xFF),
            (BYTE)((len >> 16) & 0x1F));
    }
    /* loader / xbdiag ARM: ARG0..2 = length (LE, 21-bit), ARG3 unused */
    return Smb_CommandArgs(EOS_CMD(region, EOS_ACT_ARM),
        (BYTE)(len & 0xFF),
        (BYTE)((len >> 8) & 0xFF),
        (BYTE)((len >> 16) & 0x1F),
        0x00);
}

BOOL Smb_SetCrc(BYTE region, DWORD crc)
{
    return Smb_CommandArgs(EOS_CMD(region, EOS_ACT_SETCRC),
        (BYTE)(crc & 0xFF),
        (BYTE)((crc >> 8) & 0xFF),
        (BYTE)((crc >> 16) & 0xFF),
        (BYTE)((crc >> 24) & 0xFF));
}

BOOL Smb_Validate(BYTE region)
{
    return Smb_Command(EOS_CMD(region, EOS_ACT_VALIDATE));
}

BOOL Smb_Commit(BYTE region)
{
    return Smb_Command(EOS_CMD(region, EOS_ACT_COMMIT));
}

BOOL Smb_Clear(void)
{
    return Smb_Command(EOS_CMD_CLEAR);
}

/* ---- wait for an async op (VALIDATE / COMMIT) ----------------------------- */
BYTE Smb_WaitDone(int timeout_ms)
{
    int  waited;
    BYTE st;

    /* poll ~1ms apart; give the engine a moment to raise BUSY first */
    for (waited = 0; waited <= timeout_ms; waited += 4) {
        st = Smb_Status();
        if (st == 0xFF) return 0xFF;               /* persistent bus error (post-retry) */
        if (!(st & EOS_ST_BUSY) && waited > 1)     /* settled, not busy */
            return st;
        KeStallExecutionProcessor(4000);           /* 4 ms: lighter load on shared bus */
    }
    return Smb_Status();                            /* timed out; return last */
}

int Smb_WaitFlag(BYTE flag, int timeout_ms)
{
    int waited; BYTE st;
    for (waited = 0; waited <= timeout_ms; waited += 4) {
        st = Smb_Status();
        if (st != 0xFF && (st & flag)) return 1;
        KeStallExecutionProcessor(4000);
    }
    return 0;
}

/* Wait for an async engine op (VALIDATE / COMMIT) that keys on completion
   FLAGS rather than merely on BUSY clearing. The old BUSY-only wait had a
   race: right after the strobe the engine has not raised BUSY yet, so the
   first poll saw !BUSY and returned the stale pre-op status (neither done nor
   err) -> spurious 'refused/failed'. Here we:
     1. give the engine a moment and watch for it to raise BUSY, OR for a
        completion flag / ERR to appear (a refused op sets ERR without BUSY);
     2. once BUSY is seen (or a terminal flag), poll until a terminal flag
        (doneFlag | ERR) is set or we time out.
   Returns the final status byte; 0xFF on persistent bus error.
   doneFlag = EOS_ST_VALID (validate) or EOS_ST_COMMITOK (commit). */
BYTE Smb_WaitOp(BYTE doneFlag, int timeout_ms)
{
    /* Transition-aware async wait. The engine's status flags are STICKY:
       after VALIDATE, EOS_ST_VALID stays set; a prior COMMIT can leave
       EOS_ST_COMMITOK set. So we must NOT judge completion by simply seeing
       doneFlag -- a stale flag would return instantly. Instead:
         Phase 1: wait for the engine to START (raise BUSY). A refused op
                  never goes busy but sets ERR promptly -- detect that as a
                  refusal within a short window.
         Phase 2: engine is running -> wait for BUSY to drop, then read the
                  terminal flags (doneFlag = success, ERR = failure).
       Returns the final status byte; 0xFF on persistent bus error. */
    int  waited;
    int  sawBusy = 0;
    BYTE st;

    /* Phase 1: confirm the op was accepted (BUSY rises) or refused (ERR rises
       without BUSY). Bounded to ~300ms -- the FPGA raises BUSY the same cycle
       it accepts the strobe, so this resolves in a few polls. */
    for (waited = 0; waited < 300; waited += 4) {
        st = Smb_Status();
        if (st == 0xFF) { KeStallExecutionProcessor(4000); continue; }
        if (st & EOS_ST_BUSY) { sawBusy = 1; break; }        /* accepted, running */
        if (st & EOS_ST_ERR) { return st; }                 /* refused outright */
        KeStallExecutionProcessor(4000);
    }
    if (!sawBusy) {
        /* Never observed BUSY and no ERR. Two cases:
           (a) the op is very fast and BUSY came and went between polls, or
           (b) the strobe was dropped. Give one more read: if a terminal flag
           is present treat it as done, else report refusal via last status. */
        st = Smb_Status();
        if (st != 0xFF && (st & (BYTE)(doneFlag | EOS_ST_ERR))) return st;
        return st;   /* neither started nor terminal -> caller sees no doneFlag */
    }

    /* Phase 2: engine is running. Wait for BUSY to drop, then the terminal
       flags are valid. We poll BUSY (not the sticky flags) as the completion
       edge, then read doneFlag/ERR once BUSY is low. */
    for (waited = 0; waited <= timeout_ms; waited += 4) {
        st = Smb_Status();
        if (st != 0xFF && !(st & EOS_ST_BUSY)) {
            /* BUSY dropped: completion latched this cycle. Re-read once so the
               terminal flag (set the same cycle BUSY clears) is visible. */
            KeStallExecutionProcessor(4000);
            st = Smb_Status();
            return st;                 /* caller checks doneFlag vs ERR */
        }
        KeStallExecutionProcessor(4000);
    }
    return Smb_Status();               /* timed out while busy */
}