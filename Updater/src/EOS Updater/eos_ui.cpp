// eos_ui.cpp -- shared menu chrome. See eos_ui.h.
//
// RXDK / MSVC2003 / C89: declarations before statements, no CRT.
#include "eos_ui.h"
#include "eos_gfx.h"
#include "eos_font.h"
#include "eos_model.h"   // Darkone 83 skin: embedded 3D model
#include "eos_plasma.h"  // Darkone 83 skin: plasma field behind model
#include "eos_theme.h"


// ---- 3D parallax orb field --------------------------------------------
// Real billboards placed at varying depth in the perspective scene, drifting
// in X/Y. Parallax falls out of the projection for free (far orbs move less on
// screen). Colors are theme tokens; motion advances once per frame.

typedef struct Orb3 { float x, y, z, vx, vy, size; int peak, tier; } Orb3;

#define ORB_N 16

static Orb3     s_orb[ORB_N];
static int      s_orbInit = 0;
static DWORD    s_orbLast = 0;
static unsigned s_orbRng = 0x9E3779B9u;

static unsigned orbRnd(void) { s_orbRng = s_orbRng * 1664525u + 1013904223u; return s_orbRng; }
static float    orbF(void) { return (float)((orbRnd() >> 8) & 0xFFFF) / 65536.0f; }   // 0..1
static float    orbRange(float a, float b) { return a + (b - a) * orbF(); }

// RGB blend a -> b by num/den.
static DWORD orbBlend(DWORD a, DWORD b, int num, int den)
{
    int ar, ag, ab, br, bg2, bb;
    if (num < 0) num = 0;
    if (num > den) num = den;
    ar = (a >> 16) & 0xFF; ag = (a >> 8) & 0xFF; ab = a & 0xFF;
    br = (b >> 16) & 0xFF; bg2 = (b >> 8) & 0xFF; bb = b & 0xFF;
    ar += (br - ar) * num / den; ag += (bg2 - ag) * num / den; ab += (bb - ab) * num / den;
    return ((DWORD)ar << 16) | ((DWORD)ag << 8) | (DWORD)ab;
}

static void orbSeed(Orb3* o, int i)
{
    int tier = (i < 5) ? 0 : (i < 11) ? 1 : 2;        // 5 far, 6 mid, 5 near (all behind menu)
    o->tier = tier;
    o->x = orbRange(-5.5f, 5.5f);
    o->y = orbRange(-3.6f, 3.6f);
    o->vx = orbRange(-0.5f, 0.5f);
    o->vy = orbRange(-0.2f, 0.2f);
    if (tier == 0) { o->z = orbRange(11.0f, 17.0f); o->size = orbRange(5.0f, 8.0f); o->peak = 0x4A; }
    else if (tier == 1) { o->z = orbRange(8.0f, 12.0f); o->size = orbRange(2.6f, 4.2f); o->peak = 0x80; }
    else { o->z = orbRange(5.5f, 8.0f); o->size = orbRange(1.2f, 2.2f); o->peak = 0xAC; }
}

static void orbsStep(void)
{
    DWORD now = GetTickCount();
    float dt;
    int i;
    if (!s_orbInit) { for (i = 0; i < ORB_N; ++i) orbSeed(&s_orb[i], i); s_orbInit = 1; s_orbLast = now; }
    dt = (float)(now - s_orbLast) / 1000.0f;
    if (dt < 0.0f) dt = 0.0f;
    if (dt > 0.10f) dt = 0.10f;
    s_orbLast = now;
    for (i = 0; i < ORB_N; ++i) {
        Orb3* o = &s_orb[i];
        o->x += o->vx * dt;
        o->y += o->vy * dt;
        if (o->x < -6.5f) o->x = 6.5f; else if (o->x > 6.5f) o->x = -6.5f;
        if (o->y < -4.2f) o->y = 4.2f; else if (o->y > 4.2f) o->y = -4.2f;
    }
}

