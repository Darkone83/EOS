// eos_splash.cpp -- expands the baked 4bpp indexed logo into an ARGB texture.
#include "eos_splash.h"
#include "eos_logo_data.h"   // EOS_LOGO_W/H, EOS_LOGO_PAL[15][3], EOS_LOGO_4BPP[8192]
#include <string.h>

static IDirect3DTexture8* s_logo = 0;

bool Splash_Init()
{
    static DWORD px[EOS_LOGO_W * EOS_LOGO_H];
    for (int i = 0; i < EOS_LOGO_W * EOS_LOGO_H; ++i) {
        unsigned char byte = EOS_LOGO_4BPP[i >> 1];
        unsigned char idx = (i & 1) ? (byte & 0x0F) : (byte >> 4);
        if (idx == 0) { px[i] = 0x00000000; continue; }   // transparent
        const unsigned char* c = EOS_LOGO_PAL[idx - 1];
        px[i] = EOS_ARGB(0xFF, c[0], c[1], c[2]);
    }
    s_logo = Gfx_CreateTexARGB(EOS_LOGO_W, EOS_LOGO_H, px);
    return (s_logo != 0);
}

void Splash_Shutdown()
{
    if (s_logo) { s_logo->Release(); s_logo = 0; }
}

void Splash_Draw(int cx, int cy, int size, DWORD mod)
{
    float x = (float)(cx - size / 2);
    float y = (float)(cy - size / 2);
    Gfx_SetFilter(TRUE);   /* smooth the scaled logo gradient */
    Gfx_DrawTex(s_logo, x, y, (float)size, (float)size, 0, 0, 1, 1, mod);
    Gfx_SetFilter(FALSE);  /* back to crisp POINT for text/menu */
}