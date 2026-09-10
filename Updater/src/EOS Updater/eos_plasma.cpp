// eos_plasma.cpp -- Darkone83 theme computed vertex-grid plasma backdrop.
//
// Ported from the Team Resurgent demoscene PlasmaScene: a screen-space grid whose
// per-vertex colours are evaluated live each frame from a stack of sine/cosine
// waves (incl. radial + rotating terms), banded through a cross-fading palette,
// with the grid itself wobbling and a slow camera zoom/rotate. Scanline + vignette
// passes give the CRT feel and help the 3D figure separate from the field.
//
// Loader adaptations vs. the original demo:
//   * trig via Gfx_SinCos (s_sinf range-reduces, so it's stable as t grows) -- no libm;
//   * one-instruction __asm fsqrt for the radial terms -- no libm;
//   * float->int uses the project's _ftol2_sse shim (eos_ftoi.cpp), so no inline Ftoi;
//   * palettes are purple/violet variations of the theme (not the demo's rainbow);
//   * VU / music reactivity removed;
//   * verts authored in 640x480 design space and mapped by (g_ox + x*g_sx, ...) like
//     every other 2D draw, so HD pillarboxing is handled;
//   * per-vertex DIFFUSE passthrough is set for the grid, then the 2D stage baseline
//     (MODULATE TEXTURE*TFACTOR, QFVF) is fully restored on exit.
//
// Drawn in the 2D pass (after the EOS_BG fill, before Gfx_Begin3D()/Model_Draw());
// it's opaque and fills the frame, and the depth-tested figure paints over it.
//
// RXDK / MSVC2003 / C89-friendly: POD statics, no global constructors.
#include "eos_plasma.h"
#include "eos_gfx.h"     // g_dev, g_scrW/H, Gfx_SinCos, EOS_* palette
#include <xtl.h>

// HD layout globals: defined in eos_gfx.cpp but not exposed in the header.
// Declared here so the grid can map design space -> backbuffer pixels the same
// way DrawQuadUV does. Types match eos_gfx.cpp (g_ox/g_oy int, g_sx/g_sy float).
extern int   g_ox, g_oy;
extern float g_sx, g_sy;

// ---- tunables -------------------------------------------------------------
#define PLZ_GX      40          // grid columns (detail vs. CPU cost)
#define PLZ_GY      30          // grid rows
#define PLZ_SCAN_A  50          // scanline darkness (0..255)
#define PLZ_VIG_A   170         // vignette edge darkness (0..255)

#define PLZ_FVF (D3DFVF_XYZRHW | D3DFVF_DIFFUSE)

struct PVtx { float x, y, z, rhw; DWORD color; };

static PVtx s_grid[PLZ_GY][PLZ_GX];        // base positions (design space) + live colour
static PVtx s_strip[PLZ_GX * 2];           // one row-pair strip

// scanline + vignette geometry (built once; positions/colours fixed)
#define PLZ_SCAN_MAX 260
static PVtx s_scan[PLZ_SCAN_MAX * 6];      // triangle list, 2 tris per dark line
static int  s_scanVerts = 0;
static PVtx s_vig[6];                      // triangle fan

static int s_ready = 0;
static int s_tried = 0;
static int s_frame = 0;

// palette cross-fade
static int   s_palFrom = 0, s_palTo = 1, s_palHold = 0;
static float s_palBlend = 0.0f;
#define PLZ_PAL_HOLD   150
#define PLZ_PAL_FADE   0.012f

// ---- purple/violet palettes: variations on the theme accent ---------------
static const DWORD s_palViolet[5] = {
    D3DCOLOR_XRGB(8,2,16), D3DCOLOR_XRGB(40,12,70), D3DCOLOR_XRGB(96,40,150),
    D3DCOLOR_XRGB(168,85,247), D3DCOLOR_XRGB(224,180,255) };
static const DWORD s_palMagenta[5] = {
    D3DCOLOR_XRGB(14,2,16), D3DCOLOR_XRGB(70,8,60), D3DCOLOR_XRGB(160,30,140),
    D3DCOLOR_XRGB(230,90,210), D3DCOLOR_XRGB(255,205,255) };
static const DWORD s_palBlueViolet[5] = {
    D3DCOLOR_XRGB(4,4,22), D3DCOLOR_XRGB(24,24,90), D3DCOLOR_XRGB(70,60,180),
    D3DCOLOR_XRGB(140,120,255), D3DCOLOR_XRGB(210,205,255) };
static const DWORD s_palLavender[5] = {
    D3DCOLOR_XRGB(10,8,22), D3DCOLOR_XRGB(56,44,100), D3DCOLOR_XRGB(130,100,200),
    D3DCOLOR_XRGB(199,125,255), D3DCOLOR_XRGB(245,238,255) };
