// eos_config.cpp -- Eos loader config persistence, split into TWO independent
// flash regions so a settings write can never disturb the bank table:
//
//   bank 0xB  (phys 0x7F0000, its own 64K erase block)  -> BANK TABLE   "EOSB"
//   bank 0xC  (phys 0x7E0000, its own 64K erase block)  -> SETTINGS     "EOSS"
//
// Because each lives in a separate erase block, changing the theme only
// erases/programs 0xC and leaves the bank table in 0xB completely untouched
// (and vice-versa). The old combined "EOSC" page (banks + settings together in
// 0xB) is still READ for backward compatibility and its theme is migrated to
// 0xC on first save.
//
// RXDK / MSVC2003 / C89: declarations before statements, no CRT.
#include "eos_config.h"
#include "eos_bank.h"
#include "eos_flash.h"

#define CFG_RECSZ   28
#define CFG_HDR     8
#define CFG_SUM_OFF 254           /* 16-bit additive checksum over [0..253] */
#define CFG_THEME_MAX 31
#define CFG_VERIFY_FAIL (-2)

#define BANKS_VER   1
#define SET_VER     2
#define OLD_SET_OFF 240           /* theme offset in the legacy combined "EOSC" page */

static int s_themeIdx = 0;        /* cached setting, loaded by Config_Load */
static int s_bgmOn = 0;        /* background music enabled */
static char s_bgmPath[EOS_BGM_PATH_MAX] = { 0 };  /* selected track path */

int Config_GetThemeIdx(void) { return s_themeIdx; }

int         Config_GetBgmOn(void) { return s_bgmOn ? 1 : 0; }
const char* Config_GetBgmPath(void) { return s_bgmPath; }
void Config_SetBgmOn(int on) { s_bgmOn = on ? 1 : 0; Config_SaveSettings(); }
void Config_SetBgmPath(const char* path)
{
    int i = 0;
    if (path) for (; path[i] && i < EOS_BGM_PATH_MAX - 1; ++i) s_bgmPath[i] = path[i];
    s_bgmPath[i] = 0;
    Config_SaveSettings();
}

// --- shared helpers ----------------------------------------------------------
static void putSum(unsigned char* buf)
{
    unsigned sum = 0; int i;
    for (i = 0; i < CFG_SUM_OFF; ++i) sum += buf[i];
    buf[CFG_SUM_OFF + 0] = (unsigned char)(sum & 0xFF);
    buf[CFG_SUM_OFF + 1] = (unsigned char)((sum >> 8) & 0xFF);
}

static int sumOk(const unsigned char* buf)
{
    unsigned sum = 0, stored; int i;
    for (i = 0; i < CFG_SUM_OFF; ++i) sum += buf[i];
    stored = (unsigned)buf[CFG_SUM_OFF] | ((unsigned)buf[CFG_SUM_OFF + 1] << 8);
    return (sum & 0xFFFF) == stored;
}

// erase+program a single 256-byte page to a config bank, then read-back verify.
static int writePage(int bank, const unsigned char* buf)
{
    unsigned char rb[256];
    int rc, j;
    rc = Flash_EraseBank(bank);
    if (rc != EOS_FLASH_OK) return rc;
    rc = Flash_ProgramPage(bank, 0, buf);
    if (rc != EOS_FLASH_OK) return rc;
    rc = Flash_ReadPage(bank, 0, rb);
    if (rc != EOS_FLASH_OK) return rc;
    for (j = 0; j < 256; ++j) if (rb[j] != buf[j]) return CFG_VERIFY_FAIL;
    return EOS_FLASH_OK;
}

// ===========================================================================
// BANK TABLE  (bank 0xB, "EOSB")
// ===========================================================================
int Config_Save(void)
{
    unsigned char buf[256];
    const char* nm;
    int           n, i, k, off;

    for (i = 0; i < 256; ++i) buf[i] = 0;
    buf[0] = 'E'; buf[1] = 'O'; buf[2] = 'S'; buf[3] = 'B';
    buf[4] = BANKS_VER;

    n = Bank_Count();
    if (n > EOS_BANK_MAX) n = EOS_BANK_MAX;
    buf[5] = (unsigned char)n;

    for (i = 0; i < n; ++i) {
        off = CFG_HDR + i * CFG_RECSZ;
        buf[off + 0] = (unsigned char)Bank_Occupied(i);
        buf[off + 1] = Bank_Ef(i);
        buf[off + 2] = (unsigned char)Bank_SizeCode(i);
        buf[off + 3] = 0;
        nm = Bank_Name(i);
        for (k = 0; k < EOS_BANK_NAMELEN && nm[k]; ++k)
            buf[off + 4 + k] = (unsigned char)nm[k];
    }

    putSum(buf);
    return writePage(EOS_CONFIG_BANK, buf);
}

