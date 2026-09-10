#pragma once
// eos_plasma.h -- Darkone83 theme soft-plasma backdrop filler.
//
// A procedural, tiling plasma generated once at init into a RAM texture (zero
// XBE size cost -- nothing is baked into the pack). Drawn as two slow, oppositely
// scrolling fullscreen layers behind the character mesh: a soft alpha base tinted
// with the theme accent, plus a fainter additive highlight layer, so the shifting
// interference reads as gentle plasma cloud without overpowering the figure.
//
// Call Plasma_Draw() in the 2D pass (after the EOS_BG fill, before Gfx_Begin3D()
// / Model_Draw()). Lazy one-shot init with failsafe: if the texture can't be
// built, Plasma_Draw() is a no-op and the backdrop stays the flat EOS_BG fill.
//
// RXDK / MSVC2003 / C89: declarations before statements, POD, no CRT beyond
// malloc/free.
#pragma once
#define EOS_PLASMA_H 1

int  Plasma_Init(void);          // build the RAM texture (idempotent). 1=ready, 0=unavailable.
int  Plasma_Ready(void);
void Plasma_Draw(float tsec);    // draw the scrolling backdrop (2D pass). tsec = seconds.
void Plasma_Free(void);