// main.cpp -- Eos Updater. Xbox-side app that flashes the loader, a BIOS bank,
// or XbDiag-lite onto the Eos board via the staged/validated/committed datapath.
//
// Three flows, source-per-risk:
//   Flash Loader  -> Internet (force-update) OR local file
//   Flash BIOS    -> local files only (browse + pick target bank)
//   Update XbDiag -> Internet only (version-gated: current = no update)
//
// Every flash write is confirmed at the scratch->flash boundary (Update_Confirm).
// Themed via g_theme so it matches the user's loader colours.
#include <xtl.h>
#include "eos_gfx.h"
#include "eos_font.h"
#include "eos_ui.h"
#include "eos_splash.h"
#include "eos_theme.h"
#include "eos_config.h"
#include "eos_bank.h"
#include "eos_descriptor.h"
#include "eos_led.h"
#include "eos_flash.h"
#include "input.h"
#include "eos_file.h"
#include "dd_net.h"
#include "eos_net.h"
#include "eos_update.h"
#include "eos_smbus.h"
#include "eos_crc.h"
#include "eos_osk.h"
#include "eos_backup.h"
#include "eos_script.h"
#include "eos_status.h"
#include "dd_mount.h"
#include "xboxinternals.h"

#define IMG_CAP   (2 * 1024 * 1024)     /* max image: a 2MB Xenium BIOS */
#define VER_CAP   512
#define WORK_CAP  (1024 * 1024)

/* ---- phases --------------------------------------------------------------- */
enum {
    PH_SPLASH = 0,
    PH_MENU,
    PH_STATUS,
    PH_STATUS_FETCH,
    PH_LOADER_SRC,
    PH_BROWSE,
    PH_BANKMGMT,
    PH_RENAME,
    PH_MGMT_CONFIRM,
    PH_NET_FETCH,
    PH_STAGE,
    PH_CONFIRM,
    PH_WRITING,
    PH_RESULT,
    PH_UTILITIES,
    PH_UTIL_BANKPICK,
    PH_LEDCOLOR,
    PH_SCRIPTS,
    PH_SCRIPT_CONFIRM,
    PH_SCRIPT_WORK,
    PH_LOADER_WARN,
    PH_LOADER_BACKUP_PROMPT,
    PH_LOADER_BACKINGUP,
    PH_LOADER_RESTORE_PROMPT,
    PH_LOADER_RESTORING,
    PH_LOADER_FACTORY_WARN,
    PH_LOADER_FACTORY
};

/* what the pending net fetch is for */
enum { FETCH_LOADER = 0, FETCH_XBDIAG, FETCH_STATUS };
enum { BROWSE_LOADER = 0, BROWSE_BIOS_FLASH, BROWSE_BIOS_RESTORE, BROWSE_SCRIPT };

/* ---- state ---------------------------------------------------------------- */
static int        s_phase = PH_SPLASH;
static int        s_splashT = 0;
static WORD       s_prev = 0;

static unsigned char* s_img = 0;        /* update/BIOS image buffer (2MB) */
static unsigned char* s_work = 0;       /* backup/script work buffer (1MB) */
static int        s_imgLen = 0;
static char       s_verbuf[VER_CAP];

static UpdateJob  s_job;
static int        s_menuSel = 0;
static int        s_srcSel = 0;
static int        s_fetchWhat = FETCH_LOADER;
static const char* s_resultMsg = "";
static char       s_eosVer[24] = "";
static EosVer     s_pendingVer;      /* version to stamp into the XbDiag bank name on success */

/* file browser */
static char           s_cwd[256];
static EosFileEntry   s_entries[EOS_FILE_MAX_ENTRIES];
static int            s_entryCount = 0;
static int            s_browseSel = 0;
static char           s_pickedFile[300];
static int            s_browseMode = BROWSE_LOADER;

/* bank management */
static int        s_bankSel = 0;
static int        s_flashTarget = -1;
static int        s_writePrimed = 0;   /* PH_WRITING: 0=render frame, 1=do write */
static int        s_renameTarget = -1;
enum {
    ACT_NONE = 0, ACT_DELETE, ACT_MGMT_FLASH,
    ACT_CLEAR_XBDIAG, ACT_CLEAR_SETTINGS, ACT_CLEAR_NAMES
};
static int        s_utilSel = 0;    /* selected row in the Utilities menu */
static int        s_utilBankSel = 0;/* selected bank in the backup/restore picker */
static int        s_utilMode = 0;   /* 0 = backup, 1 = restore (for the bank picker) */
static int        s_pendAct = ACT_NONE;
static int        s_pendIdx = -1;
static char       s_confirmMsg[80];
static char       s_statusMsg[96];
static DWORD      s_statusUntil = 0;

static EosBankFlashPlan s_flashPlan;
static int        s_flashIsRestore = 0;
static char       s_flashLeaf[EOS_BANK_NAMELEN + 32];

static EosStatusSnapshot s_status;
static EosLayout  s_uiLayout;
static int        s_uiLayoutValid = 0;
static int        s_serverChecked = 0;
static int        s_serverOnline = 0;
static EosVer     s_serverXbdVer;
static int        s_serverXbdKnown = 0;

static EosScriptInfo s_scriptInfo;
static int        s_scriptOp = 0;       /* 1 install/replace, 2 remove */
static int        s_scriptPrimed = 0;

static EosBackupSet s_loaderBackup;
static int        s_loaderHasBackup = 0;
static int        s_loaderOpPrimed = 0;
static int        s_resultReboot = 0;
static int        s_resultHardReboot = 0;
static char       s_resultBuf[160];

static const char* k_menu[6] = {
    "EOS Status", "Bank Management", "EOS Scripts",
    "Update Loader", "Update XbDiag Lite", "Utilities"
};

/* ---- helpers -------------------------------------------------------------- */
static int Pressed(WORD now, WORD prev, WORD mask) { return (now & mask) && !(prev & mask); }

static void CopyStr(char* d, int cap, const char* s)
{
    int i = 0;
    if (cap <= 0) return;
    while (s[i] && i < cap - 1) { d[i] = s[i]; ++i; }
    d[i] = 0;
}

static int StrLen(const char* s) { int n = 0; while (s[n]) ++n; return n; }

static void JoinPath(char* d, int cap, const char* base, const char* leaf)
{
    int at = 0, i = 0;
    while (base[i] && at < cap - 1) d[at++] = base[i++];
    if (at > 0 && d[at - 1] != '\\' && at < cap - 1) d[at++] = '\\';
    i = 0;
    while (leaf[i] && at < cap - 1) d[at++] = leaf[i++];
    d[at] = 0;
}

static int appendStr(char* out, int p, const char* s)
{
    int i = 0; while (s[i] && p < 62) out[p++] = s[i++]; out[p] = 0; return p;
}

static const char* sizeStr(int code)
{
    if (code == EOS_BANK_SIZE_512K) return "512K"; if (code == EOS_BANK_SIZE_1MB) return "1MB"; return "256K";
}

/* Map a bank-table index to descriptor slot 0..3; non-user banks return -1. */
static int descSlotForBank(int idx)
{
    unsigned char ef = Bank_Ef(idx);
    if (ef >= 0x3 && ef <= 0x6) return (int)(ef - 0x3);
    return -1;
}

/* Native BIOS maintenance uses the Loader full-image window (bank E) as a
   descriptor-independent physical access path. The flash control plane's dynamic
   slot numbering is not the same as the serve path's EF 0x3..0x6 numbering, so
   using EF directly becomes ambiguous once a descriptor is valid. */
#define NATIVE_PHYS_BANK  0x0E
#define NATIVE_SLOT_PAGES 1024    /* 256K / 256 */

static int NativeStartPage(int slot)
{
    if (slot < 0 || slot >= 4) return -1;
    return slot * NATIVE_SLOT_PAGES;
}

static int VerifyNativeImage(int slot, const unsigned char* data, int len)
{
    unsigned char rb[256];
    int startPage, pages, pg, off, i;
    startPage = NativeStartPage(slot);
    if (startPage < 0 || !data || len <= 0 || len > 256 * 1024) return 0;
    pages = (len + 255) / 256;
    for (pg = 0; pg < pages; ++pg) {
        off = pg * 256;
        if (Flash_ReadPage(NATIVE_PHYS_BANK, startPage + pg, rb) != EOS_FLASH_OK) return 0;
        for (i = 0; i < 256; ++i) {
            unsigned char want = (off + i < len) ? data[off + i] : 0xFF;
            if (rb[i] != want) return 0;
        }
    }
    return 1;
}

static int WriteNativeImage(int slot, const unsigned char* data, int len)
{
    int startPage, rc;
    startPage = NativeStartPage(slot);
    if (startPage < 0) return EOS_FLASH_REFUSED;
    rc = Flash_WriteImageAtNoSync(NATIVE_PHYS_BANK, startPage, data, len);
    if (rc != EOS_FLASH_OK) return rc;
    if (!VerifyNativeImage(slot, data, len)) return EOS_FLASH_VERIFY;
    return Flash_Sync(NATIVE_PHYS_BANK);
}

static int EraseNativeImage(int slot)
{
    int firstBlock, i, rc;
    if (slot < 0 || slot >= 4) return EOS_FLASH_REFUSED;
    firstBlock = slot * 4;              /* four 64K blocks per native 256K slot */
    for (i = 0; i < 4; ++i) {
        rc = Flash_EraseBlock(NATIVE_PHYS_BANK, firstBlock + i);
        if (rc != EOS_FLASH_OK) return rc;
    }
    return Flash_Sync(NATIVE_PHYS_BANK);
}

static void fileToBankName(char* nm, int cap, const char* leaf)
{
    int i = 0, dot = -1; while (leaf[i] && i < cap - 1) { if (leaf[i] == '.') dot = i; nm[i] = leaf[i]; ++i; } if (dot > 0) i = dot; nm[i] = 0;
}

