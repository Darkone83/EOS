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
#include "eos_flash.h"
#include "input.h"
#include "eos_file.h"
#include "dd_net.h"
#include "eos_net.h"
#include "eos_update.h"
#include "eos_smbus.h"
#include "eos_crc.h"
#include "eos_osk.h"
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
    PH_STAGE,           /* Update_Pump: verify image (RAM) -> confirm */
    PH_CONFIRM,         /* confirm the write */
    PH_WRITING,         /* renders 'Writing flash...' then does the blocking write */
    PH_RESULT,          /* done / failed / no-update message */
    PH_UTILITIES,       /* utilities: backup/restore, clear xbdiag/settings/names */
    PH_UTIL_BANKPICK    /* pick a bank to backup/restore */
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
static int        s_writePrimed = 0;   /* PH_WRITING: 0=render frame, 1=do write */
static int        s_renameTarget = -1;
enum {
    ACT_NONE = 0, ACT_DELETE, ACT_MGMT_FLASH,
    ACT_CLEAR_XBDIAG, ACT_CLEAR_SETTINGS, ACT_CLEAR_NAMES,
    ACT_BACKUP_BANK, ACT_RESTORE_BANK
};
static int        s_utilSel = 0;    /* selected row in the Utilities menu */
static int        s_utilBankSel = 0;/* selected bank in the backup/restore picker */
static int        s_utilMode = 0;   /* 0 = backup, 1 = restore (for the bank picker) */
static int        s_pendAct = ACT_NONE;
static int        s_pendIdx = -1;
static char       s_confirmMsg[80];
static char       s_statusMsg[64];
static DWORD      s_statusUntil = 0;

static const char* k_menu[4] = { "Flash Loader", "Bank Management", "Update XbDiag", "Utilities" };

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

/* Build a filesystem-safe "<name>.bin" from a bank name. Spaces -> '_', drops
   characters that are illegal in FATX filenames. Falls back to "bank.bin". */
static void fileToBackupLeaf(char* out, int cap, const char* name)
{
    int i = 0, o = 0;
    while (name[i] && o < cap - 5) {
        char c = name[i++];
        if (c == ' ') c = '_';
        else if (c == '\\' || c == '/' || c == ':' || c == '*' || c == '?' ||
            c == '"' || c == '<' || c == '>' || c == '|') continue;
        out[o++] = c;
    }
    if (o == 0) { out[o++] = 'b'; out[o++] = 'a'; out[o++] = 'n'; out[o++] = 'k'; }
    out[o++] = '.'; out[o++] = 'b'; out[o++] = 'i'; out[o++] = 'n'; out[o] = 0;
}