static void orbsDraw(void)
{
    int i;
    for (i = 0; i < ORB_N; ++i) {
        Orb3* o = &s_orb[i];
        DWORD c;
        if (o->tier == 0) c = orbBlend(EOS_PURPLE, EOS_BG2, 55, 100);   // far: sinks into bg
        else if (o->tier == 1) c = (i & 1) ? EOS_PURPLE : EOS_GLOW;     // mid: accent mix
        else c = EOS_GLOW;                                              // near: brightest
        Gfx_Orb3D(o->x, o->y, o->z, o->size, c, o->peak);
    }
}

// Solid base fill, then the active themed background. Darkone 83 mirrors the
// loader: computed plasma in the 2D pass, then the embedded character mesh in
// the depth-tested 3D pass. Any model init failure falls back to normal orbs.
void Ui_Backdrop(void)
{
    float tsec;
    Gfx_Fill(0, 0, (float)g_scrW, (float)g_scrH, EOS_BG);
    if (Theme_BgIsModel() && Model_Init()) {
        tsec = (float)GetTickCount() * 0.001f;
        Plasma_Draw(tsec);
        Gfx_Begin3D();
        Model_Draw(tsec);
        Gfx_End3D();
    }
    else {
        orbsStep();
        Gfx_Begin3D();
        orbsDraw();
        Gfx_End3D();
    }
}

// Keep text legible at 480i: reduce modestly, then ellipsize instead of
// compressing a long path/status into a nearly invisible row of pixels.
static void uiFitEllipsis(const char* src, char* dst, int cap, int maxW, float scale)
{
    int n = 0, ellW;
    if (cap < 4) return;
    dst[0] = 0;
    if (!src) return;
    while (src[n] && n < cap - 1) { dst[n] = src[n]; ++n; }
    dst[n] = 0;
    if (Font_TextWidthScaled(dst, scale) <= maxW) return;
    ellW = Font_TextWidthScaled("...", scale);
    while (n > 0 && Font_TextWidthScaled(dst, scale) + ellW > maxW) {
        dst[--n] = 0;
    }
    if (n + 3 < cap) {
        dst[n++] = '.'; dst[n++] = '.'; dst[n++] = '.'; dst[n] = 0;
    }
}

void Ui_TextCenteredFit(int x0, int width, int y, const char* text, DWORD color)
{
    int tw, maxW, sw, sx;
    float k;
    char tmp[512];
    if (!text || !text[0] || width <= 0) return;
    maxW = width - 24;
    if (maxW < 8) maxW = width;
    tw = Font_TextWidth(text);
    if (tw <= maxW) {
        Font_DrawCentered(x0, width, y, text, color);
        return;
    }
    k = (float)maxW / (float)tw;
    if (k < 0.80f) k = 0.80f;
    if (k > 1.0f) k = 1.0f;
    uiFitEllipsis(text, tmp, sizeof(tmp), maxW, k);
    sw = Font_TextWidthScaled(tmp, k);
    sx = x0 + (width - sw) / 2;
    Font_DrawScaled(sx, y, tmp, color, k);
}

void Ui_TextLeftFit(int x, int y, int maxW, const char* text, DWORD color)
{
    int tw;
    float k;
    char tmp[512];
    if (!text || !text[0] || maxW <= 0) return;
    tw = Font_TextWidth(text);
    if (tw <= maxW) {
        Font_Draw(x, y, text, color);
        return;
    }
    k = (float)maxW / (float)tw;
    if (k < 0.80f) k = 0.80f;
    uiFitEllipsis(text, tmp, sizeof(tmp), maxW, k);
    Font_DrawScaled(x, y, tmp, color, k);
}

