#pragma once
// eos_update.h -- update orchestration: ties eos_smbus + eos_stage + eos_crc into
// the three flows (loader / BIOS / XbDiag), with the confirm-on-commit rule and
// the XbDiag version gate.
//
// The engine is a pumped state machine so the UI stays responsive and the commit
// confirmation lands exactly at the scratch->flash boundary:
//
//   Update_Begin*(...)            arms the region, loads the job
//   each frame: Update_Pump(&j)   stages (chunked) -> validates -> PAUSES at
//                                 UPD_CONFIRM
//   UI shows Update_ConfirmText(&j); on the user's YES:
//     Update_Confirm(&j)          -> commits -> UPD_DONE
//   on NO / any failure:
//     Update_Cancel(&j)           -> Smb_Clear, UPD_IDLE
//
// The caller loads the whole image into RAM first (from local file or network)
// and hands the buffer + length in; this engine does no file/network I/O.
#include <xtl.h>

/* ---- versioning ---- */
typedef struct { BYTE maj, min, pat; } EosVer;

/* <0 if a<b, 0 if equal, >0 if a>b  (semver major.minor.patch) */
int  Ver_Compare(EosVer a, EosVer b);

/* Parse a .ver blob:  "version = 1.0.4" and "crc32 = 0xDEADBEEF" (order-free).
   Returns TRUE if at least a version was found; crc_out set if present (else 0). */
BOOL Ver_Parse(const char* text, int len, EosVer* ver_out, DWORD* crc_out);

/* Installed XbDiag version, read from the XbDiag bank's NAME (e.g. the loader
   stores "XbDiag Lite 1.0.4"; the version is parsed straight out of it).
   Returns FALSE if the XbDiag bank is empty or has no version in its name. */
BOOL Update_XbDiagInstalled(EosVer* out);

/* Extract a "maj.min.pat" embedded anywhere in a string (finds the first digit
   run that is followed by a '.'). Returns TRUE if a version was found. */
BOOL Ver_ParseName(const char* name, EosVer* out);

/* Format "maj.min.pat" into buf (no CRT). */
void Ver_Format(EosVer v, char* buf, int cap);

/* ---- job state machine ---- */
enum {
    UPD_IDLE = 0,
    UPD_STAGING,        /* streaming image -> scratch (chunked; shows progress) */
    UPD_VALIDATING,     /* SETCRC + VALIDATE, waiting on staged_valid */
    UPD_CONFIRM,        /* validated; waiting for the user to confirm the commit */
    UPD_COMMITTING,     /* COMMIT in flight (flash is being written) */
    UPD_DONE,           /* committed OK */
    UPD_FAILED          /* see .msg for why */
};

typedef struct {
    BYTE                 region;     /* EOS_RGN_LOADER / _XBDIAG / _BANK */
    BYTE                 bank;       /* target ef, BANK region only */
    const unsigned char* image;
    int                  len;
    DWORD                crc;        /* expected CRC (from .ver, or computed for local) */

    int                  state;
    int                  staged;     /* bytes streamed so far (progress) */
    BYTE                 last_status;/* engine status at the last step */
    int                  confirmed;  /* set by Update_Confirm */
    const char* msg;        /* short status line for the UI */
} UpdateJob;

/* Set up a job and ARM its region. image/len must stay valid until the job ends.
   For loader/xbdiag pass the expected CRC (from the .ver). For local files with
   no .ver, pass 0 and the engine computes it from the buffer. */
BOOL Update_BeginLoader(UpdateJob* j, const unsigned char* img, int len, DWORD crc);
BOOL Update_BeginBios(UpdateJob* j, int bankEf, const unsigned char* img, int len);
BOOL Update_BeginXbDiag(UpdateJob* j, const unsigned char* img, int len, DWORD crc);

/* Advance one step; returns the new state. Idempotent once terminal. */
int  Update_Pump(UpdateJob* j);

/* Called from UPD_CONFIRM on the user's YES / NO. */
void Update_Confirm(UpdateJob* j);
void Update_Cancel(UpdateJob* j);

/* Human-readable confirm prompt for the current region (names the consequence). */
const char* Update_ConfirmText(const UpdateJob* j);

/* 0..100 staging progress for a progress bar. */
int  Update_Progress(const UpdateJob* j);