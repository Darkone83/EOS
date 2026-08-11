// eos_led.h -- Bank LED color picker (PH_LEDCOLOR phase, self-contained module).
//
// A shared 2x6 palette picker reused by three entry points:
//   * loader flash flow (after "Flashed OK", Option B)
//   * bank management (Black button)
//   * (web UI uses eos_http.cpp directly, not this module)
//
// The module owns rendering, selection, D-pad nav, and the Desc_SetColor write.
// It does NOT touch main.cpp statics (GotoPhase/s_prevBtn/Pressed): main passes the
// button state in and acts on the returned phase.
//
// Phase integration (main.cpp):
//   - add PH_LEDCOLOR to AppPhase
//   - to enter:  LedPick_Open(bankIdx, returnPhaseInt);  GotoPhase(PH_LEDCOLOR);
//   - each frame: { int nx = LedPick_Frame(b, s_prevBtn);
//                   if (nx >= 0) GotoPhase((AppPhase)nx); }
//     LedPick_Frame returns -1 to stay in the picker, or the phase-int to leave to.
#ifndef EOS_LED_H
#define EOS_LED_H

#ifdef __cplusplus
extern "C" {
#endif

	// Open the picker for a bank (visible index 0..3). returnPhase is the AppPhase
	// (as int) to return to when the user picks (A) or backs out (B).
	void LedPick_Open(int bankIdx, int returnPhase);

	// Render + handle input for one frame. `b` = current buttons, `prev` = previous
	// frame buttons (edge detection). Returns -1 to stay in the picker, or the phase
	// int to transition to (the returnPhase supplied to LedPick_Open).
	int  LedPick_Frame(unsigned short b, unsigned short prev);

#ifdef __cplusplus
}
#endif

#endif // EOS_LED_H