static void buildMgmtRow(char* out, int idx)
{
    int p = 0; out[0] = 0;
    p = appendStr(out, p, Bank_Name(idx)); p = appendStr(out, p, "   ");
    if (Bank_IsBoot(idx)) { p = appendStr(out, p, "[BOOT]"); return; }
    if (Bank_IsLocked(idx)) { p = appendStr(out, p, "[LOCKED]"); return; }

    /* Descriptor-aware: an ext anchor shows its true size; a shadow slot is
       greyed as consumed by a preceding oversized bank. */
    {
        unsigned char ef = Bank_Ef(idx);
        if (ef >= 0x3 && ef <= 0x6) {
            EosLayout lay; int dslot = (int)(ef - 0x3);
            if (Desc_Load(&lay) && lay.valid) {
                int st = lay.slot[dslot].state;
                if (st == EOS_SLOT_SHADOW) { p = appendStr(out, p, "[-- USED --]"); return; }
                if (st == EOS_SLOT_ANCHOR) {
                    p = appendStr(out, p, "[");
                    p = appendStr(out, p, sizeStr((lay.slot[dslot].sizeCode == EOS_SZC_1MB) ? EOS_BANK_SIZE_1MB : EOS_BANK_SIZE_512K));
                    p = appendStr(out, p, " READY]");
                    return;
                }
            }
        }
    }

    if (Bank_Occupied(idx)) { p = appendStr(out, p, "["); p = appendStr(out, p, sizeStr(Bank_SizeCode(idx))); p = appendStr(out, p, " READY]"); }
    else                    p = appendStr(out, p, "[EMPTY]");
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
    File_MountDrives();
    s_img = (unsigned char*)MmAllocateContiguousMemory(IMG_CAP);
    s_cwd[0] = 0;
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
    if (Pressed(b, s_prev, BTN_DPAD_UP))   s_menuSel = (s_menuSel + 3) % 4;
    if (Pressed(b, s_prev, BTN_DPAD_DOWN)) s_menuSel = (s_menuSel + 1) % 4;
    if (Pressed(b, s_prev, BTN_B)) { Smb_SetLedMode(0); XLaunchNewImage(NULL, NULL); return; }
    if (Pressed(b, s_prev, BTN_A)) {
        if (s_menuSel == 0) { s_srcSel = 0; GotoPhase(PH_LOADER_SRC); }
        else if (s_menuSel == 1) { s_bankSel = 0; GotoPhase(PH_BANKMGMT); }
        else if (s_menuSel == 2) { s_fetchWhat = FETCH_XBDIAG; GotoPhase(PH_NET_FETCH); }
        else { s_utilSel = 0; GotoPhase(PH_UTILITIES); }
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
    int got, rc, sc; char nm[EOS_BANK_NAMELEN];
    if (idx < 0 || Bank_IsLocked(idx)) { SetMgmtStatus("Protected bank"); return; }
    /* Load up to a full 2MB so large (512K/1MB) images are not truncated to the
       256K bank capacity; DoMgmtFlash decides the path by the actual size. */
    got = LoadLocal(s_pickedFile);
    if (got < 0) { SetMgmtStatus("Read failed / too big for bank"); return; }
    if (got == 0) { SetMgmtStatus("Empty file"); return; }

    sc = sizeCodeForLen(got);

    /* Large BIOS (512K/1MB) -> ext region + descriptor auto-place. The selected
       bank is a hint; it lands in the first free, correctly-aligned slot run. */
    if (got > 256 * 1024) {
        s_progTitle = (got > 512 * 1024) ? "Writing 1MB Bank" : "Writing 512K Bank";
        Flash_SetProgressCb(flashProgress);
        rc = Update_ExtBankFlash(s_img, got);
        Flash_SetProgressCb(0);
        if (rc == EOS_FLASH_VERIFY) { SetMgmtStatus("No free slot for this size"); return; }
        if (rc == EOS_FLASH_REFUSED) { SetMgmtStatus("Descriptor write FAILED");   return; }
        if (rc != EOS_FLASH_OK) { SetMgmtStatus("Ext-region flash FAILED");   return; }
        /* name the actual anchor bank (Update_ExtBankFlash marked it occupied) */
        {
            int n = StrLen(s_pickedFile), st = n; while (st > 0 && s_pickedFile[st - 1] != '\\') --st;
            fileToBankName(nm, EOS_BANK_NAMELEN, s_pickedFile + st);
        }
        rc = Config_Save();
        SetMgmtStatus(rc == EOS_FLASH_OK ? "Large bank flashed" : "Flashed; cfg save FAILED");
        return;
    }

    /* 256K -> normal direct verified write into this specific bank. */
    s_progTitle = "Writing Bank";
    Flash_SetProgressCb(flashProgress);
    rc = Flash_WriteImageVerified(Bank_Ef(idx), s_img, got);
    Flash_SetProgressCb(0);
    if (rc == EOS_FLASH_VERIFY) { SetMgmtStatus("Verify FAILED - reflash"); return; }
    if (rc != EOS_FLASH_OK) { SetMgmtStatus("Flash FAILED"); return; }
    Bank_SetOccupied(idx, 1, sc);
    /* record NATIVE in the descriptor so a later large-bank auto-place does not
       overwrite this slot. */
    {
        unsigned char ef = Bank_Ef(idx);
        if (ef >= 0x3 && ef <= 0x6) {
            EosLayout lay; int dslot = (int)(ef - 0x3);
            if (!Desc_Load(&lay) || !lay.valid) Desc_InitEmpty(&lay);
            lay.slot[dslot].state = EOS_SLOT_NATIVE;
            lay.slot[dslot].sizeCode = EOS_SZC_256K;
            lay.slot[dslot].physBase = 0;
            Desc_Save(&lay);
        }
    }
    {
        int n = StrLen(s_pickedFile), st = n; while (st > 0 && s_pickedFile[st - 1] != '\\') --st;
        fileToBankName(nm, EOS_BANK_NAMELEN, s_pickedFile + st); if (nm[0]) Bank_SetName(idx, nm);
    }
    rc = Config_Save();
    SetMgmtStatus(rc == EOS_FLASH_OK ? "Flashed OK" : "Flashed; cfg save FAILED");
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

    /* Normal 256K bank. Also clear a NATIVE descriptor entry if present. */
    rc = Flash_EraseBank(Bank_Ef(idx));
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

/* ---- Utilities: backup/restore + clears --------------------------------- */

static char s_utilStatus[64] = "";
static void SetUtilStatus(const char* m) { int i = 0; while (m[i] && i < 63) { s_utilStatus[i] = m[i]; ++i; } s_utilStatus[i] = 0; }


/* First writable drive root ("E:", "F:", "G:") for saving a backup. Skips the
   read-only disc drive (D:). */
static int firstWritableDrive(char* out, int cap)
{
    EosFileEntry drv[8];
    int n = File_ListDrives(drv, 8), i;
    for (i = 0; i < n; ++i) {
        if (drv[i].name[0] == 'D') continue;   /* skip the read-only disc */
        CopyStr(out, cap, drv[i].name);
        return 1;
    }
    if (n > 0) { CopyStr(out, cap, drv[0].name); return 1; }
    return 0;
}

/* Read a bank's full image into s_img. For an ext anchor the bytes live in the
   new region (bank 0x0) at the half offset; for a native/256K bank they are in
   the bank itself. Returns the byte count, or -1. */
static int readBankImage(int idx, int* outLen)
{
    unsigned char ef = Bank_Ef(idx);
    int len = 256 * 1024, srcEf = (int)ef, basePage = 0, pages, pg, rc;

    if (ef >= 0x3 && ef <= 0x6) {
        EosLayout lay; int dslot = (int)(ef - 0x3);
        if (Desc_Load(&lay) && lay.valid && lay.slot[dslot].state == EOS_SLOT_ANCHOR) {
            unsigned int base = lay.slot[dslot].physBase;
            len = (lay.slot[dslot].sizeCode == EOS_SZC_1MB) ? (1024 * 1024) : (512 * 1024);
            srcEf = EOS_BANK_NEWREGION;                          /* bank 0x0 */
            basePage = (int)((base - EOS_NEWRGN_BASE) / 256);     /* half offset in pages */
        }
        else if (Desc_Load(&lay) && lay.valid && lay.slot[dslot].state == EOS_SLOT_SHADOW) {
            return -1;   /* a shadow has no image of its own */
        }
    }

    pages = len / 256;
    for (pg = 0; pg < pages; ++pg) {
        rc = Flash_ReadPage(srcEf, basePage + pg, s_img + pg * 256);
        if (rc != EOS_FLASH_OK) return -1;
    }
    if (outLen) *outLen = len;
    return len;
}

static void DoBackupBank(int idx)
{
    char drive[16], path[300], leaf[EOS_BANK_NAMELEN + 8];
    int len = 0, n;
    if (idx < 0 || !Bank_Occupied(idx)) { SetUtilStatus("Bank is empty"); return; }
    if (readBankImage(idx, &len) < 0) { SetUtilStatus("Read failed"); return; }
    if (!firstWritableDrive(drive, sizeof(drive))) { SetUtilStatus("No writable drive"); return; }

    /* leaf = "<bankname>.bin", sanitized to the bank name (already filesystem-safe) */
    fileToBackupLeaf(leaf, sizeof(leaf), Bank_Name(idx));
    JoinPath(path, sizeof(path), drive, leaf);

    n = File_WriteFrom(path, s_img, len);
    if (n == len) SetUtilStatus("Backup saved");
    else          SetUtilStatus("Write failed");
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
    Bank_ResetToFactory();             /* restore factory labels, keep flashed BIOSes */
    rc = Config_Save();
    SetUtilStatus(rc == EOS_FLASH_OK ? "Names cleared" : "Saved names FAILED");
}

static void Ph_MgmtConfirm(WORD b)
{
    if (Pressed(b, s_prev, BTN_A)) {
        int fromUtil = 0;
        if (s_pendAct == ACT_DELETE) DoMgmtDelete(s_pendIdx);
        else if (s_pendAct == ACT_MGMT_FLASH) DoMgmtFlash(s_pendIdx);
        else if (s_pendAct == ACT_CLEAR_XBDIAG) { DoClearXbDiag();   fromUtil = 1; }
        else if (s_pendAct == ACT_CLEAR_SETTINGS) { DoClearSettings(); fromUtil = 1; }
        else if (s_pendAct == ACT_CLEAR_NAMES) { DoClearNames();    fromUtil = 1; }
        s_pendAct = ACT_NONE; s_pendIdx = -1;
        GotoPhase(fromUtil ? PH_UTILITIES : PH_BANKMGMT);
        return;
    }
    if (Pressed(b, s_prev, BTN_B)) {
        int fromUtil = (s_pendAct == ACT_CLEAR_XBDIAG || s_pendAct == ACT_CLEAR_SETTINGS || s_pendAct == ACT_CLEAR_NAMES);
        s_pendAct = ACT_NONE; s_pendIdx = -1;
        GotoPhase(fromUtil ? PH_UTILITIES : PH_BANKMGMT);
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
        case UTIL_BACKUP:  s_utilMode = 0; s_utilBankSel = 0; GotoPhase(PH_UTIL_BANKPICK); break;
        case UTIL_RESTORE: s_utilMode = 1; s_utilBankSel = 0; GotoPhase(PH_UTIL_BANKPICK); break;
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
            s_flashTarget = s_utilBankSel; s_cwd[0] = 0; s_browseSel = 0; Browse_Refresh();
            s_menuSel = 1; GotoPhase(PH_BROWSE);   /* s_menuSel=1 routes the browse pick to DoMgmtFlash */
        }
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
    if (Pressed(b, s_prev, BTN_A)) { Update_Confirm(&s_job); s_writePrimed = 0; GotoPhase(PH_WRITING); }
    if (Pressed(b, s_prev, BTN_B)) { Update_Cancel(&s_job); s_resultMsg = "Cancelled."; GotoPhase(PH_RESULT); }
}

static void Ph_Writing(WORD b)
{
    int st;
    (void)b;
    /* First visit: let this frame render the 'Writing flash...' screen before
       we enter the multi-second blocking flash write on the next frame. */
    if (!s_writePrimed) { s_writePrimed = 1; return; }
    s_progTitle = (s_job.region == EOS_RGN_XBDIAG) ? "Writing XbDiag" : "Writing Loader";
    Flash_SetProgressCb(flashProgress);
    st = Update_Pump(&s_job);   /* UPD_COMMITTING -> blocking verified write */
    Flash_SetProgressCb(0);
    if (st == UPD_DONE) {
        if (s_job.region == EOS_RGN_XBDIAG) StampXbDiag();
        s_resultMsg = s_job.msg; GotoPhase(PH_RESULT); return;
    }
    if (st == UPD_FAILED) { s_resultMsg = s_job.msg; GotoPhase(PH_RESULT); return; }
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
        Ui_Menu3D(k_menu, 4, s_menuSel);
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
    case PH_WRITING:
        Ui_TitleBar("Updating");
        Font_DrawCentered(0, g_scrW, 240, "Writing flash - do NOT power off...", EOS_WHITE);
        Font_DrawCentered(0, g_scrW, 300, "Verifying every page (this takes ~1 min)", EOS_PURPLE);
        break;

    case PH_RESULT:
        Ui_TitleBar("Result");
        Font_DrawCentered(0, g_scrW, 250, s_resultMsg, EOS_WHITE);
        Ui_Footer("A / B  Back to menu");
        break;
    case PH_UTILITIES: {
        static const char* k_util[UTIL_COUNT] = {
            "Backup Bank -> Drive", "Restore Bank <- Drive",
            "Clear XbDiag Bank", "Clear Settings", "Clear Bank Names"
        };
        Ui_TitleBar("UTILITIES");
        Ui_Menu3D(k_util, UTIL_COUNT, s_utilSel);
        if (s_utilStatus[0])
            Font_DrawCentered(0, g_scrW, g_scrH - 94, s_utilStatus, EOS_PURPLE);
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
        Ui_Footer(s_utilMode == 0 ? "A Backup   B Back" : "A Pick File   B Back");
        break;
    }
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
        case PH_WRITING:     Ph_Writing(b);   break;
        case PH_RESULT:      Ph_Result(b);    break;
        case PH_UTILITIES:   Ph_Utilities(b); break;
        case PH_UTIL_BANKPICK: Ph_UtilBankPick(b); break;
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