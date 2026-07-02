// eos_gfx.h -- Minimal D3D8 2D layer for the EOS Loader.
// Pre-transformed textured quads, locked linear (LIN_A8R8G8B8) textures.
// 640x480 32bpp backbuffer. Alpha-blended; diffuse modulates texture so a
// white-on-transparent glyph/atlas can be tinted any color at draw time.
#pragma once
#include <xtl.h>
#include <xgraphics.h>   // XGSwizzleRect (NV2A swizzle) -- required by eos_gfx.cpp

// ARGB helper.
#define EOS_ARGB(a,r,g,b) ((DWORD)(((a)<<24)|((r)<<16)|((g)<<8)|(b)))

// Theme-driven palette. These resolve to fields of the active theme (g_theme),
// so re-theming recolors every draw call with no call-site changes. Default is
// the Eos accent purple RGB(168,85,247) until Theme_Init() loads the saved one.
#include "eos_theme.h"
#define EOS_PURPLE (g_theme.accent)
#define EOS_WHITE  (g_theme.white)
#define EOS_DIM    (g_theme.dim)
#define EOS_BG     (g_theme.bg)
#define EOS_BG2    (g_theme.bg2)
#define EOS_PANEL  (g_theme.panel)
#define EOS_GLOW   (g_theme.glow)

extern IDirect3DDevice8* g_dev;

// Runtime video mode (detected from the console's AV pack in Gfx_Init).
// The render target stays a fixed 640-wide design space so layout math holds;
// the NV2A scales it to the actual output signal. g_scrH is 480, or 576 on a
// true PAL-I 50Hz console. g_isWide reflects the widescreen flag; g_videoMode
// is a short label for the HUD ("480i","480p","720p","1080i","576i").
extern int         g_scrW;
extern int         g_scrH;
extern BOOL        g_isWide;
extern const char* g_videoMode;

bool Gfx_Init();
void Gfx_Shutdown();
void Gfx_Begin(DWORD clear_argb);   // Clear + BeginScene
void Gfx_End();                     // EndScene + Present

// Create a managed linear ARGB texture from a CPU pixel buffer (row-major,
// w*h DWORDs, 0xAARRGGBB). Returns NULL on failure.
IDirect3DTexture8* Gfx_CreateTexARGB(int w, int h, const DWORD* pixels);

// Textured quad. uv in 0..1. color = diffuse tint (modulated with texture).
void Gfx_DrawTex(IDirect3DTexture8* tex, float x, float y, float w, float h,
    float u0, float v0, float u1, float v1, DWORD color);

// Solid filled rectangle (uses internal 1x1 white texture).
void Gfx_Fill(float x, float y, float w, float h, DWORD color);

// Solid filled rounded rectangle / pill. Integer coords (no float->int, so no
// __ftol2_sse). radius is clamped to min(w,h)/2; radius>=h/2 gives a capsule.
// Corners use a generated mask drawn with LINEAR filtering for a smooth edge;
// the filter is restored to POINT afterward so following text stays crisp.
void Gfx_FillRounded(int x, int y, int w, int h, int radius, DWORD color);
void Gfx_FillVGradient(int x, int y, int w, int h, DWORD top, DWORD bottom);
void Gfx_GlowRounded(int x, int y, int w, int h, int r, DWORD color);
void Gfx_GlowSoft(int cx, int cy, int w, int h, DWORD color, int peak);

void Gfx_SetFilter(BOOL linear);   // TRUE=LINEAR (logo), FALSE=POINT (text/menu)

// ----- Real 3D perspective pass ----------------------------------------
// Switches the pipeline from the 2D XYZRHW blitter to true fixed-function T&L:
// a perspective projection + identity view, untransformed XYZ geometry, with
// the viewport locked to the 4:3 design area so it lines up with the 2D chrome.
// Open with Gfx_Begin3D(), draw quads, close with Gfx_End3D() (restores 2D).
void Gfx_Begin3D(void);
void Gfx_End3D(void);

// Camera-facing quad at world (cx,cy,cz), half extents (hw,hh), tinted by the
// vertex diffuse color (alpha honored). Fill = solid white tex; Add = additive
// (glow/highlight). Orb3D billboards the soft glow sprite additively.
void Gfx_Quad3D(float cx, float cy, float cz, float hw, float hh, DWORD c,
    IDirect3DTexture8* tex, float u0, float v0, float u1, float v1);
void Gfx_Quad3DFill(float cx, float cy, float cz, float hw, float hh, DWORD c);
void Gfx_Quad3DAdd(float cx, float cy, float cz, float hw, float hh, DWORD c,
    IDirect3DTexture8* tex);
void Gfx_Orb3D(float cx, float cy, float cz, float size, DWORD color, int peak);

// CRT-free sine/cosine (range-reduced; ~0.1% error). For wheel rotation.
void Gfx_SinCos(float a, float* s, float* c);

// Tilted quad: a local rect (centered at lcx,lcy on the item face) rotated about
// the world X axis by (ca=cos a, sa=sin a), placed at (cx,cy,cz). ca=1,sa=0 ->
// screen-parallel. This is the primitive that makes surfaces turn in space.
void Gfx_Quad3DP(float cx, float cy, float cz, float ca, float sa,
    float lcx, float lcy, float hw, float hh, DWORD c,
    IDirect3DTexture8* tex, float u0, float v0, float u1, float v1);

// Rounded, translucent 3D pill (3-slice: flat middle + disc end-caps), tilted
// by (ca,sa). 'c' carries tint + alpha so pills are properly see-through.
void Gfx_PillX3D(float cx, float cy, float cz, float ca, float sa,
    float hw, float hh, DWORD c);