static const DWORD* s_palettes[4] = {
    s_palViolet, s_palMagenta, s_palBlueViolet, s_palLavender };
#define PLZ_PAL_COUNT 4

// ---- libm-free helpers ----------------------------------------------------
static float PSin(float a) { float s; Gfx_SinCos(a, &s, 0); return s; }
static float PCos(float a) { float c; Gfx_SinCos(a, 0, &c); return c; }
static float PSqrt(float f)
{
    float r;
    if (f <= 0.0f) return 0.0f;
    __asm {
        fld  f
        fsqrt
        fstp r
    }
    return r;
}

static float MapX(float dx) { return (float)g_ox + dx * g_sx; }
static float MapY(float dy) { return (float)g_oy + dy * g_sy; }

// ---- init -----------------------------------------------------------------
int Plasma_Init(void)
{
    int i, j, sy, n;
    float dx, dy;
    DWORD scanCol, vigEdge, vigCtr;
    float x0, x1, y0, y1;

    if (s_ready) return 1;
    if (s_tried) return 0;
    s_tried = 1;
    if (!g_dev) return 0;

    // base grid positions in design space
    dx = (float)g_scrW / (float)(PLZ_GX - 1);
    dy = (float)g_scrH / (float)(PLZ_GY - 1);
    for (j = 0; j < PLZ_GY; ++j) {
        for (i = 0; i < PLZ_GX; ++i) {
            s_grid[j][i].x = dx * (float)i;
            s_grid[j][i].y = dy * (float)j;
            s_grid[j][i].z = 0.0f;
            s_grid[j][i].rhw = 1.0f;
            s_grid[j][i].color = 0xFF000000;
        }
    }

    // scanline batch: a dark quad on every other design row (2 tris each)
    scanCol = D3DCOLOR_ARGB(PLZ_SCAN_A, 0, 0, 0);
    n = 0;
    for (sy = 1; sy < g_scrH; sy += 2) {
        if (n + 6 > PLZ_SCAN_MAX * 6) break;
        x0 = MapX(0.0f);             x1 = MapX((float)g_scrW);
        y0 = MapY((float)sy - 0.5f); y1 = MapY((float)sy + 0.5f);
        s_scan[n + 0].x = x0; s_scan[n + 0].y = y0;
        s_scan[n + 1].x = x1; s_scan[n + 1].y = y0;
        s_scan[n + 2].x = x0; s_scan[n + 2].y = y1;
        s_scan[n + 3].x = x1; s_scan[n + 3].y = y0;
        s_scan[n + 4].x = x1; s_scan[n + 4].y = y1;
        s_scan[n + 5].x = x0; s_scan[n + 5].y = y1;
        for (i = 0; i < 6; ++i) { s_scan[n + i].z = 0.0f; s_scan[n + i].rhw = 1.0f; s_scan[n + i].color = scanCol; }
        n += 6;
    }
    s_scanVerts = n;

    // vignette fan: transparent centre, dark corners
    vigEdge = D3DCOLOR_ARGB(PLZ_VIG_A, 0, 0, 0);
    vigCtr = D3DCOLOR_ARGB(0, 0, 0, 0);
    x0 = MapX(0.0f); x1 = MapX((float)g_scrW);
    y0 = MapY(0.0f); y1 = MapY((float)g_scrH);
    s_vig[0].x = MapX((float)g_scrW * 0.5f); s_vig[0].y = MapY((float)g_scrH * 0.5f); s_vig[0].color = vigCtr;
    s_vig[1].x = x0; s_vig[1].y = y0; s_vig[1].color = vigEdge;
    s_vig[2].x = x1; s_vig[2].y = y0; s_vig[2].color = vigEdge;
    s_vig[3].x = x1; s_vig[3].y = y1; s_vig[3].color = vigEdge;
    s_vig[4].x = x0; s_vig[4].y = y1; s_vig[4].color = vigEdge;
    s_vig[5].x = x0; s_vig[5].y = y0; s_vig[5].color = vigEdge;
    for (i = 0; i < 6; ++i) { s_vig[i].z = 0.0f; s_vig[i].rhw = 1.0f; }

    s_ready = 1;
    return 1;
}

int  Plasma_Ready(void) { return s_ready; }
void Plasma_Free(void) { s_ready = 0; }