// For folders and paths keep the *end* visible (file/folder of interest).
void Ui_TextPathTail(int x, int y, int maxW, const char* text, DWORD color)
{
    int n, first, i, ellW;
    char tmp[300];
    if (!text || !text[0] || maxW <= 0) return;
    if (Font_TextWidth(text) <= maxW) { Font_Draw(x, y, text, color); return; }
    n = 0;
    while (text[n] && n < 298) ++n;
    ellW = Font_TextWidth("...");
    first = n;
    while (first > 0 && Font_TextWidth(text + first - 1) + ellW <= maxW)
        --first;
    tmp[0] = '.'; tmp[1] = '.'; tmp[2] = '.';
    i = 3;
    while (text[first] && i < (int)sizeof(tmp) - 1) tmp[i++] = text[first++];
    tmp[i] = 0;
    Ui_TextLeftFit(x, y, maxW, tmp, color);
}

// File labels retain both a recognizable prefix and the extension/suffix.
// File labels retain both a recognizable prefix and the extension/suffix.
static void uiTextMiddleFit(int x, int y, int maxW, const char* text, DWORD color)
{
    char tmp[300];
    int n = 0, head = 0, tail = 0, i, pos = 0, used, headW = 0, tailW = 0, avail;
    if (!text || !text[0] || maxW <= 0) return;
    if (Font_TextWidth(text) <= maxW) { Font_Draw(x, y, text, color); return; }
    while (text[n] && n < 295) ++n;
    avail = maxW - Font_TextWidth("...");
    if (avail < 18) { Ui_TextLeftFit(x, y, maxW, "...", color); return; }
    // Reserve 45% for the beginning and 55% for the suffix, including .bin/.eos.
    while (head < n) {
        char c[2]; c[0] = text[head]; c[1] = 0;
        used = Font_TextWidth(c);
        if (headW + used > avail * 45 / 100) break;
        headW += used; ++head;
    }
    while (n - tail > head) {
        char c[2]; c[0] = text[n - tail - 1]; c[1] = 0;
        used = Font_TextWidth(c);
        if (tailW + used > avail - headW) break;
        tailW += used; ++tail;
    }
    for (i = 0; i < head && pos < (int)sizeof(tmp) - 4; ++i) tmp[pos++] = text[i];
    tmp[pos++] = '.'; tmp[pos++] = '.'; tmp[pos++] = '.';
    for (i = n - tail; i < n && pos < (int)sizeof(tmp) - 1; ++i) tmp[pos++] = text[i];
    tmp[pos] = 0;
    Ui_TextLeftFit(x, y, maxW, tmp, color);
}

// Wrap an important result across two readable lines rather than shrinking
// the whole message to fit a single 640-wide line.
void Ui_ResultMessage(int x0, int width, int y, const char* text, DWORD color)
{
    int n, split, i, lastSpace, safeW;
    char first[256];
    const char* rest;
    if (!text || !text[0]) return;
    safeW = width - 24;
    if (Font_TextWidth(text) <= safeW) {
        Ui_TextCenteredFit(x0, width, y + 13, text, color);
        return;
    }
    n = 0; lastSpace = 0;
    while (text[n] && n < 250) {
        first[n] = text[n]; first[n + 1] = 0;
        if (text[n] == ' ') lastSpace = n;
        if (Font_TextWidth(first) > safeW) break;
        ++n;
    }
    split = (lastSpace > 0) ? lastSpace : n;
    if (split < 1) split = 1;
    for (i = 0; i < split && i < 254; ++i) first[i] = text[i];
    first[i] = 0;
    rest = text + split;
    while (*rest == ' ') ++rest;
    Ui_TextCenteredFit(x0, width, y, first, color);
    Ui_TextCenteredFit(x0, width, y + 30, rest, color);
}

// Smooth sprite-based halo: no nested geometric outlines, so selected pills
// keep a soft bloom even over the high-contrast Darkone83 backdrop.
static void selGlow(int x, int y, int w, int h, int r)
{
    Gfx_GlowSoft(x + w / 2, y + h / 2, w + 48, h + 30, EOS_GLOW, 32);
    Gfx_GlowSoft(x + w / 2, y + h / 2, w + 18, h + 10 + r / 4, EOS_PURPLE, 18);
}

