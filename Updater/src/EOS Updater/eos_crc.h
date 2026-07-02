#pragma once
// eos_crc.h -- host-side CRC-32, byte-identical to the FPGA's eos_crc32.
//
// Standard IEEE 802.3 / zlib / PNG CRC-32:
//   polynomial 0xEDB88320 (reflected), init 0xFFFFFFFF, final XOR 0xFFFFFFFF.
// The value produced here is what gets sent via SETCRC; the FPGA computes the
// same CRC over the staged scratch bytes and VALIDATE compares them. They MUST
// match bit-for-bit, so this is the single source of the algorithm on the host.
//
// One-shot for a whole buffer, or incremental for streaming large images:
//   DWORD c; Crc_Init(&c); Crc_Update(&c, p0, n0); ...; crc = Crc_Final(c);
#include <xtl.h>

DWORD Crc_Buffer(const unsigned char* data, int len);   /* whole buffer */

void  Crc_Init(DWORD* crc);                              /* -> running accumulator */
void  Crc_Update(DWORD* crc, const unsigned char* data, int len);
DWORD Crc_Final(DWORD crc);                              /* apply final complement */