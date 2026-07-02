#pragma once
// eos_osk.h -- controller on-screen keyboard overlay (adapted from DarkDash's
// dd_osk, which came from SceneChat). Retooled onto the Eos loader primitives:
// Gfx_Fill panels, Font_Draw/Font_DrawCentered labels, EOS_* colors, drawn in
// the real g_scrW/g_scrH space (no virtual scaler).
//
// Two layouts:
//   OSK_TEXT     full QWERTY (lower / upper / symbols; X cycles the set)
//   OSK_NUMERIC  10-key pad for numbers + '.'  (IP octets, etc.)
//
// Usage (overlay on top of whatever phase is active):
//   Osk_Open(OSK_TEXT, Bank_Name(idx), maxLen);
//   each frame: int r = Osk_Update(edges);   // 0 open, 1 confirm, -1 cancel
//   in the render pass (inside Gfx_Begin/End): Osk_Draw();
//   on confirm: Osk_GetText(buf, sizeof buf);
//
// Controller: D-pad move, A/LTrigger select, B backspace, X cycle set (text),
//   Y space (text), L3 caps (text), Start confirm, Back cancel.
#pragma once
#include <xtl.h>

#define OSK_MAX_LEN 32

enum { OSK_TEXT = 0, OSK_NUMERIC = 1 };

void Osk_Open(int mode, const char* initial, int maxLen);
void Osk_Close(void);
int  Osk_IsOpen(void);
int  Osk_Update(WORD pressed);   // 0 still open, 1 confirmed, -1 cancelled
void Osk_Draw(void);             // call inside the active Gfx_Begin/End pass
void Osk_GetText(char* buf, int buflen);