void Ui_TitleBar(const char* title)
{
    int tw, pw, ph, px, py;
    if (!title) title = "";
    tw = Font_TextWidth(title);
    pw = tw + 64;
    if (pw > g_scrW - 60) pw = g_scrW - 60;
    ph = 44;
    px = (g_scrW - pw) / 2;
    py = 22;

    Gfx_GlowSoft(px + pw / 2, py + ph / 2, pw + 58, ph + 34, EOS_GLOW, 30);
    Gfx_GlowSoft(px + pw / 2, py + ph / 2, pw + 24, ph + 14, EOS_PURPLE, 18);
    // One draw for the entire header face: no cap/body boundary and no
    // internal sheen/edge strokes for alpha/MSAA to expose as a seam.
    Gfx_FillCapsule(px, py, pw, ph, EOS_PURPLE);
    Ui_TextCenteredFit(px, pw, py + (ph - FONT_CH) / 2, title, EOS_WHITE);
}

// Inline controller-button hints shared by footers, script actions and OSK.
// Source strings remain plain ASCII. Separate actions with two spaces:
//   "A Select   X Rename   B Back"
// Each input is parsed once per frame without allocations or platform fonts.
#define UI_HINT_MAX 8
#define UI_HINT_TEXT 112
typedef struct UiHint { int key; char action[UI_HINT_TEXT]; } UiHint;
// 0=plain text, 1=A, 2=B, 3=X, 4=Y, 5=Black, 6=Start, 7=Back, 8=L3, 9=D-pad
static int uiPrefix(const char* p, const char* token)
{
    int i = 0;
    while (token[i]) { if (p[i] != token[i]) return 0; ++i; }
    return 1;
}
static int uiHintKey(const char* p, int* used)
{
    if (uiPrefix(p, "Black ")) { *used = 6; return 5; }
    if (uiPrefix(p, "Start ")) { *used = 6; return 6; }
    if (uiPrefix(p, "Back ")) { *used = 5; return 7; }
    if (uiPrefix(p, "L3 ")) { *used = 3; return 8; }
    if (uiPrefix(p, "D-PAD ")) { *used = 6; return 9; }
    if (p[1] == ' ') {
        *used = 2;
        if (p[0] == 'A') return 1;
        if (p[0] == 'B') return 2;
        if (p[0] == 'X') return 3;
        if (p[0] == 'Y') return 4;
    }
    *used = 0;
    return 0;
}
static int uiParseHints(const char* source, UiHint* hints)
{
    int count = 0, i, n, used;
    const char* p = source;
    const char* begin;
    while (p && *p && count < UI_HINT_MAX) {
        while (*p == ' ') ++p;
        if (!*p) break;
        begin = p;
        while (*p && !(p[0] == ' ' && p[1] == ' ')) ++p;
        n = (int)(p - begin);
        while (n > 0 && begin[n - 1] == ' ') --n;
        if (!n) continue;
        hints[count].key = uiHintKey(begin, &used);
        if (used >= n) used = 0;
        if (used == 0) hints[count].key = 0;
        n -= used;
        if (n >= UI_HINT_TEXT) n = UI_HINT_TEXT - 1;
        for (i = 0; i < n; ++i) hints[count].action[i] = begin[used + i];
        hints[count].action[n] = 0;
        ++count;
    }
    return count;
}
static int uiBadgeWidth(int key)
{
    if (key == 5) return 39;               // original Xbox Black button
    if (key == 6) return 49;               // Start
    if (key == 7) return 46;               // Back
    if (key == 8) return 27;               // left thumb click
    if (key == 9) return 44;               // directional pad
    return key ? 22 : 0;
}
static DWORD uiBadgeColor(int key)
{
    if (key == 1) return EOS_ARGB(0xFF, 42, 157, 74);
    if (key == 2) return EOS_ARGB(0xFF, 199, 55, 65);
    if (key == 3) return EOS_ARGB(0xFF, 49, 112, 212);
    if (key == 4) return EOS_ARGB(0xFF, 211, 163, 35);
    if (key == 5) return EOS_ARGB(0xFF, 49, 52, 61);
    return (EOS_GLOW & 0x00FFFFFF) | 0xE0000000;
}
static const char* uiBadgeLabel(int key)
{
    if (key == 1) return "A";
    if (key == 2) return "B";
    if (key == 3) return "X";
    if (key == 4) return "Y";
    if (key == 5) return "BLK";
    if (key == 6) return "START";
    if (key == 7) return "BACK";
    if (key == 8) return "L3";
    if (key == 9) return "D-PAD";
    return "";
}
static void uiRenderHints(int y, const char* hint, int withPanel, int disabled)
{
    UiHint seg[UI_HINT_MAX];
    int n, i, w = 0, available, panelW, panelX, x, badgeW, badgeH, textW, fontY;
    float k;
    DWORD labelColor = disabled ? EOS_DIM : EOS_WHITE;
    DWORD panel;
    if (!hint || !hint[0]) return;
    n = uiParseHints(hint, seg);
    if (!n) return;
    for (i = 0; i < n; ++i) {
        if (i) w += 16;
        if (seg[i].key) w += uiBadgeWidth(seg[i].key) + 7;
        w += Font_TextWidth(seg[i].action);
    }
    available = g_scrW - 74;
    k = (w > available) ? (float)available / (float)w : 1.0f;
    // The supported hint phrases are intentionally short, keeping button
    // discs and labels comfortably readable even on 480i.
    if (k < 0.68f) k = 0.68f;
    if (withPanel) {
        panelW = (int)((float)w * k + 38.0f);
        if (panelW > g_scrW - 40) panelW = g_scrW - 40;
        panelX = (g_scrW - panelW) / 2;
        panel = (EOS_PANEL & 0x00FFFFFF) | 0xC8000000;
        Gfx_FillCapsule(panelX, y, panelW, 32, panel);
    }
    x = (g_scrW - (int)((float)w * k)) / 2;
    for (i = 0; i < n; ++i) {
        if (i) x += (int)(16.0f * k);
        badgeW = (int)((float)uiBadgeWidth(seg[i].key) * k);
        badgeH = (int)(22.0f * k);
        if (seg[i].key) {
            int badgeY = y + (32 - badgeH) / 2;
            const char* badgeText = uiBadgeLabel(seg[i].key);
            DWORD badgeColor = uiBadgeColor(seg[i].key);
            if (disabled) badgeColor = (badgeColor & 0x00FFFFFF) | 0x75000000;
            Gfx_FillCapsule(x, badgeY, badgeW, badgeH, badgeColor);
            textW = Font_TextWidthScaled(badgeText, k * ((seg[i].key >= 5) ? 0.70f : 0.90f));
            fontY = badgeY + (int)((float)badgeH - (float)FONT_CH * k * ((seg[i].key >= 5) ? 0.70f : 0.90f)) / 2;
            Font_DrawScaled(x + (badgeW - textW) / 2, fontY,
                badgeText, EOS_ARGB(0xFF, 255, 255, 255), k * ((seg[i].key >= 5) ? 0.70f : 0.90f));
            x += badgeW + (int)(7.0f * k);
        }
        fontY = y + (int)((32.0f - (float)FONT_CH * k) / 2.0f);
        Font_DrawScaled(x, fontY, seg[i].action, labelColor, k);
        x += Font_TextWidthScaled(seg[i].action, k);
    }
}

