// eos_status.cpp -- decoded EOS maintenance state for the on-console updater.
#include <xtl.h>
#include "eos_status.h"
#include "eos_smbus.h"
#include "eos_descriptor.h"
#include "eos_bank.h"
#include "eos_backup.h"

void Status_Refresh(EosStatusSnapshot* out)
{
    EosStatusSnapshot s;
    EosLayout lay;
    BYTE lo = 0, hi = 0;

    ZeroMemory(&s, sizeof(s));
    s.protectionActive = -1;
    s.eosPresent = Smb_Present() ? 1 : 0;
    if (s.eosPresent)
        Smb_ReadVersion(&s.verMaj, &s.verMin, &s.verPat);

    s.descriptorValid = (s.eosPresent && Desc_Load(&lay) && lay.valid) ? 1 : 0;

    if (s.eosPresent && Smb_ReadReg(EOS_REG_LOCK_LO, &lo) && Smb_ReadReg(EOS_REG_LOCK_HI, &hi)) {
        unsigned int mask = (unsigned int)lo | ((unsigned int)hi << 8);
        if (mask == 0x0402u) s.protectionActive = 1;
        else if (mask == 0)  s.protectionActive = 0;
        else                 s.protectionActive = 2;
    }

    s.xbdiagPresent = Bank_XbDiagPresent() ? 1 : 0;
    if (s.eosPresent) Script_Refresh(&s.script);
    else { s.script.state = EOS_SCRIPT_UNAVAILABLE; s.script.present = 0; }
    s.backupAvailable = Backup_HasAny() ? 1 : 0;

    if (out) *out = s;
}

const char* Status_LayoutText(const EosStatusSnapshot* s)
{
    return (s && s->descriptorValid) ? "Dynamic Layout" : "Default Layout";
}

const char* Status_ProtectionText(const EosStatusSnapshot* s)
{
    if (!s || !s->eosPresent || s->protectionActive < 0) return "Unavailable";
    if (s->protectionActive == 1) return "System Banks Protected";
    if (s->protectionActive == 2) return "Custom Bank Locks Active";
    return "No Bank Locks";
}
