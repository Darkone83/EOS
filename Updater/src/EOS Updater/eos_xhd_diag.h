#pragma once
#include <xtl.h>

/*
   Run the destructive video-mode diagnostic sequence. The caller must release
   the updater's D3D/font/splash resources first; this routine owns D3D while it
   runs. It writes D:\\regs.txt (or the supplied path) and returns after the
   480p -> 720p -> 1080i sequence is complete.
*/
BOOL XhdDiag_Run(const char* outPath);

/*
   Non-destructive current-state dump. Does not create/release D3D or change
   video modes; it simply streams ADV7511 registers 0x00..0xFF through the
   existing EOS native 0x6E diagnostic bridge and writes them to outPath.
*/
BOOL XhdDiag_DumpCurrent(const char* outPath);