void Ui_Footer(const char* hint)
{
    uiRenderHints(g_scrH - 72, hint, 1, 0);
}

void Ui_ActionHintCenter(int y, const char* hint, int disabled)
{
    uiRenderHints(y, hint, 0, disabled);
}

void Ui_StatusToast(const char* text)
{
    int tw, pw, ph, px, py;
    DWORD panel;
    if (!text || !text[0]) return;
    tw = Font_TextWidth(text);
    pw = tw + 44;
    if (pw > g_scrW - 70) pw = g_scrW - 70;
    ph = 28;
    px = (g_scrW - pw) / 2;
    py = g_scrH - 116;
    panel = (EOS_PANEL & 0x00FFFFFF) | 0xE0000000;
    Gfx_GlowSoft(g_scrW / 2, py + ph / 2, pw + 28, ph + 22, EOS_GLOW, 36);
    Gfx_FillCapsule(px, py, pw, ph, panel);
    Ui_TextCenteredFit(px, pw, py + (ph - FONT_CH) / 2, text, EOS_WHITE);
}

void Ui_ScrollBar(int x, int y, int h, int first, int visible, int total)
{
    int thumbH, travel, thumbY, maxFirst;
    DWORD track, thumb;
    if (total <= visible || visible <= 0 || h < 12) return;
    if (first < 0) first = 0;
    maxFirst = total - visible;
    if (first > maxFirst) first = maxFirst;
    thumbH = h * visible / total;
    if (thumbH < 18) thumbH = 18;
    if (thumbH > h) thumbH = h;
    travel = h - thumbH;
    thumbY = y + ((maxFirst > 0) ? (travel * first / maxFirst) : 0);
    track = (EOS_PANEL & 0x00FFFFFF) | 0x70000000;
    thumb = (EOS_GLOW & 0x00FFFFFF) | 0xD8000000;
    Gfx_FillRounded(x, y, 4, h, 2, track);
    Gfx_FillRounded(x, thumbY, 4, thumbH, 2, thumb);
}