static void RefreshUiLayout(void)
{
    int i;
    if (!Smb_Present()) { Desc_InitEmpty(&s_uiLayout); s_uiLayoutValid = 0; return; }
    s_uiLayoutValid = (Desc_Load(&s_uiLayout) && s_uiLayout.valid) ? 1 : 0;
    if (!s_uiLayoutValid) Desc_InitEmpty(&s_uiLayout);

    // Display-only reconciliation: show legacy/static occupied banks accurately
    // without writing anything merely because a screen was opened.
    for (i = 0; i < Bank_Count(); ++i) {
        unsigned char ef = Bank_Ef(i);
        int slot;
        if (ef < 0x3 || ef > 0x6) continue;
        slot = (int)(ef - 0x3);
        if (s_uiLayout.slot[slot].state == EOS_SLOT_NATIVE ||
            (Bank_Occupied(i) && s_uiLayout.slot[slot].state == EOS_SLOT_FREE)) {
            s_uiLayout.slot[slot].state = EOS_SLOT_NATIVE;
            s_uiLayout.slot[slot].sizeCode = EOS_SZC_256K;
            s_uiLayout.slot[slot].physBase = (unsigned int)(slot * 0x040000);
        }
    }
}

static const char* LedNameForColor(unsigned int c)
{
    int i;
    c &= 0xFFFFFFu;
    for (i = 0; i < EOS_LED_PALETTE_N; ++i)
        if ((Eos_LedPalette[i] & 0xFFFFFFu) == c) return Eos_LedPaletteName[i];
    return "Custom";
}

static const char* LedNameForBank(int idx)
{
    int slot = descSlotForBank(idx);
    if (slot < 0) return "Off";
    return LedNameForColor(s_uiLayout.color[slot]);
}

static void buildMgmtRow(char* out, int idx)
{
    int p = 0; out[0] = 0;
    p = appendStr(out, p, Bank_Name(idx)); p = appendStr(out, p, "   ");
    if (Bank_IsBoot(idx)) { p = appendStr(out, p, "[BOOT]"); return; }
    if (Bank_IsLocked(idx)) { p = appendStr(out, p, "[LOCKED]"); return; }

    /* Descriptor-aware from the cached layout: ext anchors show true size and
       shadows are visibly consumed, with no per-frame flash reads. */
    {
        int dslot = descSlotForBank(idx);
        if (dslot >= 0) {
            int st = s_uiLayout.slot[dslot].state;
            if (st == EOS_SLOT_SHADOW) { p = appendStr(out, p, "[-- USED --]"); return; }
            if (st == EOS_SLOT_ANCHOR) {
                p = appendStr(out, p, "[");
                p = appendStr(out, p, sizeStr((s_uiLayout.slot[dslot].sizeCode == EOS_SZC_1MB) ? EOS_BANK_SIZE_1MB : EOS_BANK_SIZE_512K));
                p = appendStr(out, p, " READY]");
                p = appendStr(out, p, " LED:"); p = appendStr(out, p, LedNameForBank(idx));
                return;
            }
        }
    }

    if (Bank_Occupied(idx)) {
        p = appendStr(out, p, "["); p = appendStr(out, p, sizeStr(Bank_SizeCode(idx))); p = appendStr(out, p, " READY]");
        if (descSlotForBank(idx) >= 0) { p = appendStr(out, p, " LED:"); p = appendStr(out, p, LedNameForBank(idx)); }
    }
    else {
        p = appendStr(out, p, "[EMPTY]");
        if (descSlotForBank(idx) >= 0) { p = appendStr(out, p, " LED:"); p = appendStr(out, p, LedNameForBank(idx)); }
    }
}

static void SetMgmtStatus(const char* msg)
{
    int i = 0; while (msg[i] && i < 63) { s_statusMsg[i] = msg[i]; ++i; } s_statusMsg[i] = 0; s_statusUntil = GetTickCount() + 1500;
}

static void GotoPhase(int p) { s_phase = p; }

static void SetResult(const char* msg, int canReboot)
{
    CopyStr(s_resultBuf, sizeof(s_resultBuf), msg ? msg : "");
    s_resultMsg = s_resultBuf;
    s_resultReboot = canReboot;
    s_resultHardReboot = 0;
    GotoPhase(PH_RESULT);
}

static void SetResultHardReboot(const char* msg)
{
    CopyStr(s_resultBuf, sizeof(s_resultBuf), msg ? msg : "");
    s_resultMsg = s_resultBuf;
    s_resultReboot = 1;
    s_resultHardReboot = 1;
    GotoPhase(PH_RESULT);
}

static const char* BaseName(const char* path)
{
    const char* p = path;
    const char* last = path;
    if (!path) return "";
    while (*p) { if (*p == '\\') last = p + 1; ++p; }
    return last;
}

static void RefreshStatus(void)
{
    Status_Refresh(&s_status);
    s_scriptInfo = s_status.script;
    RefreshUiLayout();
}

