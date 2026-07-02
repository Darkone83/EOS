// eos_ui.cpp -- shared menu chrome. See eos_ui.h.
//
// RXDK / MSVC2003 / C89: declarations before statements, no CRT.
#include "eos_ui.h"
#include "eos_gfx.h"
#include "eos_font.h"


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

// Solid base fill, then the real 3D parallax field behind everything.
void Ui_Backdrop(void)
{
    Gfx_Fill(0, 0, (float)g_scrW, (float)g_scrH, EOS_BG);
    orbsStep();
    Gfx_Begin3D();
    orbsDraw();
    Gfx_End3D();
}

// Soft accent halo behind a selected pill.
static void selGlow(int x, int y, int w, int h, int r)
{
    Gfx_GlowRounded(x, y, w, h, r, EOS_GLOW);   // soft additive bloom halo
}

void Ui_TitleBar(const char* title)
{
    int tw = Font_TextWidth(title);
    int pw = tw + 64;
    int ph = 44;
    int px = (g_scrW - pw) / 2;
    int py = 22;
    selGlow(px, py, pw, ph, ph / 2);
    Gfx_FillRounded(px, py, pw, ph, ph / 2, EOS_PURPLE);
    Font_DrawCentered(0, g_scrW, py + (ph - FONT_CH) / 2, title, EOS_WHITE);
}

void Ui_Footer(const char* hint)
{
    Font_DrawCentered(0, g_scrW, g_scrH - 66, hint, EOS_DIM);
}

void Ui_PillCentered(int x, int y, int w, int h, int r, int selected, const char* label)
{
    if (selected) selGlow(x, y, w, h, r);
    Gfx_FillRounded(x, y, w, h, r, selected ? EOS_PURPLE : UI_PILL_BG);
    Font_DrawCentered(x, w, y + (h - FONT_CH) / 2, label, selected ? EOS_WHITE : EOS_DIM);
}

void Ui_PillLeft(int x, int y, int w, int h, int r, int selected, const char* label)
{
    if (selected) selGlow(x, y, w, h, r);
    Gfx_FillRounded(x, y, w, h, r, selected ? EOS_PURPLE : UI_PILL_BG);
    Font_Draw(x + 18, y + (h - FONT_CH) / 2, label, selected ? EOS_WHITE : EOS_DIM);
}

void Ui_PillRow(int x, int y, int w, int h, int r, int selected, int dim,
    const char* label, const char* value)
{
    DWORD lcol = selected ? EOS_WHITE : (dim ? EOS_DIM : EOS_WHITE);
    int   ty = y + (h - FONT_CH) / 2;
    if (selected) selGlow(x, y, w, h, r);
    Gfx_FillRounded(x, y, w, h, r, selected ? EOS_PURPLE : UI_PILL_BG);
    Font_Draw(x + 20, ty, label, lcol);
    if (value) {
        int vx = x + w - 20 - Font_TextWidth(value);
        Font_Draw(vx, ty, value, selected ? EOS_WHITE : EOS_DIM);
    }
}

// ---- Shared 3D menu (perspective) --------------------------------------
// Per-channel ARGB blend (kept for receding-panel color fades).
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

// Tuning knobs (world units / radians). Camera at the origin looking +Z.
#define M3_R      1.85f     // wheel radius -- smaller = tighter vertical spread
#define M3_ZC     3.95f     // wheel-axis depth (front pill sits at ZC - R = 2.10)
#define M3_STEP   0.20f     // angular spacing per item (~11.5 deg tilt/step)
#define M3_K      0.0052f   // world units per atlas pixel (label ~22px at front)
#define M3_HH     0.11f     // pill half-height (trimmed)
#define M3_PAD    0.18f     // horizontal padding around the label (trimmed)
#define M3_FAN    4         // items considered each side of the selection
#define M3_AMAX   1.20f     // past this angle (~69 deg) an item has rotated away
#define M3_SWAY   0.05f     // idle sway amplitude (rad) -- keeps it alive
#define M3_EASE   10.0f     // selection-snap speed (higher = snappier)

