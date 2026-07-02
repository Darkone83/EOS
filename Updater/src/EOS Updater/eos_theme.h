// eos_theme.h -- Eos loader theme system.
//
// A theme is a small palette of ARGB colors. The active theme lives in the
// global g_theme; the EOS_* color macros in eos_gfx.h read from it, so every
// existing draw call (menu, OSK, splash, settings, HTTP status) re-colors with
// zero changes when the theme switches. The chosen theme index is persisted in
// the loader config page (see eos_config), so it survives a reboot.
//
// RXDK / MSVC2003 / C89: declarations before statements, no CRT.
#pragma once
#include <xtl.h>

typedef struct EosTheme {
    const char* name;
    DWORD       bg;       // gradient top                       (EOS_BG)
    DWORD       bg2;      // gradient bottom                    (EOS_BG2)
    DWORD       panel;    // pill / row surface                 (EOS_PANEL)
    DWORD       accent;   // primary accent: title, selection   (EOS_PURPLE)
    DWORD       glow;     // brighter accent: selection glow     (EOS_GLOW)
    DWORD       white;    // primary / selected text            (EOS_WHITE)
    DWORD       dim;      // secondary / unselected text        (EOS_DIM)
} EosTheme;

// Active theme. The EOS_* color macros resolve to fields of this. Initialized
// to the default (Eos Purple) so colors are valid even before Theme_Init().
extern EosTheme g_theme;

void        Theme_Init(void);          // apply the theme index saved in config
int         Theme_Count(void);
const char* Theme_Name(int idx);       // name of theme idx (NULL if out of range)
int         Theme_Index(void);         // current active index
void        Theme_Set(int idx);        // apply + persist (clamped)
void        Theme_Preview(int idx);    // apply only, no persist (live picker)
void        Theme_Commit(void);        // persist whatever is currently applied
void        Theme_Next(void);          // cycle forward (settings UI)
void        Theme_Prev(void);          // cycle back