// eos_crc.cpp -- see eos_crc.h. Table-driven reflected CRC-32 (poly 0xEDB88320).
#include <xtl.h>
#include "eos_crc.h"

static DWORD s_table[256];
static int   s_ready = 0;

static void build_table(void)
{
    DWORD c;
    int   n, k;
    for (n = 0; n < 256; ++n) {
        c = (DWORD)n;
        for (k = 0; k < 8; ++k)
            c = (c & 1) ? (0xEDB88320UL ^ (c >> 1)) : (c >> 1);
        s_table[n] = c;
    }
    s_ready = 1;
}

void Crc_Init(DWORD* crc)
{
    if (!s_ready) build_table();
    if (crc) *crc = 0xFFFFFFFFUL;
}

void Crc_Update(DWORD* crc, const unsigned char* data, int len)
{
    DWORD c;
    int   i;
    if (!crc || !data || len <= 0) return;
    if (!s_ready) build_table();
    c = *crc;
    for (i = 0; i < len; ++i)
        c = s_table[(c ^ data[i]) & 0xFF] ^ (c >> 8);
    *crc = c;
}

DWORD Crc_Final(DWORD crc)
{
    return crc ^ 0xFFFFFFFFUL;
}

DWORD Crc_Buffer(const unsigned char* data, int len)
{
    DWORD c;
    Crc_Init(&c);
    Crc_Update(&c, data, len);
    return Crc_Final(c);
}