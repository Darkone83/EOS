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
#include "input.h"
#include "eos_file.h"
#include "dd_net.h"
#include "eos_net.h"
#include "eos_update.h"
#include "eos_smbus.h"
#include "eos_crc.h"
#include "eos_osk.h"
#include "eos_flash.h"
#include "xboxinternals.h"

#define IMG_CAP   (2 * 1024 * 1024)     /* max image: a 2MB Xenium BIOS */
#define VER_CAP   512

/* ---- phases --------------------------------------------------------------- */
enum {
    PH_SPLASH = 0,
    PH_MENU,
    PH_LOADER_SRC,      /* Internet / Local File */
    PH_BROWSE,          /* file picker (loader-local, BIOS) */
    PH_BANKMGMT,        /* bank management: flash/delete/rename */
    PH_RENAME,          /* OSK rename overlay */
    PH_MGMT_CONFIRM,    /* confirm a bank delete or flash */
    PH_NET_FETCH,       /* blocking download, drawn first */
    PH_STAGE,           /* Update_Pump: stage -> validate */
    PH_CONFIRM,         /* confirm the commit */
    PH_RESULT           /* done / failed / no-update message */
};

/* what the pending net fetch is for */
enum { FETCH_LOADER = 0, FETCH_XBDIAG };

/* ---- state ---------------------------------------------------------------- */
static int        s_phase = PH_SPLASH;
static int        s_splashT = 0;
static WORD       s_prev = 0;

static unsigned char* s_img = 0;        /* image buffer (contiguous) */
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

/* bank management */
static int        s_bankSel = 0;
static int        s_flashTarget = -1;
static int        s_renameTarget = -1;
enum { ACT_NONE = 0, ACT_DELETE, ACT_MGMT_FLASH };
static int        s_pendAct = ACT_NONE;
static int        s_pendIdx = -1;
static char       s_confirmMsg[80];
static char       s_statusMsg[64];
static DWORD      s_statusUntil = 0;

static const char* k_menu[3] = { "Flash Loader", "Bank Management", "Update XbDiag" };

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

static int sizeCodeForLen(int len)
{
    if (len > 512 * 1024) return EOS_BANK_SIZE_1MB; if (len > 256 * 1024) return EOS_BANK_SIZE_512K; return EOS_BANK_SIZE_256K;
}

static void fileToBankName(char* nm, int cap, const char* leaf)
{
    int i = 0, dot = -1; while (leaf[i] && i < cap - 1) { if (leaf[i] == '.') dot = i; nm[i] = leaf[i]; ++i; } if (dot > 0) i = dot; nm[i] = 0;
}

static void buildMgmtRow(char* out, int idx)
{
    int p = 0; out[0] = 0;
    p = appendStr(out, p, Bank_Name(idx)); p = appendStr(out, p, "   ");
    if (Bank_IsBoot(idx))          p = appendStr(out, p, "[BOOT]");
    else if (Bank_IsLocked(idx))   p = appendStr(out, p, "[LOCKED]");
    else if (Bank_Occupied(idx)) { p = appendStr(out, p, "["); p = appendStr(out, p, sizeStr(Bank_SizeCode(idx))); p = appendStr(out, p, " READY]"); }
    else                           p = appendStr(out, p, "[EMPTY]");
}

static void SetMgmtStatus(const char* msg)
{
    int i = 0; while (msg[i] && i < 63) { s_statusMsg[i] = msg[i]; ++i; } s_statusMsg[i] = 0; s_statusUntil = GetTickCount() + 1500;
}

