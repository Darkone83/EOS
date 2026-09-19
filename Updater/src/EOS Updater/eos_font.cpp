// eos_font.cpp -- AA proportional font rendering from a baked glyph atlas.
//
// The atlas (white RGB, alpha = coverage) is uploaded once; each glyph is a
// 1:1 textured quad tinted by color and alpha-blended, so edges stay smooth.
// Layout is proportional -- use Font_TextWidth for alignment, not a fixed cell.
//
// RXDK / MSVC2003 / C89-ish: no CRT, no heap.
#include "eos_font.h"
#include "eos_font_data.h"

static IDirect3DTexture8* s_atlas = 0;
static DWORD              s_argb[FONT_ATLAS_W * FONT_ATLAS_H];

bool Font_Init()
{
    int i, n = FONT_ATLAS_W * FONT_ATLAS_H;
    for (i = 0; i < n; ++i)
        s_argb[i] = ((DWORD)FONT_ATLAS[i] << 24) | 0x00FFFFFF;   // white + coverage alpha
    s_atlas = Gfx_CreateTexARGB(FONT_ATLAS_W, FONT_ATLAS_H, s_argb);
    return (s_atlas != 0);
}

void Font_Shutdown()
{
    if (s_atlas) { s_atlas->Release(); s_atlas = 0; }
}

static const short* glyph(int c)
{
    if (c < FONT_FIRST || c >= FONT_FIRST + FONT_COUNT) return 0;
    return FONT_GLYPH[c - FONT_FIRST];
}

static int spaceAdv(void) { return FONT_GLYPH[' ' - FONT_FIRST][6]; }

int Font_TextWidth(const char* s)
{
    int w = 0, i;
    if (!s) return 0;
    for (i = 0; s[i]; ++i) {
        const short* g = glyph((unsigned char)s[i]);
        w += g ? g[6] : spaceAdv();
    }
    return w;
}

int Font_Draw(int x, int y, const char* s, DWORD color)
{
    int   cx = x, i;
    float aw = (float)FONT_ATLAS_W, ah = (float)FONT_ATLAS_H;
    if (!s) return x;
    for (i = 0; s[i]; ++i) {
        const short* g = glyph((unsigned char)s[i]);
        if (!g) { cx += spaceAdv(); continue; }
        if (g[2] > 0 && g[3] > 0) {                       // glyph has ink
            float u0 = (float)g[0] / aw, v0 = (float)g[1] / ah;
            float u1 = (float)(g[0] + g[2]) / aw, v1 = (float)(g[1] + g[3]) / ah;
            Gfx_DrawTex(s_atlas, (float)(cx + g[4]), (float)(y + g[5]),
                (float)g[2], (float)g[3], u0, v0, u1, v1, color);
        }
        cx += g[6];                                       // proportional advance
    }
    return cx;
}

int Font_DrawCentered(int x0, int width, int y, const char* s, DWORD color)
{
    int w = Font_TextWidth(s);
    int sx = x0 + (width - w) / 2;
    Font_Draw(sx, y, s, color);
    return sx;
}
// Scaled text: same atlas, glyph metrics multiplied by k (e.g. 0.72 for a
// smaller HUD line). Position offsets, quad size, and advance all scale, so the
// baseline stays at y and spacing stays proportional.
int Font_DrawScaled(int x, int y, const char* s, DWORD color, float k)
{
    float cx = (float)x, aw = (float)FONT_ATLAS_W, ah = (float)FONT_ATLAS_H;
    int i;
    if (!s) return x;
    for (i = 0; s[i]; ++i) {
        const short* g = glyph((unsigned char)s[i]);
        if (!g) { cx += (float)spaceAdv() * k; continue; }
        if (g[2] > 0 && g[3] > 0) {
            float u0 = (float)g[0] / aw, v0 = (float)g[1] / ah;
            float u1 = (float)(g[0] + g[2]) / aw, v1 = (float)(g[1] + g[3]) / ah;
            Gfx_DrawTex(s_atlas, cx + (float)g[4] * k, (float)y + (float)g[5] * k,
                (float)g[2] * k, (float)g[3] * k, u0, v0, u1, v1, color);
        }
        cx += (float)g[6] * k;
    }
    return (int)(cx + 0.5f);
}

int Font_TextWidthScaled(const char* s, float k)
{
    return (int)((float)Font_TextWidth(s) * k + 0.5f);
}
// Emit a string as real 3D geometry on a tilted pill face. Glyphs are laid out
// in the face's local space (centered about cx, vertically about cy), each one
// emitted via Gfx_Quad3DP so it tilts/recedes with the pill. Screen-y-down atlas
// is flipped to world-y-up.
void Font_Draw3D(float cx, float cy, float cz, float ca, float sa,
    float k, const char* s, DWORD color)
{
    float aw, ah, penX, minX, maxX, minY, maxY, shiftX, shiftY;
    float gl, gr, gt, gb, gw, gh, lcx, lcy, u0, v0, u1, v1;
    const short* g;
    int i, haveInk;

    if (!s || !s[0]) return;

    aw = (float)FONT_ATLAS_W;
    ah = (float)FONT_ATLAS_H;
    penX = 0.0f;
    minX = 1000000.0f; maxX = -1000000.0f;
    minY = 1000000.0f; maxY = -1000000.0f;
    haveInk = 0;

    // First pass: measure the actual rendered glyph bounds, not the string's
    // advance box. This visually centers the ink inside the pill even when the
    // first/last glyph has asymmetric side bearings or ascender/descender use.
    for (i = 0; s[i]; ++i) {
        g = glyph((unsigned char)s[i]);
        if (!g) { penX += (float)spaceAdv() * k; continue; }
        if (g[2] > 0 && g[3] > 0) {
            gl = penX + (float)g[4] * k;
            gr = gl + (float)g[2] * k;
            gt = -(float)g[5] * k;
            gb = gt - (float)g[3] * k;
            if (gl < minX) minX = gl;
            if (gr > maxX) maxX = gr;
            if (gb < minY) minY = gb;
            if (gt > maxY) maxY = gt;
            haveInk = 1;
        }
        penX += (float)g[6] * k;
    }
    if (!haveInk) return;

    shiftX = -(minX + maxX) * 0.5f;
    shiftY = -(minY + maxY) * 0.5f;
    penX = 0.0f;

    for (i = 0; s[i]; ++i) {
        g = glyph((unsigned char)s[i]);
        if (!g) { penX += (float)spaceAdv() * k; continue; }
        if (g[2] > 0 && g[3] > 0) {
            gw = (float)g[2] * k;
            gh = (float)g[3] * k;
            lcx = penX + (float)g[4] * k + gw * 0.5f + shiftX;
            lcy = -(float)g[5] * k - gh * 0.5f + shiftY;
            u0 = (float)g[0] / aw; v0 = (float)g[1] / ah;
            u1 = (float)(g[0] + g[2]) / aw; v1 = (float)(g[1] + g[3]) / ah;
            Gfx_Quad3DP(cx, cy, cz, ca, sa, lcx, lcy, gw * 0.5f, gh * 0.5f,
                color, s_atlas, u0, v0, u1, v1);
        }
        penX += (float)g[6] * k;
    }
}