// Animation state. selAnim is the fractional, eased selection the wheel rotates
// to; the integer sel is the target. Reset when the list (count) changes.
static float s_selAnim = 0.0f;
static int   s_animCount = -1;
static DWORD s_animTick = 0;

// One pill on the wheel at integer index i. The item's angle around the wheel
// drives BOTH its position (y/z on the cylinder) and its tilt, so its face
// turns toward/away from the camera -- genuine rotation. Closer to the front
// (smaller |angle|) = brighter + more opaque; far items fade out.
static void wheelItem(const char* label, int i, int sel, float aSway)
{
    float a = (s_selAnim - (float)i) * M3_STEP + aSway;   // +index drops BELOW center
    float aa = (a < 0.0f) ? -a : a;
    float ca, sa, yc, zc, twh, hw, f;
    int   ia;
    DWORD pill, txt;

    if (aa > M3_AMAX) return;                          // rotated away -- skip

    Gfx_SinCos(a, &sa, &ca);
    yc = M3_R * sa;                                    // up/down on the cylinder
    zc = M3_ZC - M3_R * ca;                            // front-most at a==0
    twh = (float)Font_TextWidth(label) * M3_K * 0.5f;
    hw = twh + M3_PAD;
    if (hw < M3_HH * 1.6f) hw = M3_HH * 1.6f;          // keep tiny labels pill-shaped

    f = 1.0f - aa / M3_AMAX;                           // 1 at front -> 0 at the edge
    if (f < 0.0f) f = 0.0f;
    ia = (int)(f * 100.0f);                            // 0..100 for the integer lerps

    if (i == sel) {
        pill = (EOS_PURPLE & 0x00FFFFFF) | 0x80000000; // accent, clearly translucent
        txt = EOS_WHITE | 0xFF000000;
    }
    else {
        int pa = 0x22 + ia * 0x66 / 100;               // nearer rows denser, far airier
        pill = (perspLerp(EOS_PANEL, EOS_BG, 100 - ia, 100) & 0x00FFFFFF) | ((DWORD)pa << 24);
        txt = (perspLerp(EOS_DIM, EOS_BG, 100 - ia, 100) & 0x00FFFFFF)
            | ((DWORD)(0x40 + ia * 0xBF / 100) << 24);  // label fades with depth too
    }

    Gfx_PillX3D(0.0f, yc, zc, ca, sa, hw, M3_HH, pill);
    Font_Draw3D(0.0f, yc, zc, ca, sa, M3_K, label, txt);
}

void Ui_Menu3D(const char** items, int count, int sel)
{
    DWORD now = GetTickCount();
    float dt, d, aSway;
    int   ad, side, j;

    if (count <= 0) return;
    if (sel < 0) sel = 0; else if (sel >= count) sel = count - 1;

    // Advance the easing toward the selected index (snap on list change / wrap).
    if (s_animCount != count) { s_selAnim = (float)sel; s_animCount = count; s_animTick = now; }
    dt = (float)(now - s_animTick) / 1000.0f;
    if (dt < 0.0f) dt = 0.0f;
    if (dt > 0.10f) dt = 0.10f;
    s_animTick = now;
    d = (float)sel - s_selAnim;
    if (d > 2.5f || d < -2.5f) s_selAnim = (float)sel;      // wrapped -- don't spin around
    else { float t = M3_EASE * dt; if (t > 1.0f) t = 1.0f; s_selAnim += d * t; }

    { float sv; Gfx_SinCos((float)now * 0.0011f, &sv, 0); aSway = M3_SWAY * sv; }   // slow idle rock

    Gfx_Begin3D();
    // Farthest (most rotated) first so nearer pills overlap on top.
    for (ad = M3_FAN; ad >= 1; --ad) {
        for (side = -1; side <= 1; side += 2) {
            j = sel + side * ad;
            if (j < 0 || j >= count) continue;
            wheelItem(items[j], j, sel, aSway);
        }
    }
    wheelItem(items[sel], sel, sel, aSway);                  // selected last, on top
    Gfx_End3D();
}