static void GotoPhase(int p) { s_phase = p; }

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
    /* read Eos firmware version from the chip (SMBus regs 0x01-0x03) */
    if (Smb_Present()) {
        BYTE mj = 0, mn = 0, pt = 0; char* vp = s_eosVer;
        Smb_ReadReg(EOS_REG_VER_MAJ, &mj); Smb_ReadReg(EOS_REG_VER_MIN, &mn); Smb_ReadReg(EOS_REG_VER_PAT, &pt);
        { const char* pfx = "Eos "; while (*pfx) *vp++ = *pfx++; }
        if (mj / 10) *vp++ = (char)('0' + mj / 10); *vp++ = (char)('0' + mj % 10); *vp++ = '.';
        if (mn / 10) *vp++ = (char)('0' + mn / 10); *vp++ = (char)('0' + mn % 10); *vp++ = '.';
        if (pt / 10) *vp++ = (char)('0' + pt / 10); *vp++ = (char)('0' + pt % 10); *vp = 0;
    }
    Splash_Init();
    File_MountDrives();
    s_img = (unsigned char*)MmAllocateContiguousMemory(IMG_CAP);
    s_cwd[0] = 0;
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
    EosVer sv, iv; DWORD crc = 0; int rc;

    if (s_fetchWhat == FETCH_LOADER) {
        /* force-update: .ver only for the CRC + display; flash regardless */
        FetchVer("loader.ver", &sv, &crc);            /* best-effort */
        rc = FetchImage("loader.bin");
        if (rc != NET_OK) { s_resultMsg = Net_ErrStr(rc); GotoPhase(PH_RESULT); return; }
        if (!Update_BeginLoader(&s_job, s_img, s_imgLen, crc)) { s_resultMsg = s_job.msg; GotoPhase(PH_RESULT); return; }
        GotoPhase(PH_STAGE);
        return;
    }

    /* FETCH_XBDIAG: version gate first */
    rc = FetchVer("xbdlite.ver", &sv, &crc);
    if (rc != NET_OK) { s_resultMsg = Net_ErrStr(rc); GotoPhase(PH_RESULT); return; }
    s_pendingVer = sv;                                /* stamp this into the bank name on success */
    if (Update_XbDiagInstalled(&iv) && Ver_Compare(sv, iv) <= 0) {
        s_resultMsg = "No update available.";
        GotoPhase(PH_RESULT);
        return;
    }
    rc = FetchImage("xbdlite.bin");
    if (rc != NET_OK) { s_resultMsg = Net_ErrStr(rc); GotoPhase(PH_RESULT); return; }
    if (!Update_BeginXbDiag(&s_job, s_img, s_imgLen, crc)) { s_resultMsg = s_job.msg; GotoPhase(PH_RESULT); return; }
    GotoPhase(PH_STAGE);
}

/* ---- per-phase update ----------------------------------------------------- */
static void Ph_Menu(WORD b)
{
    if (Pressed(b, s_prev, BTN_DPAD_UP))   s_menuSel = (s_menuSel + 2) % 3;
    if (Pressed(b, s_prev, BTN_DPAD_DOWN)) s_menuSel = (s_menuSel + 1) % 3;
    if (Pressed(b, s_prev, BTN_B)) { XLaunchNewImage(NULL, NULL); return; }
    if (Pressed(b, s_prev, BTN_A)) {
        if (s_menuSel == 0) { s_srcSel = 0; GotoPhase(PH_LOADER_SRC); }
        else if (s_menuSel == 1) { s_bankSel = 0; GotoPhase(PH_BANKMGMT); }
        else { s_fetchWhat = FETCH_XBDIAG; GotoPhase(PH_NET_FETCH); }
    }
}

static void Ph_LoaderSrc(WORD b)
{
    if (Pressed(b, s_prev, BTN_DPAD_UP) || Pressed(b, s_prev, BTN_DPAD_DOWN)) s_srcSel ^= 1;
    if (Pressed(b, s_prev, BTN_B)) { GotoPhase(PH_MENU); return; }
    if (Pressed(b, s_prev, BTN_A)) {
        if (s_srcSel == 0) { s_fetchWhat = FETCH_LOADER; GotoPhase(PH_NET_FETCH); }
        else { s_cwd[0] = 0; s_browseSel = 0; Browse_Refresh(); s_menuSel = 0; GotoPhase(PH_BROWSE); }
    }
}

static void DoMgmtFlash(int idx);
static void DoMgmtDelete(int idx);

static void Ph_Browse(WORD b)
{
    if (Pressed(b, s_prev, BTN_DPAD_UP))   s_browseSel = (s_browseSel + s_entryCount - 1) % (s_entryCount > 0 ? s_entryCount : 1);
    if (Pressed(b, s_prev, BTN_DPAD_DOWN)) s_browseSel = (s_browseSel + 1) % (s_entryCount > 0 ? s_entryCount : 1);
    if (Pressed(b, s_prev, BTN_B)) {
        if (s_cwd[0] == 0) { GotoPhase((s_menuSel == 0) ? PH_LOADER_SRC : PH_BANKMGMT); return; }
        /* pop one path element */
        {
            int n = StrLen(s_cwd), i;
            for (i = n - 1; i >= 0; --i) { if (s_cwd[i] == '\\') { s_cwd[i] = 0; break; } if (i == 0) s_cwd[0] = 0; }
        }
        s_browseSel = 0; Browse_Refresh();
        return;
    }
    if (Pressed(b, s_prev, BTN_A) && s_entryCount > 0) {
        EosFileEntry* e = &s_entries[s_browseSel];
        char next[256];
        if (s_cwd[0] == 0) CopyStr(next, sizeof(next), e->name);   /* drive root e.g. "E:" */
        else               JoinPath(next, sizeof(next), s_cwd, e->name);
        if (e->is_dir) { CopyStr(s_cwd, sizeof(s_cwd), next); s_browseSel = 0; Browse_Refresh(); }
        else {
            CopyStr(s_pickedFile, sizeof(s_pickedFile), next);
            if (s_menuSel == 0) {
                /* loader from local file */
                s_imgLen = LoadLocal(s_pickedFile);
                if (s_imgLen <= 0) { s_resultMsg = "Could not read file (too big?)."; GotoPhase(PH_RESULT); return; }
                if (!Update_BeginLoader(&s_job, s_img, s_imgLen, 0)) { s_resultMsg = s_job.msg; GotoPhase(PH_RESULT); return; }
                GotoPhase(PH_STAGE);
            }
            else {
                /* Bank mgmt: flash directly to the selected bank */
                DoMgmtFlash(s_flashTarget);
                GotoPhase(PH_BANKMGMT);
            }
        }
    }
}