void Ui_PillCentered(int x, int y, int w, int h, int r, int selected, const char* label)
{
    if (selected) selGlow(x, y, w, h, r);
    Gfx_FillRounded(x, y, w, h, r, selected ? EOS_PURPLE : UI_PILL_BG);
    Ui_TextCenteredFit(x, w, y + (h - FONT_CH) / 2, label, selected ? EOS_WHITE : EOS_DIM);
}

void Ui_PillLeft(int x, int y, int w, int h, int r, int selected, const char* label)
{
    if (selected) selGlow(x, y, w, h, r);
    Gfx_FillRounded(x, y, w, h, r, selected ? EOS_PURPLE : UI_PILL_BG);
    Ui_TextLeftFit(x + 18, y + (h - FONT_CH) / 2, w - 36, label,
        selected ? EOS_WHITE : EOS_DIM);
}

void Ui_PillFile(int x, int y, int w, int h, int r, int selected, const char* label)
{
    if (selected) selGlow(x, y, w, h, r);
    Gfx_FillRounded(x, y, w, h, r, selected ? EOS_PURPLE : UI_PILL_BG);
    uiTextMiddleFit(x + 18, y + (h - FONT_CH) / 2, w - 36, label,
        selected ? EOS_WHITE : EOS_DIM);
}

void Ui_PillRow(int x, int y, int w, int h, int r, int selected, int dim,
    const char* label, const char* value)
{
    DWORD lcol, vcol;
    int ty, lw, vw, inner, gap, svw, vx;
    float k;
    lcol = selected ? EOS_WHITE : (dim ? EOS_DIM : EOS_WHITE);
    vcol = selected ? EOS_WHITE : EOS_DIM;
    ty = y + (h - FONT_CH) / 2;
    if (selected) selGlow(x, y, w, h, r);
    Gfx_FillRounded(x, y, w, h, r, selected ? EOS_PURPLE : UI_PILL_BG);

    if (!value || !value[0]) {
        Ui_TextLeftFit(x + 20, ty, w - 40, label, lcol);
        return;
    }

    lw = Font_TextWidth(label);
    vw = Font_TextWidth(value);
    inner = w - 40;
    gap = 18;
    if (lw + vw + gap <= inner) {
        Font_Draw(x + 20, ty, label, lcol);
        Font_Draw(x + w - 20 - vw, ty, value, vcol);
        return;
    }

    k = (float)(inner - gap) / (float)(lw + vw);
    Font_DrawScaled(x + 20, ty, label, lcol, k);
    svw = Font_TextWidthScaled(value, k);
    vx = x + w - 20 - svw;
    Font_DrawScaled(vx, ty, value, vcol, k);
}

