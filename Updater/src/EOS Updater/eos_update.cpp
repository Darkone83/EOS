// eos_update.cpp -- see eos_update.h.
#include <xtl.h>
#include "eos_update.h"

/* Canonical staged image length. The FPGA datapath (scr addr, crc_len,
   image_len) is 21-bit and the served image tops out at eos_sdram_backend's
   LENGTH = 0x1C0000; the top 256K of a 2MB image is empty. Staging/CRC/commit
   all use this so a full 2MB file does not overflow the 21-bit length to 0. */
#define EOS_IMAGE_LEN  0x1C0000
#include "eos_smbus.h"
#include "eos_stage.h"
#include "eos_flash.h"
#include "eos_crc.h"
#include "eos_bank.h"
#include "eos_descriptor.h"

#define XBDIAG_EF  0x0D          /* XbDiag lives in bank 0xD */
#define LOADER_EF  0x0E          /* loader full-image commit bank (base 0, phys 0x200000) */

   /* Map an update region to the bankEf the direct flash engine writes. The FPGA
      translates bankEf -> phys via bank_base(): BANK banks are base 0 (256K), the
      loader is bank 0xE (base 0, full image -> phys 0x200000), XbDiag is bank 0xD
      (base 0x200000 -> phys 0x400000). Same targets the SDRAM commit used. */
      /* small no-CRT helpers to format the failing page into the status line */
static char s_msgbuf[64];
static int  msg_append(char* b, int p, const char* s)
{
    int i = 0; while (s[i] && p < 63) b[p++] = s[i++]; b[p] = 0; return p;
}
static int  msg_append_int(char* b, int p, int v)
{
    char tmp[12]; int n = 0;
    if (v < 0) v = 0;
    do { tmp[n++] = (char)('0' + (v % 10)); v /= 10; } while (v && n < 11);
    while (n > 0 && p < 63) b[p++] = tmp[--n];
    b[p] = 0; return p;
}

static int region_bank_ef(const UpdateJob* j)
{
    switch (j->region) {
    case EOS_RGN_LOADER: return LOADER_EF;
    case EOS_RGN_XBDIAG: return XBDIAG_EF;
    case EOS_RGN_BANK:   return (int)(j->bank & 0x0F);
    default:             return -1;
    }
}

#define STAGE_CHUNK   16384      /* bytes streamed per Pump (UI stays responsive) */
#define VAL_TIMEOUT   8000       /* ms to wait for VALIDATE (CRC over up to 2MB) */
#define COMMIT_TIMEOUT 30000     /* ms to wait for COMMIT (erase + program) */

/* ---- versioning ----------------------------------------------------------- */
int Ver_Compare(EosVer a, EosVer b)
{
    if (a.maj != b.maj) return (a.maj < b.maj) ? -1 : 1;
    if (a.min != b.min) return (a.min < b.min) ? -1 : 1;
    if (a.pat != b.pat) return (a.pat < b.pat) ? -1 : 1;
    return 0;
}

static BOOL is_digit(char c) { return (c >= '0' && c <= '9'); }

/* parse up to 3 dotted decimals starting at *pp; advances *pp */
static void parse_ver(const char** pp, const char* end, EosVer* v)
{
    const char* p = *pp;
    int  field = 0;
    BYTE vals[3];
    vals[0] = vals[1] = vals[2] = 0;
    while (p < end && field < 3) {
        int acc = 0;
        if (!is_digit(*p)) break;
        while (p < end && is_digit(*p)) { acc = acc * 10 + (*p - '0'); ++p; }
        vals[field++] = (BYTE)acc;
        if (p < end && *p == '.') ++p; else break;
    }
    v->maj = vals[0]; v->min = vals[1]; v->pat = vals[2];
    *pp = p;
}