// ---- per-vertex colour field (the plasma proper) --------------------------
static void UpdateColors(float t)
{
    DWORD pal[5];
    const DWORD* pA = s_palettes[s_palFrom];
    const DWORD* pB = s_palettes[s_palTo];
    int blendI = (int)(s_palBlend * 256.0f);
    float sxN = 4.0f / (float)(PLZ_GX - 1);
    float syN = 4.0f / (float)(PLZ_GY - 1);
    float angle = t * 0.5f, ca1 = PCos(angle), sa1 = PSin(angle);
    float angle2 = t * -0.7f + 1.5f, ca2 = PCos(angle2), sa2 = PSin(angle2);
    float st03 = PSin(t * 0.3f), ct04 = PCos(t * 0.4f), st02 = PSin(t * 0.2f);
    int p, i, j;

    if (blendI > 256) blendI = 256;
    for (p = 0; p < 5; ++p) {
        int r0 = (pA[p] >> 16) & 0xFF, r1 = (pB[p] >> 16) & 0xFF;
        int g0 = (pA[p] >> 8) & 0xFF, g1 = (pB[p] >> 8) & 0xFF;
        int b0 = pA[p] & 0xFF, b1 = pB[p] & 0xFF;
        int r = r0 + (((r1 - r0) * blendI) >> 8), g = g0 + (((g1 - g0) * blendI) >> 8), b = b0 + (((b1 - b0) * blendI) >> 8);
        pal[p] = 0xFF000000 | (r << 16) | (g << 8) | b;
    }

    for (j = 0; j < PLZ_GY; ++j) {
        float ny = (float)j * syN - 2.0f;
        for (i = 0; i < PLZ_GX; ++i) {
            float nx = (float)i * sxN - 2.0f;
            float rx1, ry1, rx2, ry2, v;
            int band, palidx, subband, blend256;
            DWORD c0, c1;
            int red0, red1, grn0, grn1, blu0, blu1, red, grn, blu;

            v = PSin(nx * 5.0f + t * 1.2f);
            v += PCos(ny * 5.0f - t * 1.5f);
            v += PSin((nx + ny) * 4.0f + t * 0.8f);
            v += PCos((nx - ny) * 4.5f - t * 1.0f);
            v += PSin(nx * 6.5f + ny * 3.5f + t * 1.3f);
            v += PCos(nx * 3.0f - ny * 6.0f - t * 0.9f);
            v += PSin(PSqrt(nx * nx + ny * ny) * 7.0f + t * 1.1f);
            v += PCos(PSqrt((nx - 0.5f) * (nx - 0.5f) + (ny + 0.3f) * (ny + 0.3f)) * 6.0f - t * 1.4f);
            v += PSin(PSqrt((nx + 0.7f) * (nx + 0.7f) + (ny - 0.6f) * (ny - 0.6f)) * 5.5f + t * 0.7f);

            rx1 = nx * ca1 - ny * sa1;  ry1 = nx * sa1 + ny * ca1;
            v += PCos(rx1 * 4.5f + ry1 * 3.5f + t * 0.6f);
            rx2 = nx * ca2 - ny * sa2;  ry2 = nx * sa2 + ny * ca2;
            v += PSin(rx2 * 5.5f - ry2 * 4.0f - t * 0.8f);

            v += PSin(nx * ny * 3.0f + t);
            v += PCos((nx + st03) * 7.0f);
            v += PSin((ny + ct04) * 7.0f);
            v += PCos((nx * 3.0f + ny * 2.0f) * st02 + t * 1.5f);

            // 16 bands -> 5 palette colours with interpolation
            if (v > 2.625f) band = 15; else if (v > 2.25f) band = 14;
            else if (v > 1.875f) band = 13; else if (v > 1.5f) band = 12;
            else if (v > 1.125f) band = 11; else if (v > 0.75f) band = 10;
            else if (v > 0.375f) band = 9;  else if (v > 0.0f) band = 8;
            else if (v > -0.375f) band = 7; else if (v > -0.75f) band = 6;
            else if (v > -1.125f) band = 5; else if (v > -1.5f) band = 4;
            else if (v > -1.875f) band = 3; else if (v > -2.25f) band = 2;
            else if (v > -2.625f) band = 1; else band = 0;

            palidx = band >> 2; subband = band & 3;
            if (palidx > 3) palidx = 3;
            c0 = pal[palidx]; c1 = pal[palidx + 1 > 4 ? 4 : palidx + 1];
            red0 = (c0 >> 16) & 0xFF; red1 = (c1 >> 16) & 0xFF;
            grn0 = (c0 >> 8) & 0xFF;  grn1 = (c1 >> 8) & 0xFF;
            blu0 = c0 & 0xFF;       blu1 = c1 & 0xFF;
            blend256 = subband << 6;
            red = red0 + (((red1 - red0) * blend256) >> 8);
            grn = grn0 + (((grn1 - grn0) * blend256) >> 8);
            blu = blu0 + (((blu1 - blu0) * blend256) >> 8);
            s_grid[j][i].color = 0xFF000000 | (red << 16) | (grn << 8) | blu;
        }
    }
}

