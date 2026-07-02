#pragma once
// eos_smbus.h -- Xbox-side SMBus master to the Eos control device at 7-bit 0x6E.
//
// Drives the nForce SMBus controller directly (mirrors the loader's eos_bank /
// eos_console primitives) because HalReadSMBusValue / HalWriteSMBusValue do not
// resolve under RXDK for this project. This is the control plane for the update
// datapath: ARM -> (stage over LPC) -> SETCRC -> VALIDATE -> COMMIT, plus CLEAR.
//
// Register map matches the FPGA's eos_i2c:
//   0x00 magic(0xD8)  0x01/02/03 ver maj/min/pat  0x04 boot/serve status
//   0x05 engine status (bits below)   0x06 {bank<<4 | armed_region}
//   0x07..0x0A computed CRC-32 (LE)   0x0B/0x0C lock mask
//   0x10 CMD (write triggers action)  0x11..0x14 ARG0..3
#include <xtl.h>

#define EOS_SMB_ADDR      0x6E     /* 7-bit slave address */
#define EOS_MAGIC         0xD8

/* registers */
#define EOS_REG_MAGIC     0x00
#define EOS_REG_VER_MAJ   0x01
#define EOS_REG_VER_MIN   0x02
#define EOS_REG_VER_PAT   0x03
#define EOS_REG_STATUS    0x04     /* boot/serve bits (preload/mode16/d0/abort) */
#define EOS_REG_ESTAT     0x05     /* engine status */
#define EOS_REG_REGION    0x06     /* {commit_bank[7:4], armed_region[3:0]} */
#define EOS_REG_CRC0      0x07     /* CRC-32 result, little-endian 0x07..0x0A */
#define EOS_REG_LOCK_LO   0x0B
#define EOS_REG_LOCK_HI   0x0C
#define EOS_REG_CMD       0x10
#define EOS_REG_ARG0      0x11
#define EOS_REG_ARG1      0x12
#define EOS_REG_ARG2      0x13
#define EOS_REG_ARG3      0x14

/* engine status (0x05) bits */
#define EOS_ST_ARMED      0x01
#define EOS_ST_CRCSET     0x02
#define EOS_ST_VALID      0x04
#define EOS_ST_BUSY       0x08
#define EOS_ST_ERR        0x10
#define EOS_ST_COMMITOK   0x20

/* regions = high nibble of the command byte */
#define EOS_RGN_LOADER    0x1
#define EOS_RGN_XBDIAG    0x2
#define EOS_RGN_BANK      0x3

/* actions = low nibble */
#define EOS_ACT_ARM       0x0
#define EOS_ACT_SETCRC    0x1
#define EOS_ACT_VALIDATE  0x3
#define EOS_ACT_COMMIT    0x4

/* system commands (full byte) */
#define EOS_CMD_PING      0x01
#define EOS_CMD_ABORT     0x02
#define EOS_CMD_CLEAR     0x03
/* bank-only full-byte commands */
#define EOS_CMD_SELECT    0x30
#define EOS_CMD_BOOTMODE  0x36
#define EOS_CMD_SETLOCK   0x37

#define EOS_CMD(region, action)  (BYTE)(((region) << 4) | (action))

/* ---- raw register access ---- */
BOOL Smb_ReadReg(BYTE reg, BYTE* val);
BOOL Smb_WriteReg(BYTE reg, BYTE val);

/* ---- presence / identity ---- */
BOOL Smb_Present(void);                              /* magic reads back 0xD8 */
BOOL Smb_ReadVersion(BYTE* maj, BYTE* min, BYTE* pat);
BYTE Smb_Status(void);                               /* engine status (0x05); 0xFF on bus error */
BOOL Smb_ReadCrc(DWORD* crc);                        /* computed CRC (0x07..0x0A) */
BYTE Smb_ArmedRegion(void);                          /* low nibble of 0x06 */

/* ---- command choreography (operand-before-strobe) ---- */
/* args are written to 0x11..0x14 first, then the CMD to 0x10 triggers the FPGA. */
BOOL Smb_Command(BYTE cmd);                          /* no-arg strobe */
BOOL Smb_CommandArgs(BYTE cmd, BYTE a0, BYTE a1, BYTE a2, BYTE a3);

/* ---- high-level update ops ---- */
/* region = EOS_RGN_*; len = image byte count; bank only used for EOS_RGN_BANK. */
BOOL Smb_Arm(BYTE region, DWORD len, BYTE bank);
BOOL Smb_SetCrc(BYTE region, DWORD crc);
BOOL Smb_Validate(BYTE region);                      /* async: poll Smb_WaitDone */
BOOL Smb_Commit(BYTE region);                        /* async: poll Smb_WaitDone */
BOOL Smb_Clear(void);                                /* disarm + invalidate + scr_clear */

/* Poll engine status until BUSY clears or timeout. Returns the final status
   byte (check EOS_ST_VALID / EOS_ST_COMMITOK / EOS_ST_ERR); 0xFF on bus error. */
BYTE Smb_WaitDone(int timeout_ms);

/* Poll ESTAT until (status & flag) is set, or timeout. Returns 1 if the flag
   appeared, 0 on timeout/bus error. Confirms ARM/SETCRC latched before the
   next command (the command queue's between-step gate). */
int  Smb_WaitFlag(BYTE flag, int timeout_ms);

/* Wait for an async op keyed on a completion FLAG (EOS_ST_VALID or
   EOS_ST_COMMITOK) rather than BUSY-clear. Confirms the engine started
   before judging completion, curing the post-strobe race. Returns the final
   status byte; 0xFF on persistent bus error. */
BYTE Smb_WaitOp(BYTE doneFlag, int timeout_ms);