/* parse a hex value (with or without 0x) starting at *pp */
static DWORD parse_hex(const char** pp, const char* end)
{
    const char* p = *pp;
    DWORD acc = 0;
    if (p + 1 < end && p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
    while (p < end) {
        char c = *p; int d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else break;
        acc = (acc << 4) | (DWORD)d; ++p;
    }
    *pp = p;
    return acc;
}

/* case-insensitive match of key at p; returns ptr past key+'=' or 0 */
static const char* match_key(const char* p, const char* end, const char* key)
{
    int i = 0;
    while (key[i]) {
        char a, b;
        if (p + i >= end) return 0;
        a = p[i]; b = key[i];
        if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
        if (a != b) return 0;
        ++i;
    }
    p += i;
    while (p < end && (*p == ' ' || *p == '\t' || *p == '=')) ++p;
    return p;
}

BOOL Ver_Parse(const char* text, int len, EosVer* ver_out, DWORD* crc_out)
{
    const char* p = text;
    const char* end = text + len;
    BOOL got_ver = FALSE;
    EosVer v; DWORD crc = 0;
    v.maj = v.min = v.pat = 0;
    if (!text || len <= 0) return FALSE;

    while (p < end) {
        const char* k;
        if ((k = match_key(p, end, "version")) != 0) { parse_ver(&k, end, &v); got_ver = TRUE; p = k; }
        else if ((k = match_key(p, end, "crc32")) != 0) { crc = parse_hex(&k, end); p = k; }
        else ++p;
    }
    if (ver_out) *ver_out = v;
    if (crc_out) *crc_out = crc;
    return got_ver;
}

/* ---- version from the bank name ------------------------------------------ */
BOOL Ver_ParseName(const char* name, EosVer* out)
{
    const char* p;
    const char* end;
    EosVer v;
    v.maj = v.min = v.pat = 0;
    if (out) *out = v;
    if (!name) return FALSE;
    end = name; while (*end) ++end;
    for (p = name; p < end; ++p) {
        if (is_digit(*p)) {
            const char* q = p;
            while (q < end && is_digit(*q)) ++q;
            if (q < end && *q == '.') {          /* a dotted version, not a stray digit */
                const char* r = p;
                parse_ver(&r, end, &v);
                if (out) *out = v;
                return TRUE;
            }
        }
    }
    return FALSE;
}

void Ver_Format(EosVer v, char* buf, int cap)
{
    int at = 0, k;
    unsigned char parts[3];
    parts[0] = v.maj; parts[1] = v.min; parts[2] = v.pat;
    for (k = 0; k < 3; ++k) {
        int val = parts[k];
        char tmp[4]; int n = 0;
        if (k > 0 && at < cap - 1) buf[at++] = '.';
        if (val == 0) { if (at < cap - 1) buf[at++] = '0'; }
        else {
            while (val > 0 && n < 3) { tmp[n++] = (char)('0' + val % 10); val /= 10; }
            while (n > 0 && at < cap - 1) buf[at++] = tmp[--n];
        }
    }
    if (at < cap) buf[at] = 0; else if (cap > 0) buf[cap - 1] = 0;
}

/* ---- installed XbDiag version (from the bank name) ------------------------ */
BOOL Update_XbDiagInstalled(EosVer* out)
{
    int n = Bank_Count(), i;
    if (out) { out->maj = 0; out->min = 0; out->pat = 0; }
    for (i = 0; i < n; ++i) {
        if ((Bank_Ef(i) & 0x0F) == XBDIAG_EF) {
            if (!Bank_Occupied(i)) return FALSE;         /* bank empty = not installed */
            return Ver_ParseName(Bank_Name(i), out);     /* version parsed from the name */
        }
    }
    return FALSE;                                        /* no XbDiag bank in the table */
}

/* ---- job setup ------------------------------------------------------------ */
static BOOL begin_common(UpdateJob* j, BYTE region, BYTE bank,
    const unsigned char* img, int len, DWORD crc)
{
    if (!j || !img || len <= 0) return FALSE;
    if (len > EOS_IMAGE_LEN) len = EOS_IMAGE_LEN;   /* fit 21-bit field; empty top skipped */
    j->region = region;
    j->bank = bank;
    j->image = img;
    j->len = len;
    j->crc = crc ? crc : Crc_Buffer(img, len);   /* compute if not supplied */
    j->state = UPD_STAGING;
    j->staged = 0;
    j->last_status = 0;
    j->confirmed = 0;
    j->msg = "Staging image...";

    /* Tolerant presence probe up front so a busy-bus fluke doesn't abort. The
       actual write is a direct chunked+verified flash push (see Update_Pump),
       NOT the SDRAM scratch/ARM/commit pipeline -- so no ARM here. */
    if (!Smb_Present()) { j->state = UPD_FAILED; j->msg = "Eos not detected on SMBus."; return FALSE; }
    return TRUE;
}

BOOL Update_BeginLoader(UpdateJob* j, const unsigned char* img, int len, DWORD crc)
{
    return begin_common(j, EOS_RGN_LOADER, 0, img, len, crc);
}

BOOL Update_BeginBios(UpdateJob* j, int bankEf, const unsigned char* img, int len)
{
    /* local BIOS: no .ver, CRC computed from the buffer */
    return begin_common(j, EOS_RGN_BANK, (BYTE)(bankEf & 0x0F), img, len, 0);
}

BOOL Update_BeginXbDiag(UpdateJob* j, const unsigned char* img, int len, DWORD crc)
{
    return begin_common(j, EOS_RGN_XBDIAG, 0, img, len, crc);
}

/* ---- state machine -------------------------------------------------------- */
/* Bank table index -> descriptor slot (0..3), or -1 if not a user bank. User
   banks have EF 0x3..0x6 -> slot 0..3. (Mirrors the loader's descSlotForBank.) */
static int ext_slot_for_index(int idx)
{
    unsigned char ef;
    if (idx < 0) return -1;
    ef = Bank_Ef(idx);
    if (ef >= 0x3 && ef <= 0x6) return (int)(ef - 0x3);
    return -1;
}

/* Commit a large (512K/1MB) BANK image into the ext region with descriptor
   auto-placement -- the same model the loader uses. The user's selected bank is
   only a hint; the image lands in the first free, correctly-aligned slot run.
   Returns EOS_FLASH_OK, or EOS_FLASH_VERIFY (no room) / EOS_FLASH_REFUSED
   (descriptor write failed) / EOS_FLASH_TIMEOUT (ext-region flash failed). */
int Update_ExtBankFlash(const unsigned char* image, int len)
{
    EosLayout lay;
    int  szc = (len > 0x80000) ? EOS_SZC_1MB : EOS_SZC_512K;
    int  need = Desc_SlotsFor(szc);
    int  slot = -1, cand, anchorTbl, i;
    unsigned int nrbase;
    int  startPage, rc;

    if (!Desc_Load(&lay) || !lay.valid) Desc_InitEmpty(&lay);

    /* auto-place: 1MB needs all four slots free; 512K takes the first free even
       pair (0-1 or 2-3), matching the two physical new-region halves. */
    if (szc == EOS_SZC_1MB) {
        int allFree = 1;
        for (i = 0; i < EOS_DESC_SLOTS; ++i)
            if (lay.slot[i].state != EOS_SLOT_FREE) { allFree = 0; break; }
        if (allFree) slot = 0;
    }
    else {
        for (cand = 0; cand <= 2; cand += 2)
            if (lay.slot[cand].state == EOS_SLOT_FREE &&
                lay.slot[cand + 1].state == EOS_SLOT_FREE) {
                slot = cand; break;
            }
    }
    if (slot < 0) return EOS_FLASH_VERIFY;   /* no room -> mapped to a clear msg */

    /* new-region offset: slots 0/1 -> +0, slots 2/3 -> +512K; 1MB -> +0 */
    nrbase = (szc == EOS_SZC_1MB) ? EOS_NEWRGN_BASE
        : (slot >= 2) ? (EOS_NEWRGN_BASE + EOS_NEWRGN_HALF)
        : EOS_NEWRGN_BASE;
    startPage = (int)((nrbase - EOS_NEWRGN_BASE) / 256);

    rc = Flash_WriteImageAtNoSync(EOS_BANK_NEWREGION, startPage, image, len);
    if (rc != EOS_FLASH_OK) return EOS_FLASH_TIMEOUT;

    /* page it into SDRAM so the bank is launchable without a cold boot */
    Flash_SyncNewRegion();

    /* descriptor: anchor + shadows */
    lay.slot[slot].state = EOS_SLOT_ANCHOR;
    lay.slot[slot].sizeCode = (unsigned char)szc;
    lay.slot[slot].physBase = nrbase;
    for (i = 1; i < need; ++i) {
        lay.slot[slot + i].state = EOS_SLOT_SHADOW;
        lay.slot[slot + i].sizeCode = EOS_SZC_256K;
        lay.slot[slot + i].physBase = 0;
    }
    if (Desc_Save(&lay) != EOS_FLASH_OK) return EOS_FLASH_REFUSED;

    /* mark the ACTUAL anchor bank occupied (the auto-chosen slot, not the
       bank the user selected). anchor bank EF = 0x3 + slot. */
    anchorTbl = Bank_IndexForEf((unsigned char)(0x3 + slot));
    if (anchorTbl >= 0)
        Bank_SetOccupied(anchorTbl, 1, (szc == EOS_SZC_1MB) ? EOS_BANK_SIZE_1MB : EOS_BANK_SIZE_512K);

    return EOS_FLASH_OK;
}

/* Job-pump wrapper: the committing state calls this with the staged image. */
static int commit_ext_bank(UpdateJob* j)
{
    return Update_ExtBankFlash(j->image, j->len);
}

int Update_Pump(UpdateJob* j)
{
    if (!j) return UPD_FAILED;

    switch (j->state) {
        /* STAGING: the image is already in host RAM (j->image). Optionally verify
           its CRC against the .ver here as an identity check, then go straight to
           the confirm gate. No SDRAM scratch, no ARM. */
    case UPD_STAGING: {
        if (j->crc != 0) {
            DWORD calc = Crc_Buffer(j->image, j->len);
            if (calc != j->crc) {
                j->state = UPD_FAILED; j->msg = "CRC mismatch - download bad."; break;
            }
        }
        j->staged = j->len;                 /* progress bar shows complete */
        j->state = UPD_CONFIRM;
        j->msg = "Verified. Confirm to flash.";
        break;
    }
    case UPD_VALIDATING:                    /* retained for enum compat; unused */
        j->state = UPD_CONFIRM;
        break;
    case UPD_CONFIRM:
        if (j->confirmed) { j->state = UPD_COMMITTING; j->msg = "Writing flash..."; }
        break;
        /* COMMITTING: the real write. Direct, chunked, per-page verified flash push
           via the 0xEC/0xED engine -- the same reliable path manual flash uses. */
    case UPD_COMMITTING: {
        int ef = region_bank_ef(j);
        int rc;
        if (ef < 0) { j->state = UPD_FAILED; j->msg = "Bad target region."; break; }

        /* Large BANK image (512K/1MB) -> ext region + descriptor auto-place, the
           same model the loader uses. Anything <=256K (or a non-BANK region) takes
           the normal direct verified write. */
        if (j->region == EOS_RGN_BANK && j->len > 0x40000) {
            rc = commit_ext_bank(j);
            if (rc == EOS_FLASH_OK) { j->state = UPD_DONE; j->msg = "Done. Large bank flashed."; }
            else if (rc == EOS_FLASH_VERIFY) { j->state = UPD_FAILED; j->msg = "No free slot for this size."; }
            else if (rc == EOS_FLASH_REFUSED) { j->state = UPD_FAILED; j->msg = "Descriptor write failed."; }
            else { j->state = UPD_FAILED; j->msg = "Ext-region flash failed."; }
            break;
        }

        rc = Flash_WriteImageVerified(ef, j->image, j->len);
        if (rc == EOS_FLASH_OK) {
            /* record a native 256K in the descriptor so a later large-bank
               auto-place will not overwrite this slot. */
            int di = Bank_IndexForEf((BYTE)ef);
            int dslot = ext_slot_for_index(di);
            if (dslot >= 0) {
                EosLayout lay;
                if (!Desc_Load(&lay) || !lay.valid) Desc_InitEmpty(&lay);
                lay.slot[dslot].state = EOS_SLOT_NATIVE;
                lay.slot[dslot].sizeCode = EOS_SZC_256K;
                lay.slot[dslot].physBase = 0;
                Desc_Save(&lay);
            }
            j->state = UPD_DONE; j->msg = "Done. Flash updated.";
        }
        else if (rc == EOS_FLASH_VERIFY) {
            int p = 0;
            p = msg_append(s_msgbuf, p, "Verify failed at page ");
            p = msg_append_int(s_msgbuf, p, Flash_LastFailPage());
            j->state = UPD_FAILED; j->msg = s_msgbuf;
        }
        else if (rc == EOS_FLASH_REFUSED) { j->state = UPD_FAILED; j->msg = "Flash refused (bad target)."; }
        else { j->state = UPD_FAILED; j->msg = "Flash timeout (bus/FPGA)."; }
        break;
    }
    case UPD_IDLE:
    case UPD_DONE:
    case UPD_FAILED:
    default:
        break;
    }
    return j->state;
}

void Update_Confirm(UpdateJob* j)
{
    if (j && j->state == UPD_CONFIRM) j->confirmed = 1;
}

void Update_Cancel(UpdateJob* j)
{
    if (!j) return;
    Smb_Clear();                 /* disarm + invalidate the staged image */
    j->state = UPD_IDLE;
    j->msg = "Cancelled.";
}

const char* Update_ConfirmText(const UpdateJob* j)
{
    if (!j) return "";
    switch (j->region) {
    case EOS_RGN_LOADER: return "This will ERASE and OVERWRITE the loader region. Continue?";
    case EOS_RGN_XBDIAG: return "This will ERASE and OVERWRITE the XbDiag bank. Continue?";
    case EOS_RGN_BANK:   return "This will ERASE and OVERWRITE the selected BIOS bank. Continue?";
    default:             return "This will write flash. Continue?";
    }
}

int Update_Progress(const UpdateJob* j)
{
    if (!j || j->len <= 0) return 0;
    if (j->state >= UPD_VALIDATING) return 100;
    return (int)(((__int64)j->staged * 100) / j->len);
}