static void DoMgmtFlash(int idx)
{
    int cap, got, rc, sc; char nm[EOS_BANK_NAMELEN];
    if (idx < 0 || Bank_IsLocked(idx)) { SetMgmtStatus("Protected bank"); return; }
    cap = Bank_CapacityBytes(idx); if (cap > IMG_CAP) cap = IMG_CAP;
    got = LoadLocal(s_pickedFile);
    if (got < 0) { SetMgmtStatus("Read failed / too big for bank"); return; }
    if (got == 0) { SetMgmtStatus("Empty file"); return; }
    rc = Flash_WriteImage(Bank_Ef(idx), s_img, got);
    if (rc != EOS_FLASH_OK) { SetMgmtStatus("Flash FAILED"); return; }
    sc = sizeCodeForLen(got); Bank_SetOccupied(idx, 1, sc);
    {
        int n = StrLen(s_pickedFile), st = n; while (st > 0 && s_pickedFile[st - 1] != '\\') --st;
        fileToBankName(nm, EOS_BANK_NAMELEN, s_pickedFile + st); if (nm[0]) Bank_SetName(idx, nm);
    }
    rc = Config_Save();
    SetMgmtStatus(rc == EOS_FLASH_OK ? "Flashed OK" : "Flashed; cfg save FAILED");
}

