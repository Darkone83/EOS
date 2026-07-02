// eos_theme.cpp -- Eos loader theme system. See eos_theme.h.
//
// RXDK / MSVC2003 / C89: declarations before statements, no CRT.
#include "eos_theme.h"
#include "eos_config.h"

// Local ARGB helper (eos_gfx.h also defines EOS_ARGB; we keep this file free of
// the graphics include so the palette table stays a pure data definition).
#define THEME_ARGB(a,r,g,b) ((DWORD)(((a)<<24)|((r)<<16)|((g)<<8)|(b)))

// Palette table. Index 0 is the Eos default (accent purple 168,85,247). Each
// theme picks a near-black tinted background, an accent, a bright text, and a
// muted secondary so contrast holds on both the menu and the info panels.
static const EosTheme k_themes[] = {
    // name           bg                         bg2                        panel                      accent                       glow                         white                        dim
    { "Eos Purple", THEME_ARGB(0xFF,10, 8,18), THEME_ARGB(0xFF, 4, 3, 8), THEME_ARGB(0xFF,26,22,40), THEME_ARGB(0xFF,168,85,247), THEME_ARGB(0xFF,199,125,255), THEME_ARGB(0xFF,245,243,255), THEME_ARGB(0xFF,139,127,168) },
    { "Cyber Cyan", THEME_ARGB(0xFF, 6,16,20), THEME_ARGB(0xFF, 2, 7,10), THEME_ARGB(0xFF,14,32,40), THEME_ARGB(0xFF, 34,211,238), THEME_ARGB(0xFF,103,232,249), THEME_ARGB(0xFF,236,254,255), THEME_ARGB(0xFF, 94,138,153) },
    { "Amber",      THEME_ARGB(0xFF,18,14, 4), THEME_ARGB(0xFF, 9, 6, 2), THEME_ARGB(0xFF,36,27,10), THEME_ARGB(0xFF,245,158, 11), THEME_ARGB(0xFF,252,211, 77), THEME_ARGB(0xFF,255,251,235), THEME_ARGB(0xFF,153,129, 78) },
    { "Matrix",     THEME_ARGB(0xFF, 4,14, 6), THEME_ARGB(0xFF, 2, 7, 3), THEME_ARGB(0xFF,12,32,15), THEME_ARGB(0xFF, 52,211,113), THEME_ARGB(0xFF,110,231,160), THEME_ARGB(0xFF,236,253,243), THEME_ARGB(0xFF, 78,138,100) },
    { "Crimson",    THEME_ARGB(0xFF,18, 6, 8), THEME_ARGB(0xFF, 9, 3, 4), THEME_ARGB(0xFF,36,10,15), THEME_ARGB(0xFF,244, 63, 94), THEME_ARGB(0xFF,251,113,133), THEME_ARGB(0xFF,255,241,242), THEME_ARGB(0xFF,153, 84, 94) },
    { "Ice Blue",   THEME_ARGB(0xFF, 6,10,18), THEME_ARGB(0xFF, 2, 5,10), THEME_ARGB(0xFF,14,26,42), THEME_ARGB(0xFF, 96,165,250), THEME_ARGB(0xFF,147,197,253), THEME_ARGB(0xFF,239,246,255), THEME_ARGB(0xFF, 94,116,143) },
    { "Synthwave",  THEME_ARGB(0xFF,14, 6,24), THEME_ARGB(0xFF, 7, 3,12), THEME_ARGB(0xFF,30,14,46), THEME_ARGB(0xFF,255,106,213), THEME_ARGB(0xFF,255,156,230), THEME_ARGB(0xFF,253,240,255), THEME_ARGB(0xFF,156,106,168) },
    { "Slate",      THEME_ARGB(0xFF,12,14,18), THEME_ARGB(0xFF, 6, 7, 9), THEME_ARGB(0xFF,26,30,38), THEME_ARGB(0xFF,148,163,184), THEME_ARGB(0xFF,203,213,225), THEME_ARGB(0xFF,248,250,252), THEME_ARGB(0xFF,100,116,139) }
};
#define THEME_COUNT ((int)(sizeof(k_themes) / sizeof(k_themes[0])))

EosTheme g_theme = { "Eos Purple",
                     THEME_ARGB(0xFF,10,8,18), THEME_ARGB(0xFF,4,3,8), THEME_ARGB(0xFF,26,22,40),
                     THEME_ARGB(0xFF,168,85,247), THEME_ARGB(0xFF,199,125,255),
                     THEME_ARGB(0xFF,245,243,255), THEME_ARGB(0xFF,139,127,168) };

static int s_idx = 0;

static void apply(int idx)
{
    if (idx < 0) idx = 0;
    if (idx >= THEME_COUNT) idx = THEME_COUNT - 1;
    s_idx = idx;
    g_theme = k_themes[idx];
}

void Theme_Init(void)
{
    apply(Config_GetThemeIdx());   // config default is 0 if never saved
}

int Theme_Count(void) { return THEME_COUNT; }

const char* Theme_Name(int idx)
{
    if (idx < 0 || idx >= THEME_COUNT) return 0;
    return k_themes[idx].name;
}

int Theme_Index(void) { return s_idx; }

void Theme_Set(int idx)
{
    apply(idx);
    Config_SetThemeIdx(s_idx);     // persist (clamped index)
}

void Theme_Preview(int idx) { apply(idx); }      // live recolor, no flash write
void Theme_Commit(void)
{
    if (Config_GetThemeIdx() != s_idx)           // only touch flash on a real change
        Config_SetThemeIdx(s_idx);
}

void Theme_Next(void) { Theme_Preview((s_idx + 1) % THEME_COUNT); }
void Theme_Prev(void) { Theme_Preview((s_idx + THEME_COUNT - 1) % THEME_COUNT); }