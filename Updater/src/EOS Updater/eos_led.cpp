// eos_led.cpp -- Bank LED color picker (PH_LEDCOLOR), self-contained.
//
// Renders a 2x6 grid of color pills (12 palette entries; [0]=Off). D-pad moves the
// highlight, A commits (Desc_SetColor), B backs out without changing. Opens on the
// bank's current color. Charcoal text on every pill (uniform), Off = grey pill.
//
// See eos_led.h for the main.cpp integration contract.

#include <xtl.h>
#include "eos_led.h"
#include "eos_gfx.h"
#include "eos_font.h"
#include "eos_ui.h"
#include "eos_theme.h"
#include "eos_descriptor.h"
#include "input.h"

// ---- picker state ----------------------------------------------------------
static int s_bank = 0;    // target visible bank (0..3)
static int s_return = 0;    // AppPhase (int) to return to
static int s_sel = 0;    // highlighted palette index (0..11)

// charcoal text on all pills (uniform; no per-pill light/dark switching)
#define LED_TEXT_CHARCOAL EOS_ARGB(0xFF,0x1A,0x1A,0x1A)
#define LED_OFF_BG        EOS_ARGB(0xFF,0x3A,0x3A,0x3A)   // grey for the Off cell

// grid geometry
#define LED_COLS 6
#define LED_ROWS 2

// find the palette index whose color matches rgb; default 0 (Off) if none.
static int PaletteIndexOf(unsigned int rgb)
{
    int i;
    rgb &= 0xFFFFFFu;
    for (i = 0; i < EOS_LED_PALETTE_N; ++i)
        if ((Eos_LedPalette[i] & 0xFFFFFFu) == rgb) return i;
    return 0;
}

void LedPick_Open(int bankIdx, int returnPhase)
{
    s_bank = bankIdx;
    s_return = returnPhase;
    // open ON the bank's current color
    s_sel = PaletteIndexOf(Desc_GetColor(bankIdx));
}

// local edge-detect (module doesn't use main.cpp's static Pressed())
static int Edge(unsigned short now, unsigned short prev, unsigned short mask)
{
    return ((now & mask) != 0) && ((prev & mask) == 0);
}

int LedPick_Frame(unsigned short b, unsigned short prev)
{
    int row, col, i;

    // ---- input ----
    col = s_sel % LED_COLS;
    row = s_sel / LED_COLS;

    if (Edge(b, prev, BTN_DPAD_LEFT))  col = (col + LED_COLS - 1) % LED_COLS;
    if (Edge(b, prev, BTN_DPAD_RIGHT)) col = (col + 1) % LED_COLS;
    if (Edge(b, prev, BTN_DPAD_UP))    row = (row + LED_ROWS - 1) % LED_ROWS;
    if (Edge(b, prev, BTN_DPAD_DOWN))  row = (row + 1) % LED_ROWS;
    s_sel = row * LED_COLS + col;

    if (Edge(b, prev, BTN_A)) {
        Desc_SetColor(s_bank, Eos_LedPalette[s_sel]);   // commit -> descriptor + reload
        return s_return;                                // leave to caller's return phase
    }
    if (Edge(b, prev, BTN_B)) {
        return s_return;                                // back out, no change
    }

    // ---- render ----
    Gfx_Begin(EOS_BG); Ui_Backdrop();
    Ui_TitleBar("LED COLOR");

    // grid layout centered on screen
    // Design space is 640x480 (see eos_gfx.cpp). Size the 6x2 grid to fit inside
    // a TV-safe margin: 6*84 + 5*8 = 544 wide, centered on 640.
    int cellW = 84, cellH = 54, gapX = 8, gapY = 14, radius = 12;
    int gridW = LED_COLS * cellW + (LED_COLS - 1) * gapX;
    int gridH = LED_ROWS * cellH + (LED_ROWS - 1) * gapY;
    int x0 = (g_scrW - gridW) / 2;
    int y0 = (g_scrH - gridH) / 2 + 10;

    for (i = 0; i < EOS_LED_PALETTE_N; ++i) {
        int cx = x0 + (i % LED_COLS) * (cellW + gapX);
        int cy = y0 + (i / LED_COLS) * (cellH + gapY);

        unsigned int rgb = Eos_LedPalette[i] & 0xFFFFFFu;
        DWORD fill = (i == 0)
            ? LED_OFF_BG
            : EOS_ARGB(0xFF, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);

        // selection glow behind the highlighted pill
        if (i == s_sel)
            Gfx_GlowRounded(cx - 5, cy - 5, cellW + 10, cellH + 10, radius + 4, EOS_GLOW);

        Gfx_FillRounded(cx, cy, cellW, cellH, radius, fill);

        // selection border (accent) around the highlighted pill
        if (i == s_sel) {
            DWORD acc = EOS_PURPLE;
            Gfx_Fill((float)cx, (float)cy, (float)cellW, 3, acc);
            Gfx_Fill((float)cx, (float)(cy + cellH - 3), (float)cellW, 3, acc);
            Gfx_Fill((float)cx, (float)cy, 3, (float)cellH, acc);
            Gfx_Fill((float)(cx + cellW - 3), (float)cy, 3, (float)cellH, acc);
        }

        // uniform charcoal label, scaled to fit the pill and centered.
        {
            const char* nm = Eos_LedPaletteName[i];
            float k = 0.8f;                                   // slightly smaller for fit
            int tw = Font_TextWidthScaled(nm, k);
            int tx = cx + (cellW - tw) / 2;
            int ty = cy + cellH / 2 - 8;
            Font_DrawScaled(tx, ty, nm, LED_TEXT_CHARCOAL, k);
        }
    }

    // helper line (real functions only)
    Font_DrawCentered(0, g_scrW, g_scrH - 60,
        "D-PAD MOVE    A SET    B BACK", EOS_DIM);

    Gfx_End();
    return -1;   // stay in the picker
}