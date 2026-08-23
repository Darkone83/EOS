// eos_status.cpp -- decoded EOS maintenance state for the on-console updater.
#include <xtl.h>
#include "eos_status.h"
#include "eos_smbus.h"
#include "eos_flash.h"
#include "eos_descriptor.h"
#include "eos_bank.h"
#include "eos_backup.h"
#include "dd_net.h"

// Direct flash STATUS bits are intentionally private to this decoder. The user
// never sees the register value itself.
#define FLASH_ST_BUSY     0x01
#define FLASH_ST_REFUSED  0x04
#define FLASH_ST_RELOAD   0x08

void Status_Refresh(EosStatusSnapshot* out)
{
    EosStatusSnapshot s;
    EosLayout lay;
    BYTE lo = 0, hi = 0;
    unsigned char fst = 0xFF;
    int i;

    ZeroMemory(&s, sizeof(s));
    s.protectionActive = -1;
    s.activeBankIndex = -1;
    s.eosPresent = Smb_Present() ? 1 : 0;
    if (s.eosPresent)
        Smb_ReadVersion(&s.verMaj, &s.verMin, &s.verPat);

    // Decode the flash engine actually used by this updater. The older staged
    // update-engine flags are intentionally not surfaced here: this application
    // performs direct verified flash I/O, so stale staged-engine flags would be
    // misleading post-boot maintenance information.
    if (s.eosPresent) fst = Flash_RawStatus();
    if (!s.eosPresent || fst == 0xFF) s.flashState = EOS_STATUS_FLASH_UNAVAILABLE;
    else if (fst & FLASH_ST_REFUSED) s.flashState = EOS_STATUS_FLASH_ERROR;
    else if (fst & (FLASH_ST_BUSY | FLASH_ST_RELOAD)) s.flashState = EOS_STATUS_FLASH_BUSY;
    else s.flashState = EOS_STATUS_FLASH_READY;

    s.descriptorValid = (s.eosPresent && Desc_Load(&lay) && lay.valid) ? 1 : 0;

    if (s.eosPresent && Smb_ReadReg(EOS_REG_LOCK_LO, &lo) && Smb_ReadReg(EOS_REG_LOCK_HI, &hi)) {
        unsigned int mask = (unsigned int)lo | ((unsigned int)hi << 8);
        // 0x0402 is the normal EOS policy: Loader + Recovery protected. Keep the
        // raw mask private and expose only a maintenance-level interpretation.
        if (mask == 0x0402u) s.protectionActive = 1;
        else if (mask == 0)  s.protectionActive = 0;
        else                 s.protectionActive = 2;
    }

    if (s.eosPresent) {
        s.activeEf = Bank_ReadEf();
        for (i = 0; i < Bank_Count(); ++i) {
            if ((Bank_Ef(i) & 0x0F) == (s.activeEf & 0x0F)) { s.activeBankIndex = i; break; }
        }
    }

    s.xbdiagPresent = Bank_XbDiagPresent() ? 1 : 0;
    if (s.eosPresent) Script_Refresh(&s.script);
    else { s.script.state = EOS_SCRIPT_UNAVAILABLE; s.script.present = 0; }

    s.netLink = Net_LinkUp() ? 1 : 0;
    s.netUp = Net_IsUp() ? 1 : 0;
    s.backupAvailable = Backup_HasAny() ? 1 : 0;

    if (out) *out = s;
}

const char* Status_FlashText(int state)
{
    switch (state) {
    case EOS_STATUS_FLASH_READY:       return "Ready";
    case EOS_STATUS_FLASH_BUSY:        return "Busy";
    case EOS_STATUS_FLASH_ERROR:       return "Needs Attention";
    case EOS_STATUS_FLASH_UNAVAILABLE: return "Unavailable";
    default:                           return "Unknown";
    }
}

const char* Status_LayoutText(const EosStatusSnapshot* s)
{
    return (s && s->descriptorValid) ? "Dynamic Layout" : "Default Layout";
}

const char* Status_NetworkText(const EosStatusSnapshot* s)
{
    if (!s) return "Unknown";
    if (s->netUp) return "Connected";
    if (s->netLink) return "Waiting for Address";
    return "Disconnected";
}

const char* Status_ProtectionText(const EosStatusSnapshot* s)
{
    if (!s || !s->eosPresent || s->protectionActive < 0) return "Unavailable";
    if (s->protectionActive == 1) return "System Banks Protected";
    if (s->protectionActive == 2) return "Custom Bank Locks Active";
    return "No Bank Locks";
}