static void appendSmallInt(char* out, int cap, int v)
{
    char tmp[12]; int n = 0, at = StrLen(out);
    if (v == 0) tmp[n++] = '0';
    else while (v > 0 && n < 11) { tmp[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n > 0 && at < cap - 1) out[at++] = tmp[--n];
    out[at] = 0;
}

static void BuildVersionText(char* out, int cap, BYTE a, BYTE b, BYTE c)
{
    out[0] = 0; appendSmallInt(out, cap, a); if (StrLen(out) < cap - 1) out[StrLen(out)] = 0;
    { int n = StrLen(out); if (n < cap - 1) { out[n++] = '.'; out[n] = 0; } }
    appendSmallInt(out, cap, b);
    { int n = StrLen(out); if (n < cap - 1) { out[n++] = '.'; out[n] = 0; } }
    appendSmallInt(out, cap, c);
}

/* On a successful XbDiag flash, record the new version in the bank name so the
   next "installed?" check reads it back. Name e.g. "XbDiag Lite 1.0.4". */
static void StampXbDiag(void)
{
    int  n = Bank_Count(), i, at = 0, k = 0;
    char nm[EOS_BANK_NAMELEN + 8];
    char vs[16];
    const char* pfx = "XbDiag Lite ";
    while (*pfx && at < (int)sizeof(nm) - 1) nm[at++] = *pfx++;
    Ver_Format(s_pendingVer, vs, sizeof(vs));
    while (vs[k] && at < (int)sizeof(nm) - 1) nm[at++] = vs[k++];
    nm[at] = 0;
    for (i = 0; i < n; ++i) {
        if ((Bank_Ef(i) & 0x0F) == 0x0D) { Bank_SetName(i, nm); Bank_SetOccupied(i, 1, EOS_BANK_SIZE_256K); Config_Save(); break; }
    }
}

/* refresh the browser listing for the current cwd (empty cwd = drive list) */
static void Browse_Refresh(void)
{
    if (s_cwd[0] == 0) s_entryCount = File_ListDrives(s_entries, EOS_FILE_MAX_ENTRIES);
    else               s_entryCount = File_ListDir(s_cwd, s_entries, EOS_FILE_MAX_ENTRIES);
    if (s_browseSel >= s_entryCount) s_browseSel = (s_entryCount > 0) ? s_entryCount - 1 : 0;
    if (s_browseSel < 0) s_browseSel = 0;
}

/* draw a simple vertical list of pills; returns nothing (caller owns selection) */
static void DrawList(const char* title, const char* items[], int count, int sel,
    const char* footer)
{
    int i, y = 150, rowH = 40, gap = 8, x = 80, w;
    w = g_scrW - 160;
    Ui_TitleBar(title);
    for (i = 0; i < count && i < 9; ++i) {
        Ui_PillLeft(x, y, w, rowH, rowH / 2, (i == sel), items[i]);
        y += rowH + gap;
    }
    Ui_Footer(footer);
}

/* ---- boot ----------------------------------------------------------------- */
static void Boot(void)
{
    Gfx_Init();
    Font_Init();            /* build the glyph atlas texture (needs g_dev) */
    InitInput();
    Config_Load();          /* bank table + settings from the config bank */
    Theme_Init();           /* apply the saved theme (recolours everything) */
    Net_Start();            /* bring the network up; resolves over next frames */
    /* read Eos firmware version from the chip (SMBus regs 0x01-0x03).
       Use Smb_ReadVersion so ALL THREE reads must succeed together -- a
       partial read (one register lost to bus contention) must NOT format a
       garbage version. On any failure we leave s_eosVer empty and simply
       don't show a version, rather than displaying a wrong one. */
    {
        BYTE mj = 0, mn = 0, pt = 0;
        if (Smb_ReadVersion(&mj, &mn, &pt)) {
            char* vp = s_eosVer;
            const char* pfx = "Eos "; while (*pfx) *vp++ = *pfx++;
            if (mj / 10) *vp++ = (char)('0' + mj / 10); *vp++ = (char)('0' + mj % 10); *vp++ = '.';
            if (mn / 10) *vp++ = (char)('0' + mn / 10); *vp++ = (char)('0' + mn % 10); *vp++ = '.';
            if (pt / 10) *vp++ = (char)('0' + pt / 10); *vp++ = (char)('0' + pt % 10); *vp = 0;
        }
        else {
            s_eosVer[0] = 0;   /* unknown -> show nothing */
        }
    }
    Splash_Init();
    Mount_SelfToD();       /* make D:\ resolve to the updater's own folder */
    File_MountDrives();
    s_img = (unsigned char*)MmAllocateContiguousMemory(IMG_CAP);
    s_work = (unsigned char*)MmAllocateContiguousMemory(WORK_CAP);
    s_cwd[0] = 0;
    ZeroMemory(&s_loaderBackup, sizeof(s_loaderBackup));
    if (!s_img || !s_work) {
        SetResult("Unable to allocate EOS maintenance buffers.", 0);
        return;
    }
    RefreshStatus();
    Smb_SetLedMode(1);      /* rainbow LED while the updater is running */
}

/* ---- source loading ------------------------------------------------------- */
/* local file -> s_img; returns bytes or -1 */
static int LoadLocal(const char* path)
{
    int n = File_ReadInto(path, s_img, IMG_CAP);
    return n;
}

/* blocking download of leaf -> s_img; returns NET_* code, sets s_imgLen */
static int FetchImage(const char* leaf)
{
    int len = 0;
    int rc = Net_HttpGet(leaf, s_img, IMG_CAP, &len);
    if (rc == NET_OK) s_imgLen = len;
    return rc;
}

/* download+parse a .ver into ver/crc; returns NET_* code */
static int FetchVer(const char* leaf, EosVer* ver, DWORD* crc)
{
    int len = 0;
    int rc = Net_HttpGet(leaf, (unsigned char*)s_verbuf, VER_CAP - 1, &len);
    if (rc != NET_OK) return rc;
    s_verbuf[(len < VER_CAP) ? len : VER_CAP - 1] = 0;
    Ver_Parse(s_verbuf, len, ver, crc);
    return NET_OK;
}

/* ---- the pending network operation (run after its screen is drawn) -------- */
static void RunNetFetch(void)
{
    EosVer sv, iv;
    DWORD crc = 0;
    int rc;

    if (s_fetchWhat == FETCH_STATUS) {
        s_serverChecked = 1;
        s_serverOnline = 0;
        s_serverXbdKnown = 0;
        rc = FetchVer("loader.ver", &sv, &crc);
        if (rc == NET_OK) s_serverOnline = 1;
        rc = FetchVer("xbdlite.ver", &s_serverXbdVer, &crc);
        if (rc == NET_OK) { s_serverOnline = 1; s_serverXbdKnown = 1; }
        RefreshStatus();
        GotoPhase(PH_STATUS);
        return;
    }

    if (s_fetchWhat == FETCH_LOADER) {
        /* force-update: .ver is used for CRC identity; the Loader is updated on
           explicit request rather than version-gated. */
        FetchVer("loader.ver", &sv, &crc);
        rc = FetchImage("loader.bin");
        if (rc != NET_OK) { SetResult(Net_ErrStr(rc), 0); return; }
        if (!Update_BeginLoader(&s_job, s_img, s_imgLen, crc)) { SetResult(s_job.msg, 0); return; }
        GotoPhase(PH_STAGE);
        return;
    }

    /* FETCH_XBDIAG: version gate first */
    rc = FetchVer("xbdlite.ver", &sv, &crc);
    if (rc != NET_OK) { SetResult(Net_ErrStr(rc), 0); return; }
    s_pendingVer = sv;
    if (Update_XbDiagInstalled(&iv) && Ver_Compare(sv, iv) <= 0) {
        SetResult("XbDiag Lite is already current.", 0);
        return;
    }
    rc = FetchImage("xbdlite.bin");
    if (rc != NET_OK) { SetResult(Net_ErrStr(rc), 0); return; }
    if (!Update_BeginXbDiag(&s_job, s_img, s_imgLen, crc)) { SetResult(s_job.msg, 0); return; }
    GotoPhase(PH_STAGE);
}

/* ---- per-phase update ----------------------------------------------------- */
static void Ph_Menu(WORD b)
{
    if (Pressed(b, s_prev, BTN_DPAD_UP))   s_menuSel = (s_menuSel + 5) % 6;
    if (Pressed(b, s_prev, BTN_DPAD_DOWN)) s_menuSel = (s_menuSel + 1) % 6;
    if (Pressed(b, s_prev, BTN_B)) { Smb_SetLedMode(0); XLaunchNewImage(NULL, NULL); return; }
    if (Pressed(b, s_prev, BTN_A)) {
        if (s_menuSel != 0 && !Smb_Present()) {
            SetResult("EOS hardware was not detected. Maintenance actions are disabled.", 0);
            return;
        }
        if (s_menuSel == 0) { RefreshStatus(); GotoPhase(PH_STATUS); }
        else if (s_menuSel == 1) { s_bankSel = 0; RefreshUiLayout(); GotoPhase(PH_BANKMGMT); }
        else if (s_menuSel == 2) { Script_Refresh(&s_scriptInfo); GotoPhase(PH_SCRIPTS); }
        else if (s_menuSel == 3) { s_srcSel = 0; GotoPhase(PH_LOADER_SRC); }
        else if (s_menuSel == 4) {
            if (!Net_IsUp()) { SetResult("Network is not ready for the XbDiag update.", 0); return; }
            s_fetchWhat = FETCH_XBDIAG; GotoPhase(PH_NET_FETCH);
        }
        else { s_utilSel = 0; GotoPhase(PH_UTILITIES); }
    }
}

static void Ph_Status(WORD b)
{
    if (Pressed(b, s_prev, BTN_B)) { GotoPhase(PH_MENU); return; }
    if (Pressed(b, s_prev, BTN_Y)) {
        if (!Net_IsUp()) { SetMgmtStatus("Network is not ready"); return; }
        s_fetchWhat = FETCH_STATUS;
        GotoPhase(PH_STATUS_FETCH);
        return;
    }
    if (Pressed(b, s_prev, BTN_A)) RefreshStatus();
}

static void Ph_Scripts(WORD b)
{
    if (Pressed(b, s_prev, BTN_B)) { GotoPhase(PH_MENU); return; }
    if (Pressed(b, s_prev, BTN_A)) {
        s_cwd[0] = 0; s_browseSel = 0; s_browseMode = BROWSE_SCRIPT;
        Browse_Refresh(); GotoPhase(PH_BROWSE); return;
    }
    if (Pressed(b, s_prev, BTN_X)) {
        if (!s_scriptInfo.present) { SetMgmtStatus("No script is installed"); return; }
        s_scriptOp = 2; s_scriptPrimed = 0; GotoPhase(PH_SCRIPT_CONFIRM); return;
    }
    if (Pressed(b, s_prev, BTN_Y)) {
        Script_Refresh(&s_scriptInfo);
    }
}

static void Ph_ScriptConfirm(WORD b)
{
    if (Pressed(b, s_prev, BTN_B)) { s_scriptOp = 0; GotoPhase(PH_SCRIPTS); return; }
    if (Pressed(b, s_prev, BTN_A)) { s_scriptPrimed = 0; GotoPhase(PH_SCRIPT_WORK); }
}

static void Ph_ScriptWork(WORD b)
{
    int rc;
    (void)b;
    if (!s_scriptPrimed) { s_scriptPrimed = 1; return; }
    if (s_scriptOp == 2) {
        if (Script_Clear()) CopyStr(s_statusMsg, sizeof(s_statusMsg), "EOS Script removed");
        else CopyStr(s_statusMsg, sizeof(s_statusMsg), "Script removal failed");
    }
    else {
        rc = Script_FlashFrom(s_pickedFile, s_work, WORK_CAP);
        CopyStr(s_statusMsg, sizeof(s_statusMsg), Script_FlashErrorText(rc));
    }
    s_statusUntil = GetTickCount() + 3500;
    Script_Refresh(&s_scriptInfo);
    s_scriptOp = 0; s_scriptPrimed = 0;
    GotoPhase(PH_SCRIPTS);
}

static void Ph_LoaderSrc(WORD b)
{
    if (Pressed(b, s_prev, BTN_DPAD_UP) || Pressed(b, s_prev, BTN_DPAD_DOWN)) s_srcSel ^= 1;
    if (Pressed(b, s_prev, BTN_B)) { GotoPhase(PH_MENU); return; }
    if (Pressed(b, s_prev, BTN_A)) {
        if (s_srcSel == 0) {
            if (!Net_IsUp()) { SetResult("Network is not ready for an Internet Loader update.", 0); return; }
            s_fetchWhat = FETCH_LOADER; GotoPhase(PH_NET_FETCH);
        }
        else { s_cwd[0] = 0; s_browseSel = 0; s_browseMode = BROWSE_LOADER; Browse_Refresh(); GotoPhase(PH_BROWSE); }
    }
}

static void DoMgmtFlash(int idx);
static void DoMgmtDelete(int idx);

/* Paint one full frame with a progress bar. Called from the flash progress
   callback so a long write shows visible motion instead of a frozen screen. */
static const char* s_progTitle = "Updating";
static void drawProgressFrame(const char* title, int done, int total)
{
    int bx, bw, bh, by, fillw;
    int pct = (total > 0) ? (int)(((long)done * 100) / total) : 0;
    char msg[32]; int mp = 0;

    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;

    bw = (g_scrW * 3) / 5; bh = 28;
    bx = (g_scrW - bw) / 2; by = g_scrH / 2 + 10;
    fillw = (bw * pct) / 100;

    Gfx_Begin(EOS_BG);
    Ui_Backdrop();
    Ui_TitleBar(title);
    Font_DrawCentered(0, g_scrW, by - 70, "Writing flash - do NOT power off...", EOS_WHITE);

    Gfx_FillRounded(bx - 2, by - 2, bw + 4, bh + 4, 8, EOS_DIM);        /* track */
    if (fillw > 0) Gfx_FillRounded(bx, by, fillw, bh, 6, EOS_PURPLE);   /* fill  */

    mp = 0;
    if (pct >= 100) { msg[mp++] = '1'; msg[mp++] = '0'; msg[mp++] = '0'; }
    else { if (pct >= 10) msg[mp++] = (char)('0' + pct / 10); msg[mp++] = (char)('0' + pct % 10); }
    msg[mp++] = '%'; msg[mp] = 0;
    Font_DrawCentered(0, g_scrW, by + bh + 16, msg, EOS_PURPLE);

    Gfx_End();
}

static void flashProgress(int done, int total) { drawProgressFrame(s_progTitle, done, total); }

static int PlanPickedBios(int idx, int isRestore)
{
    int rc, n, st;
    const char* leaf;
    if (idx < 0 || Bank_IsLocked(idx)) { SetMgmtStatus("Protected bank"); return 0; }

    s_imgLen = LoadLocal(s_pickedFile);
    if (s_imgLen <= 0) { SetMgmtStatus("Could not read BIOS image"); return 0; }
    if (s_imgLen > 1024 * 1024) { SetMgmtStatus("BIOS image exceeds 1MB"); return 0; }

    rc = Update_PlanBankFlash(idx, s_imgLen, &s_flashPlan);
    if (rc == EOS_BANKPLAN_USED_BY_LARGE) { SetMgmtStatus("Selected slot belongs to a large BIOS"); return 0; }
    if (rc == EOS_BANKPLAN_NOROOM) { SetMgmtStatus("No free slot for this BIOS size"); return 0; }
    if (rc != EOS_BANKPLAN_OK) { SetMgmtStatus("Invalid BIOS target"); return 0; }

    n = StrLen(s_pickedFile); st = n;
    while (st > 0 && s_pickedFile[st - 1] != '\\') --st;
    leaf = s_pickedFile + st;
    CopyStr(s_flashLeaf, sizeof(s_flashLeaf), leaf);
    s_flashIsRestore = isRestore;
    s_pendAct = ACT_MGMT_FLASH;
    s_pendIdx = idx;
    GotoPhase(PH_MGMT_CONFIRM);
    return 1;
}

static void Ph_Browse(WORD b)
{
    int backPhase;
    if (Pressed(b, s_prev, BTN_DPAD_UP))   s_browseSel = (s_browseSel + s_entryCount - 1) % (s_entryCount > 0 ? s_entryCount : 1);
    if (Pressed(b, s_prev, BTN_DPAD_DOWN)) s_browseSel = (s_browseSel + 1) % (s_entryCount > 0 ? s_entryCount : 1);

    backPhase = (s_browseMode == BROWSE_LOADER) ? PH_LOADER_SRC :
        (s_browseMode == BROWSE_BIOS_RESTORE) ? PH_UTIL_BANKPICK :
        (s_browseMode == BROWSE_SCRIPT) ? PH_SCRIPTS : PH_BANKMGMT;

    if (Pressed(b, s_prev, BTN_B)) {
        if (s_cwd[0] == 0) { GotoPhase(backPhase); return; }
        {
            int n = StrLen(s_cwd), i;
            for (i = n - 1; i >= 0; --i) {
                if (s_cwd[i] == '\\') { s_cwd[i] = 0; break; }
                if (i == 0) s_cwd[0] = 0;
            }
        }
        s_browseSel = 0; Browse_Refresh();
        return;
    }

    if (Pressed(b, s_prev, BTN_A) && s_entryCount > 0) {
        EosFileEntry* e = &s_entries[s_browseSel];
        char next[256];
        if (s_cwd[0] == 0) CopyStr(next, sizeof(next), e->name);
        else               JoinPath(next, sizeof(next), s_cwd, e->name);
        if (e->is_dir) {
            CopyStr(s_cwd, sizeof(s_cwd), next); s_browseSel = 0; Browse_Refresh(); return;
        }

        CopyStr(s_pickedFile, sizeof(s_pickedFile), next);
        if (s_browseMode == BROWSE_LOADER) {
            s_imgLen = LoadLocal(s_pickedFile);
            if (s_imgLen <= 0) { SetResult("Could not read Loader image.", 0); return; }
            if (!Update_BeginLoader(&s_job, s_img, s_imgLen, 0)) { SetResult(s_job.msg, 0); return; }
            GotoPhase(PH_STAGE);
            return;
        }
        if (s_browseMode == BROWSE_SCRIPT) {
            int got = File_ReadInto(s_pickedFile, s_work, EOS_SCRIPT_MAXTXT);
            const char* fn = BaseName(s_pickedFile);
            int ln = StrLen(fn);
            int extOk = 0;
            if (ln >= 4) {
                char a = fn[ln - 3], c = fn[ln - 2], d = fn[ln - 1];
                if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
                if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
                if (d >= 'A' && d <= 'Z') d = (char)(d + 32);
                extOk = (fn[ln - 4] == '.' && a == 'e' && c == 'o' && d == 's');
            }
            if (!extOk || got <= 0) { SetMgmtStatus("Select a valid .eos script"); GotoPhase(PH_SCRIPTS); return; }
            s_scriptOp = 1;
            s_scriptPrimed = 0;
            GotoPhase(PH_SCRIPT_CONFIRM);
            return;
        }

        PlanPickedBios(s_flashTarget, s_browseMode == BROWSE_BIOS_RESTORE);
    }
}

static void DoMgmtFlash(int idx)
{
    int rc, actualIdx, sc;
    char nm[EOS_BANK_NAMELEN];
    const char* leaf;

    if (idx < 0 || !s_flashPlan.valid || s_imgLen <= 0) { SetMgmtStatus("Flash preflight expired"); return; }
    sc = s_flashPlan.sizeCode;
    leaf = BaseName(s_pickedFile);
    fileToBankName(nm, EOS_BANK_NAMELEN, leaf);

    if (s_imgLen > 256 * 1024) {
        s_progTitle = (s_imgLen > 512 * 1024) ? "Writing 1MB Bank" : "Writing 512K Bank";
        Flash_SetProgressCb(flashProgress);
        rc = Update_ExtBankFlashAt(s_img, s_imgLen, s_flashPlan.anchorSlot);
        Flash_SetProgressCb(0);
        if (rc == EOS_FLASH_VERIFY) { SetMgmtStatus("Large BIOS verify FAILED"); return; }
        if (rc == EOS_FLASH_REFUSED) { SetMgmtStatus("Placement/descriptor was refused"); return; }
        if (rc != EOS_FLASH_OK) { SetMgmtStatus("Ext-region flash FAILED"); return; }
        actualIdx = Bank_IndexForEf((unsigned char)(0x3 + s_flashPlan.anchorSlot));
        if (actualIdx >= 0 && nm[0]) Bank_SetName(actualIdx, nm);
        rc = Config_Save();
        SetMgmtStatus(rc == EOS_FLASH_OK ? (s_flashIsRestore ? "BIOS restored + verified" : "Large BIOS flashed + verified")
            : "Flashed; bank metadata save FAILED");
        return;
    }

    s_progTitle = s_flashIsRestore ? "Restoring Bank" : "Writing Bank";
    Flash_SetProgressCb(flashProgress);
    rc = WriteNativeImage(s_flashPlan.anchorSlot, s_img, s_imgLen);
    Flash_SetProgressCb(0);
    if (rc == EOS_FLASH_VERIFY) { SetMgmtStatus("Verify FAILED - bank not accepted"); return; }
    if (rc != EOS_FLASH_OK) { SetMgmtStatus("Flash FAILED"); return; }

    Bank_SetOccupied(idx, 1, sc);
    {
        unsigned char ef = Bank_Ef(idx);
        if (ef >= 0x3 && ef <= 0x6) {
            EosLayout lay; int dslot = (int)(ef - 0x3); int bi;
            if (!Desc_Load(&lay) || !lay.valid) Desc_InitEmpty(&lay);
            // Saving a descriptor makes it authoritative for every user slot.
            // Reconcile ALL occupied native banks first so this one flash cannot
            // accidentally make an older neighboring BIOS disappear.
            for (bi = 0; bi < Bank_Count(); ++bi) {
                unsigned char bef = Bank_Ef(bi);
                if (bef >= 0x3 && bef <= 0x6 && Bank_Occupied(bi)) {
                    int bs = (int)(bef - 0x3);
                    if (lay.slot[bs].state == EOS_SLOT_FREE || lay.slot[bs].state == EOS_SLOT_NATIVE) {
                        lay.slot[bs].state = EOS_SLOT_NATIVE;
                        lay.slot[bs].sizeCode = EOS_SZC_256K;
                        lay.slot[bs].physBase = (unsigned int)(bs * 0x040000);
                    }
                }
            }
            lay.slot[dslot].state = EOS_SLOT_NATIVE;
            lay.slot[dslot].sizeCode = EOS_SZC_256K;
            lay.slot[dslot].physBase = (unsigned int)(dslot * 0x040000);
            if (Desc_Save(&lay) != EOS_FLASH_OK) { SetMgmtStatus("BIOS written; descriptor save FAILED"); return; }
        }
    }
    if (nm[0]) Bank_SetName(idx, nm);
    rc = Config_Save();
    SetMgmtStatus(rc == EOS_FLASH_OK ? (s_flashIsRestore ? "BIOS restored + verified" : "BIOS flashed + verified")
        : "Flashed; bank metadata save FAILED");
}

static void DoMgmtDelete(int idx)
{
    int rc, dslot;
    unsigned char ef;
    if (idx < 0 || Bank_IsLocked(idx)) { SetMgmtStatus("Protected bank"); return; }

    ef = Bank_Ef(idx);
    dslot = (ef >= 0x3 && ef <= 0x6) ? (int)(ef - 0x3) : -1;

    /* Ext bank (anchor/shadow): erase its new-region blocks + clear the whole
       descriptor footprint, mirroring the loader's delete. */
    if (dslot >= 0) {
        EosLayout lay;
        if (Desc_Load(&lay) && lay.valid &&
            lay.slot[dslot].state != EOS_SLOT_FREE &&
            lay.slot[dslot].state != EOS_SLOT_NATIVE) {
            int anchor = dslot, span, j;
            if (lay.slot[dslot].state == EOS_SLOT_SHADOW)
                while (anchor > 0 && lay.slot[anchor].state != EOS_SLOT_ANCHOR) --anchor;

            if (lay.slot[anchor].state == EOS_SLOT_ANCHOR) {
                unsigned int base = lay.slot[anchor].physBase;
                span = Desc_SlotsFor(lay.slot[anchor].sizeCode);
                if (base >= EOS_NEWRGN_BASE && base < (EOS_NEWRGN_BASE + 0x100000)) {
                    int firstBlk = (int)((base - EOS_NEWRGN_BASE) / 0x10000);
                    int nblk = (span == 4) ? 16 : 8;
                    int bk;
                    for (bk = 0; bk < nblk && (firstBlk + bk) < 16; ++bk)
                        Flash_EraseBlock(EOS_BANK_NEWREGION, firstBlk + bk);
                }
            }
            else { span = 1; anchor = dslot; }

            for (j = 0; j < span && (anchor + j) < EOS_DESC_SLOTS; ++j) {
                int tbl;
                lay.slot[anchor + j].state = EOS_SLOT_FREE;
                lay.slot[anchor + j].sizeCode = EOS_SZC_256K;
                lay.slot[anchor + j].physBase = 0;
                tbl = Bank_IndexForEf((unsigned char)(0x3 + anchor + j));
                if (tbl >= 0) Bank_ClearEntry(tbl);
            }
            Desc_Save(&lay);
            Config_Save();
            SetMgmtStatus("Bank cleared");
            return;
        }
    }

    /* Normal 256K bank: erase through the physical bank-E window so descriptor
       state cannot redirect the target. */
    rc = EraseNativeImage(dslot);
    if (rc == EOS_FLASH_OK) {
        if (dslot >= 0) {
            EosLayout lay;
            if (Desc_Load(&lay) && lay.valid && lay.slot[dslot].state == EOS_SLOT_NATIVE) {
                lay.slot[dslot].state = EOS_SLOT_FREE;
                lay.slot[dslot].sizeCode = EOS_SZC_256K;
                lay.slot[dslot].physBase = 0;
                Desc_Save(&lay);
            }
        }
        Bank_ClearEntry(idx); rc = Config_Save();
        SetMgmtStatus(rc == EOS_FLASH_OK ? "Bank cleared" : "Erased; cfg save FAILED");
    }
    else SetMgmtStatus("Erase FAILED");
}

static void Ph_BankMgmt(WORD b)
{
    int n = Bank_Count();
    if (n <= 0) n = 1;
    if (s_bankSel >= n) s_bankSel = (n > 0) ? n - 1 : 0;
    if (Pressed(b, s_prev, BTN_DPAD_UP))   s_bankSel = (s_bankSel + n - 1) % n;
    if (Pressed(b, s_prev, BTN_DPAD_DOWN)) s_bankSel = (s_bankSel + 1) % n;
    if (Pressed(b, s_prev, BTN_B)) { GotoPhase(PH_MENU); return; }

    /* A = Flash a BIOS into this bank */
    if (Pressed(b, s_prev, BTN_A)) {
        if (Bank_IsLocked(s_bankSel)) { SetMgmtStatus("Cannot flash locked bank"); }
        else { s_flashTarget = s_bankSel; s_flashIsRestore = 0; s_cwd[0] = 0; s_browseSel = 0; s_browseMode = BROWSE_BIOS_FLASH; Browse_Refresh(); GotoPhase(PH_BROWSE); }
        return;
    }
    /* X = Delete (erase) */
    if (Pressed(b, s_prev, BTN_X)) {
        if (Bank_IsLocked(s_bankSel)) { SetMgmtStatus("Cannot delete locked bank"); }
        else {
            int ds = descSlotForBank(s_bankSel);
            EosLayout dl;
            int marked = (ds >= 0 && Desc_Load(&dl) && dl.valid && dl.slot[ds].state != EOS_SLOT_FREE);
            if (!Bank_Occupied(s_bankSel) && !marked) { SetMgmtStatus("Bank already empty"); return; }
            int p = 0; s_confirmMsg[0] = 0;
            p = appendStr(s_confirmMsg, p, "Delete "); p = appendStr(s_confirmMsg, p, Bank_Name(s_bankSel)); appendStr(s_confirmMsg, p, " ?");
            s_pendAct = ACT_DELETE; s_pendIdx = s_bankSel; GotoPhase(PH_MGMT_CONFIRM);
        }
        return;
    }
    /* Y = Rename */
    if (Pressed(b, s_prev, BTN_Y)) {
        if (Bank_IsLocked(s_bankSel)) { SetMgmtStatus("Cannot rename locked bank"); }
        else { s_renameTarget = s_bankSel; Osk_Open(OSK_TEXT, Bank_Name(s_bankSel), EOS_BANK_NAMELEN - 1); GotoPhase(PH_RENAME); }
        return;
    }

    /* Black = set this user bank's persistent LED color. Shadow slots inherit
       the color of their oversized-bank anchor and cannot be set separately. */
    if (Pressed(b, s_prev, BTN_BLACK)) {
        int cslot = descSlotForBank(s_bankSel);
        if (Bank_IsLocked(s_bankSel)) {
            SetMgmtStatus("Cannot set color on locked bank");
        }
        else if (cslot < 0) {
            SetMgmtStatus("Not a user bank");
        }
        else {
            EosLayout lay;
            if (Desc_Load(&lay) && lay.valid && lay.slot[cslot].state == EOS_SLOT_SHADOW) {
                SetMgmtStatus("Slot is part of a large bank");
            }
            else {
                LedPick_Open(s_bankSel, PH_BANKMGMT);
                GotoPhase(PH_LEDCOLOR);
                return;
            }
        }
    }
}

static void Ph_Rename(WORD b)
{
    int r = Osk_Update(b ^ s_prev);   /* edges */
    if (r == 1) {
        char nm[EOS_BANK_NAMELEN]; Osk_GetText(nm, sizeof(nm));
        if (nm[0]) { Bank_SetName(s_renameTarget, nm); Config_Save(); SetMgmtStatus("Renamed"); }
        GotoPhase(PH_BANKMGMT);
    }
    if (r == -1) GotoPhase(PH_BANKMGMT);
}

/* ---- Utilities: backup/restore + clears --------------------------------- */

static char s_utilStatus[64] = "";
static void SetUtilStatus(const char* m) { int i = 0; while (m[i] && i < 63) { s_utilStatus[i] = m[i]; ++i; } s_utilStatus[i] = 0; }


static void backupProgress(const char* stage, int done, int total)
{
    int bx, bw, bh, by, fillw, pct;
    char msg[16]; int mp = 0;
    pct = (total > 0) ? (int)(((long)done * 100) / total) : 0;
    if (pct < 0) pct = 0; if (pct > 100) pct = 100;
    bw = (g_scrW * 3) / 5; bh = 28; bx = (g_scrW - bw) / 2; by = g_scrH / 2 + 10;
    fillw = (bw * pct) / 100;
    Gfx_Begin(EOS_BG); Ui_Backdrop(); Ui_TitleBar(stage ? stage : "EOS Backup");
    Font_DrawCentered(0, g_scrW, by - 70, "EOS maintenance in progress...", EOS_WHITE);
    Gfx_FillRounded(bx - 2, by - 2, bw + 4, bh + 4, 8, EOS_DIM);
    if (fillw > 0) Gfx_FillRounded(bx, by, fillw, bh, 6, EOS_PURPLE);
    if (pct >= 100) { msg[mp++] = '1'; msg[mp++] = '0'; msg[mp++] = '0'; }
    else { if (pct >= 10) msg[mp++] = (char)('0' + pct / 10); msg[mp++] = (char)('0' + pct % 10); }
    msg[mp++] = '%'; msg[mp] = 0;
    Font_DrawCentered(0, g_scrW, by + bh + 16, msg, EOS_PURPLE);
    Font_DrawCentered(0, g_scrW, by + bh + 46, "Keep the console powered on until this step completes.", EOS_DIM);
    Gfx_End();
}

static void DoBackupBank(int idx)
{
    char path[300];
    const char* fn;
    char msg[96];
    int p = 0;
    if (idx < 0 || !Bank_Occupied(idx)) { SetUtilStatus("Bank is empty"); return; }
    Backup_SetProgressCb(backupProgress);
    if (!Backup_SaveBankManual(idx, s_work, WORK_CAP, path, sizeof(path))) {
        Backup_SetProgressCb(0); SetUtilStatus("Backup failed - check app folder"); return;
    }
    Backup_SetProgressCb(0);
    fn = BaseName(path);
    msg[0] = 0; p = appendStr(msg, p, "Saved: "); appendStr(msg, p, fn);
    SetUtilStatus(msg);
}

static void DoClearXbDiag(void)
{
    int i, rc, xd = -1;
    for (i = 0; i < Bank_Count(); ++i) if ((Bank_Ef(i) & 0x0F) == 0x0D) { xd = i; break; }
    if (xd < 0) { SetUtilStatus("No XbDiag bank"); return; }
    rc = Flash_EraseBank(0x0D);
    if (rc != EOS_FLASH_OK) { SetUtilStatus("Erase FAILED"); return; }
    Bank_ClearEntry(xd);
    Config_Save();
    SetUtilStatus("XbDiag cleared");
}

static void DoClearSettings(void)
{
    int rc = Config_ResetSettings();   /* theme/bgm only; banks + names untouched */
    SetUtilStatus(rc == EOS_FLASH_OK ? "Settings cleared" : "Clear FAILED");
}

static void DoClearNames(void)
{
    int rc;
    Bank_ResetUserNames();             /* labels only; occupancy/layout/colors remain */
    rc = Config_Save();
    SetUtilStatus(rc == EOS_FLASH_OK ? "Names cleared" : "Saved names FAILED");
}

static void Ph_MgmtConfirm(WORD b)
{
    int returnPhase = PH_BANKMGMT;
    if (s_pendAct == ACT_CLEAR_XBDIAG || s_pendAct == ACT_CLEAR_SETTINGS || s_pendAct == ACT_CLEAR_NAMES)
        returnPhase = PH_UTILITIES;
    else if (s_pendAct == ACT_MGMT_FLASH && s_flashIsRestore)
        returnPhase = PH_UTILITIES;

    if (Pressed(b, s_prev, BTN_A)) {
        if (s_pendAct == ACT_DELETE) DoMgmtDelete(s_pendIdx);
        else if (s_pendAct == ACT_MGMT_FLASH) DoMgmtFlash(s_pendIdx);
        else if (s_pendAct == ACT_CLEAR_XBDIAG) DoClearXbDiag();
        else if (s_pendAct == ACT_CLEAR_SETTINGS) DoClearSettings();
        else if (s_pendAct == ACT_CLEAR_NAMES) DoClearNames();
        s_pendAct = ACT_NONE; s_pendIdx = -1; s_flashPlan.valid = 0;
        RefreshUiLayout();
        GotoPhase(returnPhase);
        return;
    }
    if (Pressed(b, s_prev, BTN_B)) {
        s_pendAct = ACT_NONE; s_pendIdx = -1; s_flashPlan.valid = 0;
        GotoPhase(returnPhase);
        return;
    }
}

/* Utilities menu rows. Backup/Restore lead into a bank picker; the three clears
   go through the confirm gate. */
enum { UTIL_BACKUP = 0, UTIL_RESTORE, UTIL_CLR_XBDIAG, UTIL_CLR_SETTINGS, UTIL_CLR_NAMES, UTIL_COUNT };

static void Ph_Utilities(WORD b)
{
    if (Pressed(b, s_prev, BTN_DPAD_UP))   s_utilSel = (s_utilSel + UTIL_COUNT - 1) % UTIL_COUNT;
    if (Pressed(b, s_prev, BTN_DPAD_DOWN)) s_utilSel = (s_utilSel + 1) % UTIL_COUNT;
    if (Pressed(b, s_prev, BTN_B)) { s_utilStatus[0] = 0; GotoPhase(PH_MENU); return; }
    if (Pressed(b, s_prev, BTN_A)) {
        switch (s_utilSel) {
        case UTIL_BACKUP:  s_utilMode = 0; s_utilBankSel = 0; RefreshUiLayout(); GotoPhase(PH_UTIL_BANKPICK); break;
        case UTIL_RESTORE: s_utilMode = 1; s_utilBankSel = 0; RefreshUiLayout(); GotoPhase(PH_UTIL_BANKPICK); break;
        case UTIL_CLR_XBDIAG:
            CopyStr(s_confirmMsg, sizeof(s_confirmMsg), "Clear the XbDiag bank?");
            s_pendAct = ACT_CLEAR_XBDIAG; GotoPhase(PH_MGMT_CONFIRM); break;
        case UTIL_CLR_SETTINGS:
            CopyStr(s_confirmMsg, sizeof(s_confirmMsg), "Reset all settings to defaults?");
            s_pendAct = ACT_CLEAR_SETTINGS; GotoPhase(PH_MGMT_CONFIRM); break;
        case UTIL_CLR_NAMES:
            CopyStr(s_confirmMsg, sizeof(s_confirmMsg), "Reset all bank names?");
            s_pendAct = ACT_CLEAR_NAMES; GotoPhase(PH_MGMT_CONFIRM); break;
        }
    }
}

/* Bank picker for backup (mode 0) / restore (mode 1). Restore reuses the file
   browser to pick a .bin, then flashes it into the chosen bank via DoMgmtFlash. */
static void Ph_UtilBankPick(WORD b)
{
    int n = Bank_Count();
    if (n <= 0) n = 1;
    if (s_utilBankSel >= n) s_utilBankSel = n - 1;
    if (Pressed(b, s_prev, BTN_DPAD_UP))   s_utilBankSel = (s_utilBankSel + n - 1) % n;
    if (Pressed(b, s_prev, BTN_DPAD_DOWN)) s_utilBankSel = (s_utilBankSel + 1) % n;
    if (Pressed(b, s_prev, BTN_B)) { GotoPhase(PH_UTILITIES); return; }
    if (Pressed(b, s_prev, BTN_A)) {
        if (s_utilMode == 0) {
            DoBackupBank(s_utilBankSel);      /* backup -> writes to local drive */
            GotoPhase(PH_UTILITIES);
        }
        else {
            /* restore: pick a file, flash into this bank (reuses the bank-mgmt path) */
            if (Bank_IsLocked(s_utilBankSel)) { SetUtilStatus("Bank is locked"); GotoPhase(PH_UTILITIES); return; }
            s_flashTarget = s_utilBankSel; s_flashIsRestore = 1;
            s_cwd[0] = 0; s_browseSel = 0; s_browseMode = BROWSE_BIOS_RESTORE; Browse_Refresh();
            GotoPhase(PH_BROWSE);
        }
    }
}

static void Ph_Stage(WORD b)
{
    int st = Update_Pump(&s_job);
    if (st == UPD_CONFIRM) {
        if (s_job.region == EOS_RGN_LOADER) {
            s_loaderHasBackup = 0;
            ZeroMemory(&s_loaderBackup, sizeof(s_loaderBackup));
            GotoPhase(PH_LOADER_WARN);
        }
        else GotoPhase(PH_CONFIRM);
        return;
    }
    if (st == UPD_DONE) {
        if (s_job.region == EOS_RGN_XBDIAG) StampXbDiag();
        SetResult(s_job.msg, 0); return;
    }
    if (st == UPD_FAILED) { SetResult(s_job.msg, 0); return; }
    (void)b;
}

static void Ph_Confirm(WORD b)
{
    if (Pressed(b, s_prev, BTN_A)) { Update_Confirm(&s_job); s_writePrimed = 0; GotoPhase(PH_WRITING); }
    if (Pressed(b, s_prev, BTN_B)) { Update_Cancel(&s_job); SetResult("Cancelled.", 0); }
}

static void Ph_LoaderWarn(WORD b)
{
    if (Pressed(b, s_prev, BTN_B)) { Update_Cancel(&s_job); SetResult("Loader update cancelled.", 0); return; }
    if (Pressed(b, s_prev, BTN_A)) { GotoPhase(PH_LOADER_BACKUP_PROMPT); }
}

static void Ph_LoaderBackupPrompt(WORD b)
{
    if (Pressed(b, s_prev, BTN_B)) { Update_Cancel(&s_job); SetResult("Loader update cancelled.", 0); return; }
    if (Pressed(b, s_prev, BTN_A)) { s_loaderOpPrimed = 0; GotoPhase(PH_LOADER_BACKINGUP); return; }
    if (Pressed(b, s_prev, BTN_X)) {
        s_loaderHasBackup = 0;
        Update_Confirm(&s_job); s_writePrimed = 0; GotoPhase(PH_WRITING); return;
    }
}

static void Ph_LoaderBackingUp(WORD b)
{
    (void)b;
    if (!s_loaderOpPrimed) { s_loaderOpPrimed = 1; return; }
    Backup_SetProgressCb(backupProgress);
    if (!Backup_CreateLoaderSet(&s_loaderBackup, s_work, WORK_CAP)) {
        Backup_SetProgressCb(0);
        Update_Cancel(&s_job);
        SetResult("Backup failed. Loader was NOT flashed.", 0);
        return;
    }
    Backup_SetProgressCb(0);
    s_loaderHasBackup = 1;
    Update_Confirm(&s_job); s_writePrimed = 0; GotoPhase(PH_WRITING);
}

static void Ph_Writing(WORD b)
{
    int st;
    (void)b;
    if (!s_writePrimed) { s_writePrimed = 1; return; }
    s_progTitle = (s_job.region == EOS_RGN_XBDIAG) ? "Writing XbDiag" : "Writing Loader";
    Flash_SetProgressCb(flashProgress);
    st = Update_Pump(&s_job);
    Flash_SetProgressCb(0);
    if (st == UPD_DONE) {
        if (s_job.region == EOS_RGN_XBDIAG) {
            StampXbDiag(); SetResult("XbDiag Lite updated and verified.", 0); return;
        }
        if (s_job.region == EOS_RGN_LOADER) {
            GotoPhase(s_loaderHasBackup ? PH_LOADER_RESTORE_PROMPT : PH_LOADER_FACTORY_WARN);
            return;
        }
        SetResult(s_job.msg, 0); return;
    }
    if (st == UPD_FAILED) { SetResult(s_job.msg, 0); return; }
}

static void Ph_LoaderRestorePrompt(WORD b)
{
    if (Pressed(b, s_prev, BTN_A)) { s_loaderOpPrimed = 0; GotoPhase(PH_LOADER_RESTORING); return; }
    if (Pressed(b, s_prev, BTN_X)) { GotoPhase(PH_LOADER_FACTORY_WARN); return; }
}

static void Ph_LoaderRestoring(WORD b)
{
    (void)b;
    if (!s_loaderOpPrimed) { s_loaderOpPrimed = 1; return; }
    Backup_SetProgressCb(backupProgress);
    if (!Backup_RestoreLoaderSet(&s_loaderBackup, s_work, WORK_CAP)) {
        const char* why;
        int p;
        Backup_SetProgressCb(0);
        CopyStr(s_statusMsg, sizeof(s_statusMsg), "Restore failed");
        why = Backup_LastError();
        if (why && why[0]) {
            p = StrLen(s_statusMsg);
            if (p < (int)sizeof(s_statusMsg) - 3) { s_statusMsg[p++] = ':'; s_statusMsg[p++] = ' '; s_statusMsg[p] = 0; }
            CopyStr(s_statusMsg + p, (int)sizeof(s_statusMsg) - p, why);
        }
        s_statusUntil = GetTickCount() + 6500;
        s_loaderOpPrimed = 0;
        GotoPhase(PH_LOADER_RESTORE_PROMPT);
        return;
    }
    Backup_SetProgressCb(0);
    RefreshStatus();

    /* Keep the success prompt so the user decides when to reboot.  The reboot
       action itself is HARD so the restored flash/descriptor are reloaded from
       persistent storage rather than relying on resident BIOS state. */
    SetResultHardReboot("Loader updated. BIOS banks, Recovery and configuration restored + verified.");
}

static void Ph_LoaderFactoryWarn(WORD b)
{
    if (Pressed(b, s_prev, BTN_A)) { s_loaderOpPrimed = 0; GotoPhase(PH_LOADER_FACTORY); return; }
    if (Pressed(b, s_prev, BTN_B) && s_loaderHasBackup) { GotoPhase(PH_LOADER_RESTORE_PROMPT); return; }
}

static void Ph_LoaderFactory(WORD b)
{
    (void)b;
    if (!s_loaderOpPrimed) { s_loaderOpPrimed = 1; return; }
    if (!Backup_ResetFactoryUserBanks()) {
        SetResult("Loader updated, but the BIOS bank layout reset failed.", 0);
        return;
    }
    RefreshStatus();
    SetResult("Loader updated. BIOS banks returned to factory/default layout.", 1);
}

static void Ph_Result(WORD b)
{
    if (s_resultReboot && Pressed(b, s_prev, BTN_A)) {
        Smb_SetLedMode(0);
        HalReturnToFirmware(s_resultHardReboot ? RETURN_FIRMWARE_HARD : RETURN_FIRMWARE_REBOOT);
        return;
    }
    if (Pressed(b, s_prev, BTN_B) || (!s_resultReboot && Pressed(b, s_prev, BTN_A))) {
        s_menuSel = 0;
        GotoPhase(PH_MENU);
    }
}

/* ---- per-phase draw ------------------------------------------------------- */
static void Draw_ProgressBar(int pct, const char* label)
{
    int x = 80, y = 250, w = g_scrW - 160, h = 28;
    if (pct < 0) pct = 0; if (pct > 100) pct = 100;
    Gfx_FillRounded(x, y, w, h, h / 2, EOS_PANEL);
    if (pct > 0) Gfx_FillRounded(x, y, (w * pct) / 100, h, h / 2, EOS_PURPLE);
    Font_DrawCentered(0, g_scrW, y + h + 16, label, EOS_WHITE);
}

static void DrawStatusValue(int y, const char* label, const char* value, DWORD valueColor)
{
    Font_Draw(78, y, label, EOS_DIM);
    Font_Draw(250, y, value, valueColor);
}

static void Draw_StatusScreen(void)
{
    char ver[24], line[96];
    int i, y;
    EosVer iv;

    Ui_TitleBar("EOS STATUS");

    // Post-boot maintenance summary only. Keep this intentionally focused on
    // useful installed-state information and comfortably above the 480p footer.
    Gfx_FillRounded(54, 76, g_scrW - 108, 72, 14, EOS_PANEL);
    if (s_status.eosPresent) {
        BuildVersionText(ver, sizeof(ver), s_status.verMaj, s_status.verMin, s_status.verPat);
        DrawStatusValue(88, "EOS", ver, EOS_WHITE);
    }
    else DrawStatusValue(88, "EOS", "Not Detected", EOS_PURPLE);
    DrawStatusValue(108, "Bank Layout", Status_LayoutText(&s_status), EOS_WHITE);
    DrawStatusValue(128, "Protection", Status_ProtectionText(&s_status), EOS_WHITE);

    Gfx_FillRounded(54, 158, g_scrW - 108, 112, 14, EOS_PANEL);
    Font_Draw(72, 168, "BIOS BANKS", EOS_PURPLE);
    y = 190;
    for (i = 0; i < 4; ++i) {
        int idx = Bank_IndexForEf((unsigned char)(0x3 + i));
        if (idx >= 0) buildMgmtRow(line, idx); else CopyStr(line, sizeof(line), "Unavailable");
        Font_Draw(78, y, line, EOS_WHITE); y += 19;
    }

    Gfx_FillRounded(54, 280, g_scrW - 108, 72, 14, EOS_PANEL);
    DrawStatusValue(290, "XbDiag Lite", s_status.xbdiagPresent ? "Installed" : "Not Installed", EOS_WHITE);
    DrawStatusValue(310, "EOS Script", Script_StateText(s_status.script.state),
        (s_status.script.state == EOS_SCRIPT_FAULT || s_status.script.state == EOS_SCRIPT_INVALID) ? EOS_PURPLE : EOS_WHITE);
    DrawStatusValue(330, "Backups", s_status.backupAvailable ? "Available" : "None Yet", EOS_WHITE);

    // Update-server state is useful here; the Xbox network/IP itself is not.
    if (!s_serverChecked) CopyStr(line, sizeof(line), "Update Server: Not checked");
    else if (!s_serverOnline) CopyStr(line, sizeof(line), "Update Server: Unavailable");
    else {
        CopyStr(line, sizeof(line), "Update Server: Online");
        if (s_serverXbdKnown && Update_XbDiagInstalled(&iv) && Ver_Compare(s_serverXbdVer, iv) > 0) {
            int p = StrLen(line);
            if (p < (int)sizeof(line) - 1) { line[p++] = ' '; line[p] = 0; }
            if (p < (int)sizeof(line) - 1) { line[p++] = '-'; line[p] = 0; }
            if (p < (int)sizeof(line) - 1) { line[p++] = ' '; line[p] = 0; }
            CopyStr(line + p, (int)sizeof(line) - p, "XbDiag update available");
        }
    }
    if (s_statusMsg[0] && GetTickCount() < s_statusUntil)
        Font_DrawCentered(0, g_scrW, 374, s_statusMsg, EOS_PURPLE);
    else
        Font_DrawCentered(0, g_scrW, 374, line, s_serverChecked && !s_serverOnline ? EOS_PURPLE : EOS_DIM);
    Ui_Footer("A Refresh   Y Check Server   B Back");
}

static void DrawFlashPreflight(void)
{
    char line[100], placement[48];
    int p = 0;
    Ui_TitleBar(s_flashIsRestore ? "CONFIRM BIOS RESTORE" : "CONFIRM BIOS FLASH");

    line[0] = 0; p = appendStr(line, p, "Image: "); appendStr(line, p, s_flashLeaf);
    Font_DrawCentered(0, g_scrW, 126, line, EOS_WHITE);

    line[0] = 0; p = 0; p = appendStr(line, p, "Size: "); appendStr(line, p, sizeStr(s_flashPlan.sizeCode));
    Font_DrawCentered(0, g_scrW, 158, line, EOS_DIM);

    placement[0] = 0;
    if (s_flashPlan.slots == 1) {
        CopyStr(placement, sizeof(placement), "Target: Bank "); appendSmallInt(placement, sizeof(placement), s_flashPlan.anchorSlot + 1);
    }
    else {
        CopyStr(placement, sizeof(placement), "Placement: Banks "); appendSmallInt(placement, sizeof(placement), s_flashPlan.anchorSlot + 1);
        { int n = StrLen(placement); if (n < (int)sizeof(placement) - 1) { placement[n++] = '-'; placement[n] = 0; } }
        appendSmallInt(placement, sizeof(placement), s_flashPlan.anchorSlot + s_flashPlan.slots);
    }
    Font_DrawCentered(0, g_scrW, 194, placement, EOS_WHITE);

    if (s_flashPlan.slots == 1 && s_pendIdx >= 0) {
        line[0] = 0; p = 0; p = appendStr(line, p, "Current: "); appendStr(line, p, Bank_Occupied(s_pendIdx) ? Bank_Name(s_pendIdx) : "Empty");
        Font_DrawCentered(0, g_scrW, 226, line, Bank_Occupied(s_pendIdx) ? EOS_PURPLE : EOS_DIM);
    }
    else {
        Font_DrawCentered(0, g_scrW, 226, "The shown slot range will be reserved for this BIOS.", EOS_DIM);
    }

    Font_DrawCentered(0, g_scrW, 282, "The target flash area will be erased and verified page-by-page.", EOS_DIM);
    Ui_Footer("A Confirm Write   B Cancel");
}

static void DrawPhase(void)
{
    Gfx_Begin(EOS_BG);
    Ui_Backdrop();

    switch (s_phase) {
    case PH_SPLASH:
        Splash_Draw(g_scrW / 2, g_scrH / 2 - 20, 256, EOS_WHITE);
        Font_DrawCentered(0, g_scrW, g_scrH - 120, "EOS UPDATER", EOS_PURPLE);
        break;

    case PH_MENU:
        Ui_TitleBar("EOS Maintenance");
        Ui_Menu3D(k_menu, 6, s_menuSel);
        if (s_eosVer[0]) Font_Draw(g_scrW - 200, g_scrH - 86, s_eosVer, EOS_DIM);
        Font_Draw(g_scrW - 200, g_scrH - 68, s_status.eosPresent ? "Maintenance Ready" : "EOS Not Detected",
            s_status.eosPresent ? EOS_DIM : EOS_PURPLE);
        Ui_Footer("A Select   B Exit");
        break;

    case PH_STATUS:
        Draw_StatusScreen();
        break;
    case PH_STATUS_FETCH:
        Ui_TitleBar("EOS STATUS");
        Font_DrawCentered(0, g_scrW, 230, "Checking update server...", EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 266, EOS_NET_HOST, EOS_DIM);
        break;

    case PH_LOADER_SRC: {
        const char* opts[2]; opts[0] = "Internet  (latest from server)"; opts[1] = "Local File  (browse)";
        DrawList("Update Loader - Source", opts, 2, s_srcSel, "A Select   B Back");
        break;
    }
    case PH_BROWSE: {
        static const char* names[EOS_FILE_MAX_ENTRIES];
        int i, n = s_entryCount;
        const char* title = "Pick File";
        if (s_browseMode == BROWSE_LOADER) title = "Loader - Pick File";
        else if (s_browseMode == BROWSE_SCRIPT) title = "EOS Script - Pick .eos";
        else if (s_browseMode == BROWSE_BIOS_RESTORE) title = "Restore BIOS - Pick File";
        else title = "BIOS - Pick File";
        for (i = 0; i < n && i < EOS_FILE_MAX_ENTRIES; ++i) names[i] = s_entries[i].name;
        Ui_TitleBar(title);
        {
            int y = 112, rowH = 30, gap = 5, x = 70, w = g_scrW - 140, top = s_browseSel - 5;
            if (top < 0) top = 0;
            for (i = top; i < n && i < top + 10; ++i) {
                Ui_PillLeft(x, y, w, rowH, 8, (i == s_browseSel), names[i]);
                y += rowH + gap;
            }
        }
        Ui_Footer((s_cwd[0] == 0) ? "A Open drive   B Back" : "A Open/Select   B Up");
        break;
    }
    case PH_BANKMGMT: {
        int i, count = Bank_Count();
        static char rows[EOS_BANK_MAX][64]; const char* ptrs[EOS_BANK_MAX];
        int cap = (count < EOS_BANK_MAX) ? count : EOS_BANK_MAX;
        Ui_TitleBar("BANK MANAGEMENT");
        for (i = 0; i < cap; ++i) { buildMgmtRow(rows[i], i); ptrs[i] = rows[i]; }
        Ui_Menu3D(ptrs, cap, s_bankSel);
        if (s_statusMsg[0] && GetTickCount() < s_statusUntil)
            Font_DrawCentered(0, g_scrW, g_scrH - 94, s_statusMsg, EOS_PURPLE);
        Ui_Footer("A Flash   X Delete   Y Rename   Black LED   B Back");
        break;
    }
    case PH_RENAME:
        Ui_TitleBar("RENAME BANK"); Osk_Draw(); Ui_Footer("Start Confirm   Back Cancel"); break;

    case PH_MGMT_CONFIRM:
        if (s_pendAct == ACT_MGMT_FLASH) DrawFlashPreflight();
        else {
            Ui_TitleBar("CONFIRM");
            Font_DrawCentered(0, g_scrW, 220, s_confirmMsg, EOS_WHITE);
            Font_DrawCentered(0, g_scrW, 260, "This change is persistent.", EOS_DIM);
            Ui_Footer("A Yes   B No");
        }
        break;

    case PH_SCRIPTS:
        Ui_TitleBar("EOS SCRIPTS");
        Gfx_FillRounded(74, 126, g_scrW - 148, 150, 16, EOS_PANEL);
        Font_Draw(96, 148, "Status", EOS_DIM);
        Font_Draw(250, 148, Script_StateText(s_scriptInfo.state),
            (s_scriptInfo.state == EOS_SCRIPT_FAULT || s_scriptInfo.state == EOS_SCRIPT_INVALID) ? EOS_PURPLE : EOS_WHITE);
        Font_Draw(96, 180, "Installed", EOS_DIM);
        Font_Draw(250, 180, s_scriptInfo.present ? "Yes" : "No", EOS_WHITE);
        if (s_scriptInfo.present) {
            Font_Draw(96, 212, "Target", EOS_DIM);
            Font_Draw(250, 212, s_scriptInfo.targetHd ? "HD Expansion" : "Standard / NOHD", EOS_WHITE);
        }
        Font_DrawCentered(0, g_scrW, 312, s_scriptInfo.present ? "A Replace Script" : "A Install Script", EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 344, s_scriptInfo.present ? "X Remove Script" : "X Remove Script (not installed)", EOS_DIM);
        if (s_statusMsg[0] && GetTickCount() < s_statusUntil)
            Font_DrawCentered(0, g_scrW, 392, s_statusMsg, EOS_PURPLE);
        Ui_Footer("A Install/Replace   X Remove   Y Refresh   B Back");
        break;

    case PH_SCRIPT_CONFIRM:
        Ui_TitleBar(s_scriptOp == 2 ? "REMOVE EOS SCRIPT" : "INSTALL EOS SCRIPT");
        if (s_scriptOp == 2) {
            Font_DrawCentered(0, g_scrW, 202, "Remove the currently installed EOS expansion script?", EOS_WHITE);
            Font_DrawCentered(0, g_scrW, 238, "The expansion script slot will be erased and resynced.", EOS_DIM);
        }
        else {
            Font_DrawCentered(0, g_scrW, 184, "Install and start this EOS script?", EOS_WHITE);
            Font_DrawCentered(0, g_scrW, 220, BaseName(s_pickedFile), EOS_PURPLE);
            Font_DrawCentered(0, g_scrW, 256, "The selected file passed basic .eos size/type validation.", EOS_DIM);
        }
        Ui_Footer("A Confirm   B Cancel");
        break;
    case PH_SCRIPT_WORK:
        Ui_TitleBar("EOS SCRIPTS");
        Font_DrawCentered(0, g_scrW, 230, s_scriptOp == 2 ? "Removing script..." : "Installing and verifying script...", EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 270, "Do not power off while flash is being written.", EOS_PURPLE);
        break;

    case PH_NET_FETCH:
        Ui_TitleBar((s_fetchWhat == FETCH_LOADER) ? "Update Loader" : "Update XbDiag Lite");
        Font_DrawCentered(0, g_scrW, 240, "Contacting server...", EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 280, EOS_NET_HOST, EOS_DIM);
        break;
    case PH_STAGE:
        Ui_TitleBar("Validating Update"); Draw_ProgressBar(Update_Progress(&s_job), s_job.msg); break;
    case PH_CONFIRM:
        Ui_TitleBar("Confirm Update");
        Font_DrawCentered(0, g_scrW, 220, Update_ConfirmText(&s_job), EOS_WHITE);
        Ui_Footer("A Confirm Write   B Cancel");
        break;
    case PH_WRITING:
        Ui_TitleBar("Updating");
        Font_DrawCentered(0, g_scrW, 240, "Writing flash - do NOT power off...", EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 280, "Every page is read back and verified.", EOS_PURPLE);
        break;

    case PH_LOADER_WARN:
        Ui_TitleBar("LOADER UPDATE WARNING");
        Font_DrawCentered(0, g_scrW, 132, "Updating the EOS Loader replaces the native BIOS region.", EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 172, "Native BIOS Banks 1-4 can be erased by this update.", EOS_PURPLE);
        Font_DrawCentered(0, g_scrW, 214, "Recovery, XbDiag and EOS settings are stored separately.", EOS_DIM);
        Font_DrawCentered(0, g_scrW, 260, "The updater backs up BIOS banks, Recovery and configuration.", EOS_WHITE);
        Ui_Footer("A Continue   B Cancel");
        break;
    case PH_LOADER_BACKUP_PROMPT:
        Ui_TitleBar("BACK UP EOS BANKS?");
        Font_DrawCentered(0, g_scrW, 156, "Recommended: save BIOS banks + Recovery before flashing.", EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 198, "Backups, descriptor and bank metadata are stored in:", EOS_DIM);
        Font_DrawCentered(0, g_scrW, 228, "Updater Folder\\backups\\loader_update_XX", EOS_PURPLE);
        Font_DrawCentered(0, g_scrW, 276, "Skipping backup will require a factory bank-layout reset after update.", EOS_DIM);
        Ui_Footer("A Back Up + Continue   X Skip Backup   B Cancel");
        break;
    case PH_LOADER_BACKINGUP:
        Ui_TitleBar("BACKING UP EOS");
        Font_DrawCentered(0, g_scrW, 220, "Saving BIOS banks, Recovery, descriptor and bank table...", EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 260, "The Loader has not been flashed yet.", EOS_DIM);
        break;
    case PH_LOADER_RESTORE_PROMPT:
        Ui_TitleBar("RESTORE EOS BANKS?");
        Font_DrawCentered(0, g_scrW, 154, "EOS Loader updated successfully.", EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 196, "Restore BIOS banks, Recovery and configuration from the backup?", EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 240, "Oversized banks are verified first and only rewritten if needed.", EOS_DIM);
        if (s_statusMsg[0] && GetTickCount() < s_statusUntil)
            Font_DrawCentered(0, g_scrW, 300, s_statusMsg, EOS_PURPLE);
        Ui_Footer("A Restore Backup   X Do Not Restore");
        break;
    case PH_LOADER_RESTORING:
        Ui_TitleBar("RESTORING BIOS BANKS");
        Font_DrawCentered(0, g_scrW, 230, "Restoring and verifying your pre-update bank configuration...", EOS_WHITE);
        break;
    case PH_LOADER_FACTORY_WARN:
        Ui_TitleBar("RESET BIOS BANK LAYOUT");
        Font_DrawCentered(0, g_scrW, 140, "BIOS banks will not be restored.", EOS_PURPLE);
        Font_DrawCentered(0, g_scrW, 182, "EOS will clear Banks 1-4 names, mappings and LED assignments.", EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 224, "Recovery, XbDiag and unrelated EOS settings are preserved.", EOS_DIM);
        Font_DrawCentered(0, g_scrW, 270, "Oversized-bank flash bytes are left untouched but unmapped.", EOS_DIM);
        Ui_Footer(s_loaderHasBackup ? "A Factory Reset Banks   B Return to Restore" : "A Factory Reset Banks");
        break;
    case PH_LOADER_FACTORY:
        Ui_TitleBar("RESETTING BIOS BANKS");
        Font_DrawCentered(0, g_scrW, 236, "Returning the BIOS bank layout to defaults...", EOS_WHITE);
        break;

    case PH_RESULT:
        Ui_TitleBar("Result");
        Font_DrawCentered(40, g_scrW - 40, 230, s_resultMsg, EOS_WHITE);
        Ui_Footer(s_resultReboot ? "A Reboot   B Main Menu" : "A / B  Back to menu");
        break;
    case PH_UTILITIES: {
        static const char* k_util[UTIL_COUNT] = {
            "Backup Bank -> App Backups", "Restore Bank <- File",
            "Clear XbDiag Bank", "Reset EOS Settings", "Clear Bank Names"
        };
        Ui_TitleBar("UTILITIES"); Ui_Menu3D(k_util, UTIL_COUNT, s_utilSel);
        if (s_utilStatus[0]) Font_DrawCentered(0, g_scrW, g_scrH - 94, s_utilStatus, EOS_PURPLE);
        Ui_Footer("A Select   B Back");
        break;
    }
    case PH_UTIL_BANKPICK: {
        int i, count = Bank_Count();
        static char rows[EOS_BANK_MAX][64]; const char* ptrs[EOS_BANK_MAX];
        int cap = (count < EOS_BANK_MAX) ? count : EOS_BANK_MAX;
        Ui_TitleBar(s_utilMode == 0 ? "BACKUP - PICK BANK" : "RESTORE - PICK BANK");
        for (i = 0; i < cap; ++i) { buildMgmtRow(rows[i], i); ptrs[i] = rows[i]; }
        Ui_Menu3D(ptrs, cap, s_utilBankSel);
        Ui_Footer(s_utilMode == 0 ? "A Backup to app folder   B Back" : "A Pick File   B Back");
        break;
    }
    }
    Gfx_End();
}

/* ---- entry ---------------------------------------------------------------- */
void __cdecl main(void)
{
    Boot();

    for (;;) {
        WORD b;
        int selfDrawn = 0;
        PumpInput();
        Net_Poll();
        b = GetButtons();

        switch (s_phase) {
        case PH_SPLASH:
            if (++s_splashT > 90 || Pressed(b, s_prev, BTN_A) || Pressed(b, s_prev, BTN_START))
                GotoPhase(PH_MENU);
            break;
        case PH_MENU:        Ph_Menu(b);      break;
        case PH_STATUS:      Ph_Status(b);    break;
        case PH_LOADER_SRC:  Ph_LoaderSrc(b); break;
        case PH_BROWSE:      Ph_Browse(b);    break;
        case PH_BANKMGMT:    Ph_BankMgmt(b);  break;
        case PH_RENAME:      Ph_Rename(b);    break;
        case PH_MGMT_CONFIRM: Ph_MgmtConfirm(b); break;
        case PH_SCRIPTS:     Ph_Scripts(b); break;
        case PH_SCRIPT_CONFIRM: Ph_ScriptConfirm(b); break;
        case PH_SCRIPT_WORK: Ph_ScriptWork(b); break;
        case PH_STAGE:       Ph_Stage(b);     break;
        case PH_CONFIRM:     Ph_Confirm(b);   break;
        case PH_WRITING:     Ph_Writing(b);   break;
        case PH_LOADER_WARN: Ph_LoaderWarn(b); break;
        case PH_LOADER_BACKUP_PROMPT: Ph_LoaderBackupPrompt(b); break;
        case PH_LOADER_BACKINGUP: Ph_LoaderBackingUp(b); break;
        case PH_LOADER_RESTORE_PROMPT: Ph_LoaderRestorePrompt(b); break;
        case PH_LOADER_RESTORING: Ph_LoaderRestoring(b); break;
        case PH_LOADER_FACTORY_WARN: Ph_LoaderFactoryWarn(b); break;
        case PH_LOADER_FACTORY: Ph_LoaderFactory(b); break;
        case PH_RESULT:      Ph_Result(b);    break;
        case PH_UTILITIES:   Ph_Utilities(b); break;
        case PH_UTIL_BANKPICK: Ph_UtilBankPick(b); break;
        case PH_LEDCOLOR: {
            int nx = LedPick_Frame(b, s_prev);
            if (nx >= 0) { RefreshUiLayout(); GotoPhase(nx); }
            selfDrawn = 1;
            break;
        }
        case PH_NET_FETCH:
        case PH_STATUS_FETCH:
            break;
        }

        if (!selfDrawn) DrawPhase();

        /* network fetches are blocking; run them the frame AFTER their screen shows */
        if (s_phase == PH_NET_FETCH || s_phase == PH_STATUS_FETCH) {
            static int armed = 0;
            if (armed) { armed = 0; RunNetFetch(); }
            else armed = 1;
        }

        s_prev = b;
    }
}