// ---- Shared 3D menu (perspective) --------------------------------------
static DWORD perspLerp(DWORD a, DWORD b, int num, int den)
{
    int aa, ar, ag, ab, ba, br, bg2, bb;
    if (num < 0) num = 0;
    if (num > den) num = den;
    aa = (a >> 24) & 0xFF; ar = (a >> 16) & 0xFF; ag = (a >> 8) & 0xFF; ab = a & 0xFF;
    ba = (b >> 24) & 0xFF; br = (b >> 16) & 0xFF; bg2 = (b >> 8) & 0xFF; bb = b & 0xFF;
    aa += (ba - aa) * num / den;
    ar += (br - ar) * num / den;
    ag += (bg2 - ag) * num / den;
    ab += (bb - ab) * num / den;
    return ((DWORD)aa << 24) | ((DWORD)ar << 16) | ((DWORD)ag << 8) | (DWORD)ab;
}

#define M3_R        1.85f
#define M3_ZC       3.95f
#define M3_STEP     0.20f
#define M3_K        0.0052f
#define M3_HH       0.11f
#define M3_PAD      0.18f
#define M3_MAX_HW   1.42f
#define M3_FAN      4
#define M3_AMAX     1.20f
#define M3_SWAY     0.05f
#define M3_EASE     10.0f
#define M3_SEL_GLOW 120
#define M3_SAFE_TOP_DEFAULT  92
#define M3_SAFE_BOTTOM_DEFAULT (g_scrH - 82)
#define M3_SAFE_FADE 20

static float s_selAnim = 0.0f;
static int   s_animCount = -1;
static DWORD s_animTick = 0;

// Project a world-space menu Y/Z point back into the 640x480 design space.
// This exactly mirrors Gfx_Begin3D's 60-degree vertical projection (_22=1.73205).
// Keep it local so the updater does not need a new public GFX API.
static float wheelProjectY(float y, float z)
{
    if (z <= 0.001f) return 240.0f;
    return 240.0f - (y * 1.73205f / z) * 240.0f;
}

static DWORD wheelScaleAlpha(DWORD c, float k)
{
    DWORD a;
    if (k <= 0.0f) return c & 0x00FFFFFF;
    if (k >= 1.0f) return c;
    a = (c >> 24) & 0xFF;
    a = (DWORD)((float)a * k);
    return (c & 0x00FFFFFF) | (a << 24);
}

// Receding pills fade before they enter the title/header or footer helper zones.
// The selected pill is intentionally exempt so its placement never shifts.
static float wheelSafeFade(float yc, float zc, float ca, float sa, int topY, int bottomY)
{
    float y1, z1, y2, z2, p1, p2, top, bottom, kt, kb, k;
    y1 = yc + M3_HH * ca; z1 = zc + M3_HH * sa;
    y2 = yc - M3_HH * ca; z2 = zc - M3_HH * sa;
    p1 = wheelProjectY(y1, z1);
    p2 = wheelProjectY(y2, z2);
    top = (p1 < p2) ? p1 : p2;
    bottom = (p1 > p2) ? p1 : p2;

    kt = (top - (float)topY) / (float)M3_SAFE_FADE;
    kb = ((float)bottomY - bottom) / (float)M3_SAFE_FADE;
    k = (kt < kb) ? kt : kb;
    if (k < 0.0f) k = 0.0f;
    if (k > 1.0f) k = 1.0f;
    return k;
}

