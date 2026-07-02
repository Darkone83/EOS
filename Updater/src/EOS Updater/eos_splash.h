#pragma once
// eos_splash.h -- EOS goddess splash (128x128 4bpp indexed logo).
#pragma once
#include "eos_gfx.h"

bool Splash_Init();
void Splash_Shutdown();

// Draw the logo centered at (cx,cy) scaled to 'size' px square, tinted by alpha
// of 'mod' (use EOS_WHITE for full). Transparent index shows through.
void Splash_Draw(int cx, int cy, int size, DWORD mod);