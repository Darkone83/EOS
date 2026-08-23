#pragma once
// eos_status.h -- decoded, post-boot EOS maintenance status for the updater.
// Hardware/register values stay inside this module; the UI receives only states
// and user-facing text that make sense once the Xbox has already booted.

#include "eos_script.h"

typedef struct EosStatusSnapshot {
    int eosPresent;
    unsigned char verMaj, verMin, verPat;

    int flashState;          // EOS_STATUS_FLASH_*
    int descriptorValid;    // 1 dynamic descriptor, 0 default/legacy layout
    int protectionActive;   // -1 unavailable, 0 none, 1 normal system locks, 2 custom

    int activeBankIndex;     // bank table index, -1 when unknown
    unsigned char activeEf;

    int xbdiagPresent;
    EosScriptInfo script;

    int netLink;
    int netUp;
    int backupAvailable;
} EosStatusSnapshot;

enum {
    EOS_STATUS_FLASH_READY = 0,
    EOS_STATUS_FLASH_BUSY,
    EOS_STATUS_FLASH_ERROR,
    EOS_STATUS_FLASH_UNAVAILABLE
};

void Status_Refresh(EosStatusSnapshot* out);
const char* Status_FlashText(int state);
const char* Status_LayoutText(const EosStatusSnapshot* s);
const char* Status_NetworkText(const EosStatusSnapshot* s);
const char* Status_ProtectionText(const EosStatusSnapshot* s);