static void wheelItem(const char* label, int i, int sel, float aSway, float selPulse,
    int topY, int bottomY)
{
    float a, aa, ca, sa, yc, zc, twh, hw, f, textK, safeFade;
    int ia, tw;
    DWORD pill, txt;

    a = (s_selAnim - (float)i) * M3_STEP + aSway;
    aa = (a < 0.0f) ? -a : a;
    if (aa > M3_AMAX) return;

    Gfx_SinCos(a, &sa, &ca);
    yc = M3_R * sa;
    zc = M3_ZC - M3_R * ca;
    tw = Font_TextWidth(label);
    textK = M3_K;
    twh = (float)tw * textK * 0.5f;
    if (twh + M3_PAD > M3_MAX_HW && tw > 0) {
        textK = ((M3_MAX_HW - M3_PAD) * 2.0f) / (float)tw;
        twh = (float)tw * textK * 0.5f;
    }
    hw = twh + M3_PAD;
    if (hw < M3_HH * 1.6f) hw = M3_HH * 1.6f;

    f = 1.0f - aa / M3_AMAX;
    if (f < 0.0f) f = 0.0f;
    ia = (int)(f * 100.0f);

    if (i == sel) {
        zc -= 0.075f + selPulse * 0.025f;
        hw += M3_HH * (0.10f + selPulse * 0.06f);
        if (hw > M3_MAX_HW + 0.06f) hw = M3_MAX_HW + 0.06f;
        pill = (EOS_PURPLE & 0x00FFFFFF) | 0x78000000;
        txt = EOS_WHITE | 0xFF000000;
    }
    else {
        int pa;
        pa = 0x22 + ia * 0x66 / 100;
        pill = (perspLerp(EOS_PANEL, EOS_BG, 100 - ia, 100) & 0x00FFFFFF) | ((DWORD)pa << 24);
        txt = (perspLerp(EOS_DIM, EOS_BG, 100 - ia, 100) & 0x00FFFFFF)
            | ((DWORD)(0x40 + ia * 0xBF / 100) << 24);

        safeFade = wheelSafeFade(yc, zc, ca, sa, topY, bottomY);
        if (safeFade <= 0.0f) return;
        pill = wheelScaleAlpha(pill, safeFade);
        txt = wheelScaleAlpha(txt, safeFade);
    }

    if (i == sel) {
        int glowPeak;
        glowPeak = M3_SEL_GLOW + (int)(selPulse * 38.0f);
        Gfx_GlowX3D(0.0f, yc, zc + 0.018f, ca, sa,
            hw + 0.19f, M3_HH + 0.11f, EOS_GLOW, glowPeak);
    }

    Gfx_PillX3D(0.0f, yc, zc, ca, sa, hw, M3_HH, pill);
    Font_Draw3D(0.0f, yc, zc, ca, sa, textK, label, txt);
}

void Ui_Menu3D(const char** items, int count, int sel)
{
    DWORD now;
    float dt, d, aSway, pulseSin, selPulse;
    int ad, side, j;
    int topY, bottomY;

    if (count <= 0) return;
    if (sel < 0) sel = 0; else if (sel >= count) sel = count - 1;

    topY = M3_SAFE_TOP_DEFAULT;
    bottomY = M3_SAFE_BOTTOM_DEFAULT;
    now = GetTickCount();
    if (s_animCount != count) { s_selAnim = (float)sel; s_animCount = count; s_animTick = now; }
    dt = (float)(now - s_animTick) / 1000.0f;
    if (dt < 0.0f) dt = 0.0f;
    if (dt > 0.10f) dt = 0.10f;
    s_animTick = now;
    d = (float)sel - s_selAnim;
    if (d > 2.5f || d < -2.5f) s_selAnim = (float)sel;
    else {
        float t;
        t = M3_EASE * dt;
        if (t > 1.0f) t = 1.0f;
        s_selAnim += d * t;
    }

    {
        float sv;
        Gfx_SinCos((float)now * 0.0011f, &sv, 0);
        aSway = M3_SWAY * sv;
    }
    Gfx_SinCos((float)now * 0.0024f, &pulseSin, 0);
    selPulse = (pulseSin + 1.0f) * 0.5f;

    Gfx_Begin3D();
    for (ad = M3_FAN; ad >= 1; --ad) {
        for (side = -1; side <= 1; side += 2) {
            j = sel + side * ad;
            if (j < 0 || j >= count) continue;
            wheelItem(items[j], j, sel, aSway, selPulse, topY, bottomY);
        }
    }
    wheelItem(items[sel], sel, sel, aSway, selPulse, topY, bottomY);
    Gfx_End3D();
}