static void DoMgmtDelete(int idx)
{
    int rc;
    if (idx < 0 || Bank_IsLocked(idx)) { SetMgmtStatus("Protected bank"); return; }
    rc = Flash_EraseBank(Bank_Ef(idx));
    if (rc == EOS_FLASH_OK) {
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
        else { s_flashTarget = s_bankSel; s_cwd[0] = 0; s_browseSel = 0; Browse_Refresh(); s_menuSel = 1; GotoPhase(PH_BROWSE); }
        return;
    }
    /* X = Delete (erase) */
    if (Pressed(b, s_prev, BTN_X)) {
        if (Bank_IsLocked(s_bankSel)) { SetMgmtStatus("Cannot delete locked bank"); }
        else if (!Bank_Occupied(s_bankSel)) { SetMgmtStatus("Bank already empty"); }
        else {
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

static void Ph_MgmtConfirm(WORD b)
{
    if (Pressed(b, s_prev, BTN_A)) {
        if (s_pendAct == ACT_DELETE) DoMgmtDelete(s_pendIdx);
        else if (s_pendAct == ACT_MGMT_FLASH) DoMgmtFlash(s_pendIdx);
        s_pendAct = ACT_NONE; s_pendIdx = -1;
        GotoPhase(PH_BANKMGMT);
        return;
    }
    if (Pressed(b, s_prev, BTN_B)) {
        s_pendAct = ACT_NONE; s_pendIdx = -1;
        GotoPhase(PH_BANKMGMT);
        return;
    }
}

static void Ph_Stage(WORD b)
{
    int st = Update_Pump(&s_job);
    if (st == UPD_CONFIRM) { GotoPhase(PH_CONFIRM); return; }
    if (st == UPD_DONE) {
        if (s_job.region == EOS_RGN_XBDIAG) StampXbDiag();   /* record version in bank name */
        s_resultMsg = s_job.msg; GotoPhase(PH_RESULT); return;
    }
    if (st == UPD_FAILED) { s_resultMsg = s_job.msg; GotoPhase(PH_RESULT); return; }
    (void)b;
}

static void Ph_Confirm(WORD b)
{
    if (Pressed(b, s_prev, BTN_A)) { Update_Confirm(&s_job); GotoPhase(PH_STAGE); }
    if (Pressed(b, s_prev, BTN_B)) { Update_Cancel(&s_job); s_resultMsg = "Cancelled."; GotoPhase(PH_RESULT); }
}

static void Ph_Result(WORD b)
{
    if (Pressed(b, s_prev, BTN_A) || Pressed(b, s_prev, BTN_B)) {
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
        Ui_TitleBar("Eos Updater");
        Ui_Menu3D(k_menu, 3, s_menuSel);
        if (s_eosVer[0]) Font_Draw(g_scrW - 200, g_scrH - 70, s_eosVer, EOS_DIM);
        Ui_Footer("A Select   B Exit");
        break;

    case PH_LOADER_SRC: {
        const char* opts[2]; opts[0] = "Internet  (latest from server)"; opts[1] = "Local File  (browse)";
        DrawList("Flash Loader - Source", opts, 2, s_srcSel, "A Select   B Back");
        break;
    }
    case PH_BROWSE: {
        static const char* names[EOS_FILE_MAX_ENTRIES];
        int i, n = s_entryCount;
        for (i = 0; i < n && i < EOS_FILE_MAX_ENTRIES; ++i) names[i] = s_entries[i].name;
        Ui_TitleBar((s_menuSel == 0) ? "Loader - Pick File" : "BIOS - Pick File");
        {
            int y = 140, rowH = 34, gap = 6, x = 70, w = g_scrW - 140, top = s_browseSel - 6;
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
        Ui_Footer("A Flash   X Delete   Y Rename   B Back");
        break;
    }
    case PH_RENAME:
        Ui_TitleBar("RENAME BANK");
        Osk_Draw();
        Ui_Footer("Start Confirm   Back Cancel");
        break;
    case PH_MGMT_CONFIRM:
        Ui_TitleBar("CONFIRM");
        Font_DrawCentered(0, g_scrW, 220, s_confirmMsg, EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 260, "This cannot be undone.", EOS_DIM);
        Ui_Footer("A Yes   B No");
        break;
    case PH_NET_FETCH:
        Ui_TitleBar((s_fetchWhat == FETCH_LOADER) ? "Flash Loader" : "Update XbDiag");
        Font_DrawCentered(0, g_scrW, 240, "Contacting server...", EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 280, EOS_NET_HOST, EOS_DIM);
        break;

    case PH_STAGE:
        Ui_TitleBar("Updating");
        Draw_ProgressBar(Update_Progress(&s_job), s_job.msg);
        break;

    case PH_CONFIRM:
        Ui_TitleBar("Confirm");
        Font_DrawCentered(0, g_scrW, 220, Update_ConfirmText(&s_job), EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 300, "A Yes, write flash      B Cancel", EOS_PURPLE);
        break;

    case PH_RESULT:
        Ui_TitleBar("Result");
        Font_DrawCentered(0, g_scrW, 250, s_resultMsg, EOS_WHITE);
        Ui_Footer("A / B  Back to menu");
        break;
    }

    /* splash overlay for OSK etc. would go here if used */
    Gfx_End();
}

/* ---- entry ---------------------------------------------------------------- */
void __cdecl main(void)
{
    Boot();

    for (;;) {
        WORD b;
        PumpInput();
        Net_Poll();
        b = GetButtons();

        switch (s_phase) {
        case PH_SPLASH:
            if (++s_splashT > 90 || Pressed(b, s_prev, BTN_A) || Pressed(b, s_prev, BTN_START))
                GotoPhase(PH_MENU);
            break;
        case PH_MENU:        Ph_Menu(b);      break;
        case PH_LOADER_SRC:  Ph_LoaderSrc(b); break;
        case PH_BROWSE:      Ph_Browse(b);    break;
        case PH_BANKMGMT:    Ph_BankMgmt(b);  break;
        case PH_RENAME:      Ph_Rename(b);    break;
        case PH_MGMT_CONFIRM: Ph_MgmtConfirm(b); break;
        case PH_STAGE:       Ph_Stage(b);     break;
        case PH_CONFIRM:     Ph_Confirm(b);   break;
        case PH_RESULT:      Ph_Result(b);    break;
        case PH_NET_FETCH:   /* handled after draw */ break;
        }

        DrawPhase();

        /* the network fetch is blocking; run it the frame AFTER its screen shows */
        if (s_phase == PH_NET_FETCH) {
            static int armed = 0;
            if (armed) { armed = 0; RunNetFetch(); }
            else armed = 1;
        }

        s_prev = b;
    }
}