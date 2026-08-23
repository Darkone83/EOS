#pragma once
// eos_script.h -- EOS expansion-script maintenance for the on-console updater.
// Mirrors the EOS Loader's persistent script format/commit choreography while
// presenting decoded runtime states to the UI.

#define EOS_SCRIPT_BANK      0x09
#define EOS_SCRIPT_FRAME     16
#define EOS_SCRIPT_MAXTXT    0x1FFF0

enum EosScriptState {
    EOS_SCRIPT_NONE = 0,
    EOS_SCRIPT_RUNNING,
    EOS_SCRIPT_INSTALLED,
    EOS_SCRIPT_FAULT,
    EOS_SCRIPT_INVALID,
    EOS_SCRIPT_UNAVAILABLE
};

enum EosScriptFlashResult {
    EOS_SCRIPT_FLASH_OK = 1,
    EOS_SCRIPT_FLASH_BADFILE = -1,
    EOS_SCRIPT_FLASH_ERASE_FAIL = -2,
    EOS_SCRIPT_FLASH_PROGRAM_FAIL = -3,
    EOS_SCRIPT_FLASH_MAGIC_FAIL = -4,
    EOS_SCRIPT_FLASH_SYNC_FAIL = -5,
    EOS_SCRIPT_FLASH_VERIFY_FAIL = -6,
    EOS_SCRIPT_FLASH_ENGINE_TIMEOUT = -7,
    EOS_SCRIPT_FLASH_ENGINE_FAULT = -8,
    EOS_SCRIPT_FLASH_SMBUS_FAIL = -9
};

typedef struct EosScriptInfo {
    int state;                  // EosScriptState
    int present;                // committed EOSX frame exists
    int targetHd;               // frame target: 0=standard/NOHD, 1=HD
    unsigned long textLen;
    unsigned long crc32;
} EosScriptInfo;

// Refresh committed-frame + runtime state. Returns the decoded EosScriptState.
int Script_Refresh(EosScriptInfo* out);

// Flash a .eos text file using the Loader's exact frame format and commit order.
// work/workCap is caller-owned staging memory (>=128K recommended).
int Script_FlashFrom(const char* path, unsigned char* work, int workCap);

// Remove the committed script, sync the expansion scratch view, and verify gone.
int Script_Clear(void);

const char* Script_StateText(int state);
const char* Script_FlashErrorText(int rc);