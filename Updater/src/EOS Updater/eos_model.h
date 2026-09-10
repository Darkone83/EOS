#pragma once
// eos_model.h -- Darkone83 updater background model (render module).
//
// Renders the embedded higher-detail Darkone83 character mesh into the existing
// 3D scene as a drop-in replacement for the orb field, gated by the Darkone83 theme. Mesh and
// albedo are baked into the XBE (eos_model_data.h / eos_model_tex.h) so the
// theme is fully self-contained -- no SD assets required.
//
// Draw contract: call Model_Draw() BETWEEN Gfx_Begin3D() and Gfx_End3D(); it
// borrows that pass's perspective projection + linear fog, and restores every
// render state it changes so the menu wheel that follows renders unaffected.
//
// Depth: a solid concave mesh needs a depth buffer. This module enables
// ZENABLE/ZWRITE around its own draw only; the device must be created with an
// auto depth-stencil (see the Gfx_Init diff) and Gfx_Begin() must clear Z.
//
// Failsafe: Model_Init() is lazy and one-shot. If VB/IB/texture creation fails
// it latches "unavailable" and Model_Ready() returns 0, so Ui_Backdrop() falls
// back to the orb field. Nothing here runs on the boot path unless the Darkone83
// theme is actually selected.
//
// RXDK / MSVC2003 / C89: declarations before statements, POD data, no CRT beyond
// malloc/free + memcpy.
#pragma once
#define EOS_MODEL_API_H 1

// Build GPU resources on first call (idempotent). Returns 1 if ready to draw,
// 0 if unavailable (caller should fall back to orbs). Safe to call every frame.
int  Model_Init(void);

// 1 once resources are live, 0 before Init or after a failed Init.
int  Model_Ready(void);

// Draw the figure. tsec = seconds (e.g. GetTickCount()/1000.0f) for the slow
// idle turntable. Must be inside a Gfx_Begin3D()/Gfx_End3D() scope.
void Model_Draw(float tsec);

// Release GPU resources (VB/IB/texture). Optional; the loader normally lives
// until reboot. Init() will rebuild on the next call.
void Model_Free(void);