// ---- draw -----------------------------------------------------------------
void Plasma_Draw(float tsec)
{
    float t, zoom, angle, ca, sa, cx, cy, ph, phY;
    int i, j, idx;
    (void)tsec;

    if (!s_ready) { if (!Plasma_Init()) return; }
    s_frame++;
    t = (float)s_frame * 0.06f;

    // palette cross-fade state machine
    s_palHold++;
    if (s_palHold >= PLZ_PAL_HOLD) {
        s_palBlend += PLZ_PAL_FADE;
        if (s_palBlend >= 1.0f) {
            s_palBlend = 0.0f;
            s_palFrom = s_palTo;
            s_palTo = (s_palTo + 1) % PLZ_PAL_COUNT;
            s_palHold = 0;
        }
    }

    UpdateColors(t);

    // camera drift + grid wobble -> deformed screen positions
    zoom = 1.0f + 0.06f * PSin(t * 0.25f);
    angle = 0.06f * PSin(t * 0.18f);
    ca = PCos(angle); sa = PSin(angle);
    cx = (float)g_scrW * 0.5f; cy = (float)g_scrH * 0.5f;
    ph = PSin(t * 0.5f);      // shared wobble phase pieces (per-frame)
    phY = PCos(t * 0.37f);

    // ---- render state: opaque, per-vertex diffuse, no depth ----
    g_dev->SetVertexShader(PLZ_FVF);
    g_dev->SetTexture(0, NULL);
    g_dev->SetTextureStageState(0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
    g_dev->SetTextureStageState(0, D3DTSS_COLORARG1, D3DTA_DIFFUSE);
    g_dev->SetTextureStageState(0, D3DTSS_ALPHAOP, D3DTOP_SELECTARG1);
    g_dev->SetTextureStageState(0, D3DTSS_ALPHAARG1, D3DTA_DIFFUSE);
    g_dev->SetRenderState(D3DRS_ALPHABLENDENABLE, FALSE);
    g_dev->SetRenderState(D3DRS_ZENABLE, FALSE);
    g_dev->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE);
    g_dev->SetRenderState(D3DRS_LIGHTING, FALSE);

    for (j = 0; j < PLZ_GY - 1; ++j) {
        idx = 0;
        for (i = 0; i < PLZ_GX; ++i) {
            float nx = ((float)i / (float)(PLZ_GX - 1)) * 2.0f - 1.0f;
            int   k;
            for (k = 0; k < 2; ++k) {
                const PVtx* src = &s_grid[j + k][i];
                float ny = ((float)(j + k) / (float)(PLZ_GY - 1)) * 2.0f - 1.0f;
                float phX = nx * 3.1f + ph;
                float base = ny * 2.7f + phY;
                float wobY = PSin(phX + base) * 4.0f;
                float wobX = PCos(phX - base) * 3.0f;
                float tx = (src->x + wobX) - cx;
                float ty = (src->y + wobY) - cy;
                float rx, ry;
                tx *= zoom; ty *= zoom;
                rx = tx * ca - ty * sa;
                ry = tx * sa + ty * ca;
                s_strip[idx].x = MapX(rx + cx);
                s_strip[idx].y = MapY(ry + cy);
                s_strip[idx].z = 0.0f; s_strip[idx].rhw = 1.0f;
                s_strip[idx].color = src->color;
                ++idx;
            }
        }
        g_dev->DrawPrimitiveUP(D3DPT_TRIANGLESTRIP, (PLZ_GX * 2) - 2,
            s_strip, sizeof(PVtx));
    }

    // ---- scanlines + vignette (alpha) ----
    g_dev->SetRenderState(D3DRS_ALPHABLENDENABLE, TRUE);
    g_dev->SetRenderState(D3DRS_SRCBLEND, D3DBLEND_SRCALPHA);
    g_dev->SetRenderState(D3DRS_DESTBLEND, D3DBLEND_INVSRCALPHA);
    if (s_scanVerts >= 3)
        g_dev->DrawPrimitiveUP(D3DPT_TRIANGLELIST, s_scanVerts / 3, s_scan, sizeof(PVtx));
    g_dev->DrawPrimitiveUP(D3DPT_TRIANGLEFAN, 4, s_vig, sizeof(PVtx));

    // ---- restore the 2D baseline (SetState2D config) for later draws ----
    g_dev->SetTextureStageState(0, D3DTSS_COLOROP, D3DTOP_MODULATE);
    g_dev->SetTextureStageState(0, D3DTSS_COLORARG1, D3DTA_TEXTURE);
    g_dev->SetTextureStageState(0, D3DTSS_COLORARG2, D3DTA_TFACTOR);
    g_dev->SetTextureStageState(0, D3DTSS_ALPHAOP, D3DTOP_MODULATE);
    g_dev->SetTextureStageState(0, D3DTSS_ALPHAARG1, D3DTA_TEXTURE);
    g_dev->SetTextureStageState(0, D3DTSS_ALPHAARG2, D3DTA_TFACTOR);
    g_dev->SetVertexShader(D3DFVF_XYZRHW | D3DFVF_TEX1);   // QFVF
}