#pragma once
// eos_stage.h -- stream an update image into the FPGA's SDRAM scratch region
// over LPC, via the flash command bridge's scratch registers (0xEC/0xED).
//
// This is the bulk-data path: the image rides LPC (fast), NOT SMBus. The SMBus
// control plane (eos_smbus) only orchestrates (ARM / SETCRC / VALIDATE / COMMIT);
// the bytes land here. Nothing reaches flash until a gated COMMIT, so scratch is
// disposable and staging needs no confirmation.
//
// Flow:  Stage_Begin(0);  Stage_Write(buf, n) repeatedly;  then CRC + VALIDATE.
// Scratch offset auto-increments in the FPGA after each byte, so a normal image
// is Stage_Begin(0) followed by a single streamed pass.
#include <xtl.h>

/* Set the scratch write pointer (byte offset within scratch, 0..0x1FFFFF). */
void Stage_Begin(DWORD scratch_offset);

/* Stream len bytes to scratch at the current pointer (auto-increments).
   Returns TRUE on success, FALSE if the scratch port never drained (timeout). */
BOOL Stage_Write(const unsigned char* data, int len);

/* Stage a whole image at scratch offset 0 in one call. */
BOOL Stage_Image(const unsigned char* data, int len);

/* TRUE while the FPGA scratch port is busy (STATUS bit4). */
BOOL Stage_Busy(void);

/* Read back the current scratch write pointer (for diagnostics). */
DWORD Stage_Pointer(void);