// Load bank table. Accepts the new "EOSB" page and the legacy combined "EOSC"
// page (whose theme byte is captured so the setting survives the migration).
static int loadBanks(void)
{
    unsigned char buf[256];
    char          nm[EOS_BANK_NAMELEN];
    int           rc, n, i, k, off, isOld;

    rc = Flash_ReadPage(EOS_CONFIG_BANK, 0, buf);
    if (rc != EOS_FLASH_OK) return -1;

    isOld = (buf[0] == 'E' && buf[1] == 'O' && buf[2] == 'S' && buf[3] == 'C');
    if (!isOld && !(buf[0] == 'E' && buf[1] == 'O' && buf[2] == 'S' && buf[3] == 'B')) return -1;
    if (buf[4] < 1) return -1;
    if (!sumOk(buf)) {
        // Legacy "EOSC" pages predate the checksum -- accept them anyway; new
        // "EOSB" pages always carry one, so a bad sum there means corruption.
        if (!isOld) return -1;
    }

    n = buf[5];
    if (n > Bank_Count()) n = Bank_Count();
    for (i = 0; i < n; ++i) {
        off = CFG_HDR + i * CFG_RECSZ;
        Bank_SetOccupied(i, buf[off + 0], buf[off + 2]);
        for (k = 0; k < EOS_BANK_NAMELEN - 1; ++k) nm[k] = (char)buf[off + 4 + k];
        nm[EOS_BANK_NAMELEN - 1] = 0;
        Bank_SetName(i, nm);
    }

    if (isOld) {                                   // migrate the old theme byte
        s_themeIdx = buf[OLD_SET_OFF];
        if (s_themeIdx < 0 || s_themeIdx > CFG_THEME_MAX) s_themeIdx = 0;
    }
    return 0;
}

// ===========================================================================
// SETTINGS  (bank 0xC, "EOSS")
// ===========================================================================
int Config_SaveSettings(void)
{
    unsigned char buf[256];
    int i;
    for (i = 0; i < 256; ++i) buf[i] = 0;
    buf[0] = 'E'; buf[1] = 'O'; buf[2] = 'S'; buf[3] = 'S';
    buf[4] = SET_VER;
    buf[5] = (unsigned char)s_themeIdx;
    buf[6] = (unsigned char)s_bgmOn;               /* background music on/off */
    {
        int i = 0;
        while (s_bgmPath[i] && i < EOS_BGM_PATH_MAX - 1) { buf[7 + i] = (unsigned char)s_bgmPath[i]; ++i; }
        buf[7 + i] = 0;                            /* NUL-terminated track path [7..253] */
    }
    putSum(buf);
    return writePage(EOS_SETTINGS_BANK, buf);
}

// Reset ONLY the user settings (theme, background track, ...) to defaults and
// persist to the settings bank (0xC). Unlike Config_ClearAll this leaves the
// bank table (0xB) untouched, so a settings reset never disturbs flashed BIOSes.
int Config_ResetSettings(void)
{
    s_themeIdx = 0;
    s_bgmOn = 0;
    s_bgmPath[0] = 0;
    return Config_SaveSettings();
}

// Erase BOTH config banks back to blank (bank table 0xB + settings 0xC) and
// reset the in-memory theme. Caller should also reset the in-memory bank table
// via Bank_ResetToFactory() so a later save can't write the stale table back.
int Config_ClearAll(void)
{
    int r1 = Flash_EraseBank(EOS_CONFIG_BANK);
    int r2 = Flash_EraseBank(EOS_SETTINGS_BANK);
    s_themeIdx = 0;
    return (r1 == EOS_FLASH_OK && r2 == EOS_FLASH_OK) ? EOS_FLASH_OK : -1;
}

// Load settings from 0xC. If absent (blank/new), keep whatever Config_LoadBanks
// migrated (legacy theme) or the default.
static void loadSettings(void)
{
    unsigned char buf[256];
    int rc;
    rc = Flash_ReadPage(EOS_SETTINGS_BANK, 0, buf);
    if (rc != EOS_FLASH_OK) return;
    if (!(buf[0] == 'E' && buf[1] == 'O' && buf[2] == 'S' && buf[3] == 'S')) return;
    if (buf[4] < 1 || !sumOk(buf)) return;
    s_themeIdx = buf[5];
    if (s_themeIdx < 0 || s_themeIdx > CFG_THEME_MAX) s_themeIdx = 0;
    if (buf[4] >= 2) {
        int i;
        s_bgmOn = buf[6] ? 1 : 0;
        for (i = 0; i < EOS_BGM_PATH_MAX - 1 && buf[7 + i]; ++i) s_bgmPath[i] = (char)buf[7 + i];
        s_bgmPath[i] = 0;
    }
}

void Config_SetThemeIdx(int idx)
{
    if (idx < 0) idx = 0;
    if (idx > CFG_THEME_MAX) idx = CFG_THEME_MAX;
    s_themeIdx = idx;
    Config_SaveSettings();         /* persists ONLY the settings block (bank 0xC) */
}

// ===========================================================================
// Boot entry: load both regions. Banks first (may migrate a legacy theme),
// then settings (overrides with the dedicated block if present).
// ===========================================================================
int Config_Load(void)
{
    int rc = loadBanks();
    loadSettings();
    return rc;
}