// eos_script.cpp -- EOS expansion-script maintenance.
// The framing, CRC, TARGET detection, MAGIC-last commit and runtime verification
// intentionally mirror Darkone83/EOS_Loader.
#include <xtl.h>
#include "eos_script.h"
#include "eos_file.h"
#include "eos_flash.h"
#include "eos_smbus.h"

#define EOS_EXP_REG_STATUS    0x40
#define EOS_EXP_REG_FAULT     0x41
#define EOS_EXP_ST_RUNNING    0x01
#define EOS_EXP_ST_FAULT      0x02
#define EOS_EXP_ST_VALID      0x04
#define EOS_EXP_ST_BOOT_GATE  0x08

static unsigned int script_crc32(const unsigned char* p, int n)
{
    unsigned int c = 0xFFFFFFFFu;
    int i, k;
    for (i = 0; i < n; ++i) {
        c ^= (unsigned int)p[i];
        for (k = 0; k < 8; ++k)
            c = (c >> 1) ^ (0xEDB88320u & (unsigned int)(0 - (int)(c & 1u)));
    }
    return c ^ 0xFFFFFFFFu;
}

static int has_eos_ext(const char* path)
{
    int n = 0;
    char a, b, c, d;
    if (!path) return 0;
    while (path[n]) ++n;
    if (n < 4) return 0;
    a = path[n - 4]; b = path[n - 3]; c = path[n - 2]; d = path[n - 1];
    if (a != '.') return 0;
    if (b >= 'A' && b <= 'Z') b = (char)(b + 32);
    if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
    if (d >= 'A' && d <= 'Z') d = (char)(d + 32);
    return (b == 'e' && c == 'o' && d == 's') ? 1 : 0;
}

static int program_no_erase(const unsigned char* data, int len)
{
    int pages, page, off, i, rc;
    unsigned char pg[256];
    pages = (len + 255) / 256;
    for (page = 0; page < pages; ++page) {
        off = page * 256;
        for (i = 0; i < 256; ++i)
            pg[i] = (off + i < len) ? data[off + i] : 0xFF;
        rc = Flash_ProgramPage(EOS_SCRIPT_BANK, page, pg);
        if (rc != EOS_FLASH_OK) return rc;
    }
    return EOS_FLASH_OK;
}

static int runtime_state(void)
{
    int i, sawRead = 0;
    BYTE st = 0, fault = 0;
    for (i = 0; i < 100; ++i) {
        if (Smb_ReadReg(EOS_EXP_REG_STATUS, &st)) {
            sawRead = 1;
            if (st & EOS_EXP_ST_FAULT) {
                Smb_ReadReg(EOS_EXP_REG_FAULT, &fault);
                (void)fault; // intentionally decoded to a user-level fault state
                return EOS_SCRIPT_FAULT;
            }
            if ((st & (EOS_EXP_ST_RUNNING | EOS_EXP_ST_VALID | EOS_EXP_ST_BOOT_GATE)) ==
                (EOS_EXP_ST_RUNNING | EOS_EXP_ST_VALID | EOS_EXP_ST_BOOT_GATE))
                return EOS_SCRIPT_RUNNING;
        }
        Sleep(10);
    }
    return sawRead ? EOS_SCRIPT_INSTALLED : EOS_SCRIPT_UNAVAILABLE;
}

int Script_Refresh(EosScriptInfo* out)
{
    unsigned char pg[256];
    int rc, state;
    EosScriptInfo info;

    info.state = EOS_SCRIPT_NONE;
    info.present = 0;
    info.targetHd = 0;
    info.textLen = 0;
    info.crc32 = 0;

    rc = Flash_ReadPage(EOS_SCRIPT_BANK, 0, pg);
    if (rc != EOS_FLASH_OK) {
        info.state = EOS_SCRIPT_UNAVAILABLE;
        if (out) *out = info;
        return info.state;
    }

    if (!(pg[0] == 'E' && pg[1] == 'O' && pg[2] == 'S' && pg[3] == 'X')) {
        if (out) *out = info;
        return info.state;
    }

    info.present = 1;
    if (pg[4] != 0x01) {
        info.state = EOS_SCRIPT_INVALID;
        if (out) *out = info;
        return info.state;
    }

    info.targetHd = pg[5] ? 1 : 0;
    info.textLen = (unsigned long)pg[8] |
        ((unsigned long)pg[9] << 8) |
        ((unsigned long)pg[10] << 16) |
        ((unsigned long)pg[11] << 24);
    info.crc32 = (unsigned long)pg[12] |
        ((unsigned long)pg[13] << 8) |
        ((unsigned long)pg[14] << 16) |
        ((unsigned long)pg[15] << 24);

    if (info.textLen == 0 || info.textLen > EOS_SCRIPT_MAXTXT) {
        info.state = EOS_SCRIPT_INVALID;
        if (out) *out = info;
        return info.state;
    }

    state = runtime_state();
    info.state = state;
    if (out) *out = info;
    return state;
}

int Script_Clear(void)
{
    EosScriptInfo info;
    if (Flash_EraseBank(EOS_SCRIPT_BANK) != EOS_FLASH_OK) return 0;
    if (Flash_Sync(EOS_SCRIPT_BANK) != EOS_FLASH_OK) return 0;
    Script_Refresh(&info);
    return info.present ? 0 : 1;
}

int Script_FlashFrom(const char* path, unsigned char* work, int workCap)
{
    int textLen, i, total, state;
    unsigned int crc;
    unsigned char tgt;
    unsigned char magicPage[256];
    EosScriptInfo info;

    if (!path || !work || workCap <= EOS_SCRIPT_FRAME) return EOS_SCRIPT_FLASH_BADFILE;
    if (!has_eos_ext(path)) return EOS_SCRIPT_FLASH_BADFILE;

    textLen = File_ReadInto(path, work + EOS_SCRIPT_FRAME, workCap - EOS_SCRIPT_FRAME);
    if (textLen <= 0 || textLen > EOS_SCRIPT_MAXTXT) return EOS_SCRIPT_FLASH_BADFILE;

    // Same TARGET parsing semantics as the Loader: default NOHD; TARGET HD -> HD.
    tgt = 0;
    for (i = EOS_SCRIPT_FRAME; i + 9 <= EOS_SCRIPT_FRAME + textLen; ++i) {
        if (work[i] == 'T' && work[i + 1] == 'A' && work[i + 2] == 'R' &&
            work[i + 3] == 'G' && work[i + 4] == 'E' && work[i + 5] == 'T' &&
            work[i + 6] == ' ') {
            int j = i + 7;
            while (j < EOS_SCRIPT_FRAME + textLen && work[j] == ' ') ++j;
            if (j + 1 < EOS_SCRIPT_FRAME + textLen && work[j] == 'H' && work[j + 1] == 'D')
                tgt = 1;
            break;
        }
    }

    crc = script_crc32(work + EOS_SCRIPT_FRAME, textLen);

    // Frame header. MAGIC stays erased until the final validity commit.
    work[0] = 0xFF; work[1] = 0xFF; work[2] = 0xFF; work[3] = 0xFF;
    work[4] = 0x01;
    work[5] = tgt;
    work[6] = 0x00;
    work[7] = 0x00;
    work[8] = (unsigned char)(textLen);
    work[9] = (unsigned char)(textLen >> 8);
    work[10] = (unsigned char)(textLen >> 16);
    work[11] = (unsigned char)(textLen >> 24);
    work[12] = (unsigned char)(crc);
    work[13] = (unsigned char)(crc >> 8);
    work[14] = (unsigned char)(crc >> 16);
    work[15] = (unsigned char)(crc >> 24);
    total = EOS_SCRIPT_FRAME + textLen;

    if (Flash_EraseBank(EOS_SCRIPT_BANK) != EOS_FLASH_OK) return EOS_SCRIPT_FLASH_ERASE_FAIL;
    if (program_no_erase(work, total) != EOS_FLASH_OK) return EOS_SCRIPT_FLASH_PROGRAM_FAIL;

    magicPage[0] = 'E'; magicPage[1] = 'O'; magicPage[2] = 'S'; magicPage[3] = 'X';
    for (i = 4; i < 256; ++i) magicPage[i] = 0xFF;
    if (Flash_ProgramPage(EOS_SCRIPT_BANK, 0, magicPage) != EOS_FLASH_OK)
        return EOS_SCRIPT_FLASH_MAGIC_FAIL;

    if (Flash_Sync(EOS_SCRIPT_BANK) != EOS_FLASH_OK) return EOS_SCRIPT_FLASH_SYNC_FAIL;

    state = Script_Refresh(&info);
    if (!info.present) return EOS_SCRIPT_FLASH_VERIFY_FAIL;
    if (state == EOS_SCRIPT_RUNNING) return EOS_SCRIPT_FLASH_OK;
    if (state == EOS_SCRIPT_FAULT) return EOS_SCRIPT_FLASH_ENGINE_FAULT;
    if (state == EOS_SCRIPT_UNAVAILABLE) return EOS_SCRIPT_FLASH_SMBUS_FAIL;
    if (state == EOS_SCRIPT_INVALID) return EOS_SCRIPT_FLASH_VERIFY_FAIL;
    return EOS_SCRIPT_FLASH_ENGINE_TIMEOUT;
}

const char* Script_StateText(int state)
{
    switch (state) {
    case EOS_SCRIPT_NONE:        return "Not Installed";
    case EOS_SCRIPT_RUNNING:     return "Installed & Running";
    case EOS_SCRIPT_INSTALLED:   return "Installed - Not Running";
    case EOS_SCRIPT_FAULT:       return "Runtime Error";
    case EOS_SCRIPT_INVALID:     return "Invalid Script";
    case EOS_SCRIPT_UNAVAILABLE: return "Status Unavailable";
    default:                     return "Unknown";
    }
}

const char* Script_FlashErrorText(int rc)
{
    switch (rc) {
    case EOS_SCRIPT_FLASH_OK:             return "Script installed and running.";
    case EOS_SCRIPT_FLASH_BADFILE:        return "Invalid or oversized .eos file.";
    case EOS_SCRIPT_FLASH_ERASE_FAIL:     return "Could not erase the script slot.";
    case EOS_SCRIPT_FLASH_PROGRAM_FAIL:   return "Script programming failed.";
    case EOS_SCRIPT_FLASH_MAGIC_FAIL:     return "Script commit marker failed.";
    case EOS_SCRIPT_FLASH_SYNC_FAIL:      return "Script sync failed.";
    case EOS_SCRIPT_FLASH_VERIFY_FAIL:    return "Script verification failed.";
    case EOS_SCRIPT_FLASH_ENGINE_TIMEOUT: return "Script installed but did not start.";
    case EOS_SCRIPT_FLASH_ENGINE_FAULT:   return "Script runtime reported an error.";
    case EOS_SCRIPT_FLASH_SMBUS_FAIL:     return "Could not read script runtime status.";
    default:                              return "Script operation failed.";
    }
}