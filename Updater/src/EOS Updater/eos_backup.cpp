// eos_backup.cpp -- Loader-update safety snapshots + manual bank backups.
#include <xtl.h>
#include "eos_backup.h"
#include "eos_descriptor.h"
#include "eos_flash.h"
#include "eos_file.h"
#include "eos_config.h"
#include "eos_crc.h"

static BackupProgressCb s_progress = 0;
static char s_lastFolder[EOS_BACKUP_PATH_MAX] = "";
static char s_lastError[96] = "";

void Backup_SetProgressCb(BackupProgressCb cb) { s_progress = cb; }
const char* Backup_LastFolder(void) { return s_lastFolder; }
const char* Backup_LastError(void) { return s_lastError; }

static int slen(const char* s) { int n = 0; while (s && s[n]) ++n; return n; }

static void scopy(char* d, int cap, const char* s)
{
    int i = 0;
    if (cap <= 0) return;
    while (s && s[i] && i < cap - 1) { d[i] = s[i]; ++i; }
    d[i] = 0;
}

static void scat(char* d, int cap, const char* s)
{
    int at = slen(d), i = 0;
    while (s && s[i] && at < cap - 1) d[at++] = s[i++];
    d[at] = 0;
}

/* Native user BIOS bytes physically live inside the Loader full-image window.
   Accessing them through EF 0x3..0x6 is unsafe when a descriptor is valid: the
   flash control plane's descriptor slot numbering is not the same as the serve
   path's EF numbering. Bank 0xE is a static system-bank window, so using it plus
   a fixed slot offset bypasses descriptor routing completely. */
#define NATIVE_PHYS_BANK       0x0E
#define NATIVE_SLOT_PAGES      1024    /* 0x40000 / 256 */

static int native_start_page(int slot)
{
    if (slot < 0 || slot >= EOS_BACKUP_USER_BANKS) return -1;
    return slot * NATIVE_SLOT_PAGES;
}

static int backup_fail(const char* msg)
{
    scopy(s_lastError, sizeof(s_lastError), msg ? msg : "Backup operation failed");
    return 0;
}

static void join(char* out, int cap, const char* base, const char* leaf)
{
    scopy(out, cap, base);
    if (slen(out) > 0 && out[slen(out) - 1] != '\\') scat(out, cap, "\\");
    scat(out, cap, leaf);
}

static void append_dec(char* out, int cap, int v)
{
    char t[16]; int n = 0, at = slen(out);
    if (v == 0) t[n++] = '0';
    else { while (v > 0 && n < 15) { t[n++] = (char)('0' + (v % 10)); v /= 10; } }
    while (n > 0 && at < cap - 1) out[at++] = t[--n];
    out[at] = 0;
}

static void append_hex8(char* out, int cap, unsigned long v)
{
    static const char* h = "0123456789ABCDEF";
    int sh, at = slen(out);
    scat(out, cap, "0x"); at = slen(out);
    for (sh = 28; sh >= 0 && at < cap - 1; sh -= 4) out[at++] = h[(v >> sh) & 0x0F];
    out[at] = 0;
}

static void safe_name(char* out, int cap, const char* name)
{
    int i = 0, o = 0;
    while (name && name[i] && o < cap - 1) {
        char c = name[i++];
        if (c == ' ') c = '_';
        if (c == '\\' || c == '/' || c == ':' || c == '*' || c == '?' ||
            c == '"' || c == '<' || c == '>' || c == '|') continue;
        out[o++] = c;
    }
    if (o == 0 && cap > 1) {
        out[o++] = 'b'; if (o < cap - 1) out[o++] = 'a';
        if (o < cap - 1) out[o++] = 'n'; if (o < cap - 1) out[o++] = 'k';
    }
    out[o] = 0;
}

static int ensure_dir(const char* p)
{
    DWORD a = GetFileAttributesA(p);
    if (a != 0xFFFFFFFF && (a & FILE_ATTRIBUTE_DIRECTORY)) return 1;
    return CreateDirectoryA(p, NULL) ? 1 : 0;
}

static int create_numbered_folder(char* out, int cap, const char* prefix)
{
    int i;
    char leaf[40];
    if (!ensure_dir("D:\\backups")) return 0;
    for (i = 1; i <= 99; ++i) {
        scopy(leaf, sizeof(leaf), prefix);
        if (i < 10) scat(leaf, sizeof(leaf), "0");
        append_dec(leaf, sizeof(leaf), i);
        join(out, cap, "D:\\backups", leaf);
        if (GetFileAttributesA(out) == 0xFFFFFFFF) {
            if (CreateDirectoryA(out, NULL)) return 1;
        }
    }
    return 0;
}

static int descriptor_slot_state(const EosLayout* lay, int slot)
{
    if (!lay || !lay->valid || slot < 0 || slot >= EOS_DESC_SLOTS) return EOS_SLOT_FREE;
    return lay->slot[slot].state;
}

static int logical_info(int slot, const EosLayout* lay, EosBackupBank* b)
{
    int idx, st;
    unsigned char ef;
    if (!b || slot < 0 || slot >= 4) return 0;
    ef = (unsigned char)(0x3 + slot);
    idx = Bank_IndexForEf(ef);
    if (idx < 0) return 0;

    b->present = 0;
    b->tableIndex = idx;
    b->slot = slot;
    b->ef = ef;
    b->sizeCode = EOS_BANK_SIZE_256K;
    b->bytes = 256 * 1024;
    b->state = EOS_SLOT_NATIVE;
    b->physBase = (unsigned int)(slot * 0x040000);
    b->color = 0xFFFFFFu;
    b->crc32 = 0;
    scopy(b->name, sizeof(b->name), Bank_Name(idx));
    b->file[0] = 0;

    st = descriptor_slot_state(lay, slot);
    if (lay && lay->valid) b->color = lay->color[slot];
    if (st == EOS_SLOT_SHADOW) return 0;
    if (st == EOS_SLOT_ANCHOR) {
        b->present = 1;
        b->state = EOS_SLOT_ANCHOR;
        b->physBase = lay->slot[slot].physBase;
        if (lay->slot[slot].sizeCode == EOS_SZC_1MB) {
            b->sizeCode = EOS_BANK_SIZE_1MB; b->bytes = 1024 * 1024;
        }
        else { b->sizeCode = EOS_BANK_SIZE_512K; b->bytes = 512 * 1024; }
        return 1;
    }

    if (Bank_Occupied(idx) || st == EOS_SLOT_NATIVE) {
        b->present = 1;
        b->state = EOS_SLOT_NATIVE;
        b->sizeCode = EOS_BANK_SIZE_256K;
        b->bytes = 256 * 1024;
        b->physBase = (unsigned int)(slot * 0x040000);
        return 1;
    }
    return 0;
}

static void recovery_info(EosBackupBank* b)
{
    int idx;
    if (!b) return;
    ZeroMemory(b, sizeof(*b));
    idx = Bank_IndexForEf((unsigned char)EOS_BACKUP_RECOVERY_EF);
    b->present = 1;                         /* Recovery is mandatory for Loader safety sets. */
    b->tableIndex = idx;
    b->slot = -1;                           /* system bank: never descriptor-routed */
    b->ef = (unsigned char)EOS_BACKUP_RECOVERY_EF;
    b->sizeCode = EOS_BANK_SIZE_256K;
    b->bytes = EOS_BACKUP_RECOVERY_BYTES;
    b->state = EOS_SLOT_NATIVE;
    b->physBase = 0x1C0000u;                /* relative to FLOOR, phys 0x3C0000 */
    b->color = 0xFFFFFFu;
    b->crc32 = 0;
    scopy(b->name, sizeof(b->name), (idx >= 0) ? Bank_Name(idx) : "Recovery");
    b->file[0] = 0;
}

static void xbdiag_info(EosBackupBank* b)
{
    int idx;
    if (!b) return;
    ZeroMemory(b, sizeof(*b));
    idx = Bank_IndexForEf((unsigned char)EOS_BACKUP_XBDIAG_EF);
    b->present = Bank_XbDiagPresent() ? 1 : 0;
    b->tableIndex = idx;
    b->slot = -1;
    b->ef = (unsigned char)EOS_BACKUP_XBDIAG_EF;
    b->sizeCode = EOS_BANK_SIZE_256K;
    b->bytes = EOS_BACKUP_XBDIAG_BYTES;
    b->state = EOS_SLOT_NATIVE;
    b->physBase = 0x200000u;
    b->color = 0xFFFFFFu;
    b->crc32 = 0;
    scopy(b->name, sizeof(b->name), (idx >= 0) ? Bank_Name(idx) : "XbDiag Lite");
    b->file[0] = 0;
}

static int read_logical(const EosBackupBank* b, unsigned char* work, int workCap)
{
    int srcEf, basePage, pages, pg, rc;
    if (!b || !work || b->bytes <= 0 || b->bytes > workCap) return 0;

    if (b->state == EOS_SLOT_ANCHOR) {
        if (b->physBase < EOS_NEWRGN_BASE || b->physBase >= EOS_NEWRGN_BASE + 0x100000) return 0;
        srcEf = EOS_BANK_NEWREGION;
        basePage = (int)((b->physBase - EOS_NEWRGN_BASE) / 256);
    }
    else if (b->slot >= 0) {
        /* Native user slots are read physically through bank E so descriptor state
           can never redirect EF3..EF6 reads to another logical slot. */
        srcEf = NATIVE_PHYS_BANK;
        basePage = native_start_page(b->slot);
        if (basePage < 0) return 0;
    }
    else {
        /* System banks (Recovery) use their fixed flash-bank selector directly. */
        srcEf = b->ef;
        basePage = 0;
    }

    pages = b->bytes / 256;
    for (pg = 0; pg < pages; ++pg) {
        rc = Flash_ReadPage(srcEf, basePage + pg, work + pg * 256);
        if (rc != EOS_FLASH_OK) return 0;
        if (s_progress && ((pg & 63) == 0 || pg + 1 == pages)) s_progress("Reading BIOS banks", pg + 1, pages);
    }
    return 1;
}

static int verify_at(int bankEf, int startPage, const unsigned char* data, int len)
{
    unsigned char rb[256];
    int pages, pg, i, off;
    pages = (len + 255) / 256;
    for (pg = 0; pg < pages; ++pg) {
        off = pg * 256;
        if (Flash_ReadPage(bankEf, startPage + pg, rb) != EOS_FLASH_OK) return 0;
        for (i = 0; i < 256; ++i) {
            unsigned char want = (off + i < len) ? data[off + i] : 0xFF;
            if (rb[i] != want) return 0;
        }
    }
    return 1;
}

static int current_matches(const EosBackupBank* b)
{
    unsigned char rb[256];
    unsigned long crc = 0xFFFFFFFFu;
    int srcEf, basePage, pages, pg, i;
    if (!b) return 0;

    if (b->state == EOS_SLOT_ANCHOR) {
        srcEf = EOS_BANK_NEWREGION;
        basePage = (int)((b->physBase - EOS_NEWRGN_BASE) / 256);
    }
    else if (b->slot >= 0) {
        srcEf = NATIVE_PHYS_BANK;
        basePage = native_start_page(b->slot);
        if (basePage < 0) return 0;
    }
    else {
        srcEf = b->ef;
        basePage = 0;
    }

    pages = b->bytes / 256;
    for (pg = 0; pg < pages; ++pg) {
        if (Flash_ReadPage(srcEf, basePage + pg, rb) != EOS_FLASH_OK) return 0;
        for (i = 0; i < 256; ++i) {
            int k;
            crc ^= (unsigned long)rb[i];
            for (k = 0; k < 8; ++k)
                crc = (crc >> 1) ^ (0xEDB88320u & (unsigned long)(0 - (long)(crc & 1u)));
        }
    }
    crc ^= 0xFFFFFFFFu;
    return (crc == b->crc32) ? 1 : 0;
}

static int write_raw_page(int bankEf, const unsigned char* pg)
{
    unsigned char rb[256]; int i;
    if (Flash_EraseBank(bankEf) != EOS_FLASH_OK) return 0;
    if (Flash_ProgramPage(bankEf, 0, pg) != EOS_FLASH_OK) return 0;
    if (Flash_ReadPage(bankEf, 0, rb) != EOS_FLASH_OK) return 0;
    for (i = 0; i < 256; ++i) if (rb[i] != pg[i]) return 0;
    return 1;
}

static const char* size_text(int c)
{
    if (c == EOS_BANK_SIZE_1MB) return "1MB";
    if (c == EOS_BANK_SIZE_512K) return "512K";
    return "256K";
}

static const char* color_text(unsigned int rgb)
{
    int i;
    rgb &= 0xFFFFFFu;
    for (i = 0; i < EOS_LED_PALETTE_N; ++i)
        if ((Eos_LedPalette[i] & 0xFFFFFFu) == rgb) return Eos_LedPaletteName[i];
    return "Custom";
}

static int write_small_verified(const char* path, const unsigned char* data, int len)
{
    unsigned char rb[256];
    int i, got;
    if (len < 0 || len > 256) return 0;
    if (File_WriteFrom(path, data, len) != len) return 0;
    got = File_ReadInto(path, rb, sizeof(rb));
    if (got != len) return 0;
    for (i = 0; i < len; ++i) if (rb[i] != data[i]) return 0;
    return 1;
}

static int write_manifest(const EosBackupSet* set)
{
    char out[4096], path[EOS_BACKUP_PATH_MAX];
    int p = 0, i;
    out[0] = 0;
    scat(out, sizeof(out), "EOS Firmware Snapshot\r\n");
    scat(out, sizeof(out), "Descriptor: ");
    scat(out, sizeof(out), set->descriptorValid ? "Valid" : "Legacy / blank");
    scat(out, sizeof(out), "\r\nSettings: settings.bin");
    scat(out, sizeof(out), "\r\n\r\n");
    for (i = 0; i < EOS_BACKUP_USER_BANKS; ++i) {
        const EosBackupBank* b = &set->bank[i];
        if (!b->present) continue;
        scat(out, sizeof(out), "Bank "); append_dec(out, sizeof(out), b->slot + 1);
        scat(out, sizeof(out), "\r\nName: "); scat(out, sizeof(out), b->name);
        scat(out, sizeof(out), "\r\nSize: "); scat(out, sizeof(out), size_text(b->sizeCode));
        scat(out, sizeof(out), "\r\nLayout: "); scat(out, sizeof(out), b->state == EOS_SLOT_ANCHOR ? "Oversized" : "Native");
        scat(out, sizeof(out), "\r\nLED: "); scat(out, sizeof(out), color_text(b->color));
        scat(out, sizeof(out), "\r\nCRC32: "); append_hex8(out, sizeof(out), b->crc32);
        scat(out, sizeof(out), "\r\nFile: ");
        {
            const char* fn = b->file; int n = slen(fn), at = n;
            while (at > 0 && fn[at - 1] != '\\') --at;
            scat(out, sizeof(out), fn + at);
        }
        scat(out, sizeof(out), "\r\n\r\n");
    }
    if (set->recovery.present) {
        const EosBackupBank* r = &set->recovery;
        scat(out, sizeof(out), "Recovery Bank\r\n");
        scat(out, sizeof(out), "Name: "); scat(out, sizeof(out), r->name);
        scat(out, sizeof(out), "\r\nSize: 256K");
        scat(out, sizeof(out), "\r\nLayout: System / fixed EF A");
        scat(out, sizeof(out), "\r\nCRC32: "); append_hex8(out, sizeof(out), r->crc32);
        scat(out, sizeof(out), "\r\nFile: recovery.bin\r\n\r\n");
    }
    if (set->xbdiag.present) {
        const EosBackupBank* x = &set->xbdiag;
        scat(out, sizeof(out), "XbDiag Bank\r\n");
        scat(out, sizeof(out), "Name: "); scat(out, sizeof(out), x->name);
        scat(out, sizeof(out), "\r\nSize: 256K");
        scat(out, sizeof(out), "\r\nLayout: System / fixed EF D");
        scat(out, sizeof(out), "\r\nCRC32: "); append_hex8(out, sizeof(out), x->crc32);
        scat(out, sizeof(out), "\r\nFile: xbdiag.bin\r\n\r\n");
    }
    p = slen(out);
    join(path, sizeof(path), set->folder, "manifest.txt");
    return File_WriteFrom(path, (const unsigned char*)out, p) == p ? 1 : 0;
}

#define EOS_BACKUP_DISK_MAGIC   0x31424F45u   /* "EOB1" */
#define EOS_BACKUP_DISK_VERSION 1u
#define EOS_BACKUP_SNAPSHOT_FILE "firmware.eosbak"

typedef struct EosBackupDisk {
    DWORD magic;
    DWORD version;
    DWORD setBytes;
    DWORD setCrc;
    EosBackupSet set;
} EosBackupDisk;

static int write_snapshot(const EosBackupSet* set, unsigned char* work, int workCap)
{
    EosBackupDisk disk;
    char path[EOS_BACKUP_PATH_MAX];
    DWORD fileCrc;
    int got;

    if (!set || !work || workCap < (int)sizeof(disk)) return 0;
    ZeroMemory(&disk, sizeof(disk));
    disk.magic = EOS_BACKUP_DISK_MAGIC;
    disk.version = EOS_BACKUP_DISK_VERSION;
    disk.setBytes = (DWORD)sizeof(EosBackupSet);
    disk.set = *set;
    disk.setCrc = (DWORD)Crc_Buffer((const unsigned char*)&disk.set, (int)sizeof(disk.set));
    fileCrc = (DWORD)Crc_Buffer((const unsigned char*)&disk, (int)sizeof(disk));

    join(path, sizeof(path), set->folder, EOS_BACKUP_SNAPSHOT_FILE);
    got = File_WriteFrom(path, (const unsigned char*)&disk, (int)sizeof(disk));
    if (got != (int)sizeof(disk)) return 0;
    got = File_ReadInto(path, work, workCap);
    if (got != (int)sizeof(disk)) return 0;
    return ((DWORD)Crc_Buffer(work, got) == fileCrc) ? 1 : 0;
}

static void rebase_snapshot_file(char* out, int cap, const char* folder, const char* oldPath)
{
    char leaf[128];
    int n, at;
    n = slen(oldPath);
    at = n;
    while (at > 0 && oldPath[at - 1] != '\\') --at;
    scopy(leaf, sizeof(leaf), oldPath + at);
    join(out, cap, folder, leaf);
}

static int backup_create_set(EosBackupSet* set, unsigned char* work, int workCap,
    const char* prefix)
{
    EosLayout lay;
    int i, count = 0, len;
    char leaf[100], safe[64], path[EOS_BACKUP_PATH_MAX];

    s_lastError[0] = 0;
    if (!set || !work || workCap < 1024 * 1024) return 0;
    ZeroMemory(set, sizeof(*set));
    if (!create_numbered_folder(set->folder, sizeof(set->folder), prefix)) return 0;
    scopy(s_lastFolder, sizeof(s_lastFolder), set->folder);

    if (Flash_ReadPage(EOS_BANK_DESCRIPTOR, 0, set->descriptorPage) != EOS_FLASH_OK) return 0;
    set->descriptorValid = (Desc_Load(&lay) && lay.valid) ? 1 : 0;
    if (!set->descriptorValid) Desc_InitEmpty(&lay);
    join(path, sizeof(path), set->folder, "descriptor.bin");
    // descriptor.bin is the untouched on-flash page for forensic/manual recovery.
    if (!write_small_verified(path, set->descriptorPage, 256)) return 0;

    // The copy used for automatic restore is gently reconciled. Older LED writes
    // could leave a valid NATIVE entry with physBase=0 for slots 2-4, while old
    // static-bank setups can leave an occupied native slot marked FREE. Preserve
    // the untouched raw descriptor.bin above, then repair only native geometry.
    //
    // IMPORTANT: the flash command plane and serve-plane EF numbering are not the
    // same once a descriptor is valid. Do NOT activate this corrected descriptor
    // during backup. Native BIOS bytes are read physically through bank E below,
    // while this reconciled copy is retained only for the later final restore.
    if (set->descriptorValid) {
        int changed = 0;
        for (i = 0; i < EOS_BACKUP_USER_BANKS; ++i) {
            int idx = Bank_IndexForEf((unsigned char)(0x3 + i));
            unsigned char* e = set->descriptorPage + 0x08 + i * 8;
            if (idx >= 0 &&
                ((e[0] & 0x03) == EOS_SLOT_NATIVE ||
                    (Bank_Occupied(idx) && (e[0] & 0x03) == EOS_SLOT_FREE))) {
                unsigned int base = (unsigned int)(i * 0x040000);
                if ((e[0] & 0x03) != EOS_SLOT_NATIVE || e[1] != EOS_SZC_256K ||
                    e[4] != (unsigned char)(base & 0xFF) ||
                    e[5] != (unsigned char)((base >> 8) & 0xFF) ||
                    e[6] != (unsigned char)((base >> 16) & 0xFF)) changed = 1;
                e[0] = EOS_SLOT_NATIVE; e[1] = EOS_SZC_256K;
                e[4] = (unsigned char)(base & 0xFF);
                e[5] = (unsigned char)((base >> 8) & 0xFF);
                e[6] = (unsigned char)((base >> 16) & 0xFF);
                lay.slot[i].state = EOS_SLOT_NATIVE;
                lay.slot[i].sizeCode = EOS_SZC_256K;
                lay.slot[i].physBase = base;
            }
        }
        /* Keep the corrected copy only in this transaction snapshot. Backup must
           be observational: do not activate or rewrite the live descriptor just
           to read BIOS data. Native bytes are read through the physical bank-E
           window below, so no routing repair is required on the running system. */
        (void)changed;
    }

    if (Flash_ReadPage(EOS_CONFIG_BANK, 0, set->configPage) != EOS_FLASH_OK) return 0;
    set->configValid = 1;
    join(path, sizeof(path), set->folder, "banktable.bin");
    if (!write_small_verified(path, set->configPage, 256)) return 0;

    /* Settings are a separate EOS flash block (0xC). Save the raw page too so
       fan/autoboot/music/custom-theme source survive a full firmware restore. */
    if (Flash_ReadPage(EOS_SETTINGS_BANK, 0, work) != EOS_FLASH_OK) return 0;
    join(path, sizeof(path), set->folder, "settings.bin");
    if (!write_small_verified(path, work, 256)) return 0;

    for (i = 0; i < EOS_BACKUP_USER_BANKS; ++i) {
        EosBackupBank* b = &set->bank[i];
        if (!logical_info(i, &lay, b)) continue;
        if (!read_logical(b, work, workCap)) return 0;
        b->crc32 = Crc_Buffer(work, b->bytes);
        safe_name(safe, sizeof(safe), b->name);
        scopy(leaf, sizeof(leaf), "bank"); append_dec(leaf, sizeof(leaf), i + 1);
        scat(leaf, sizeof(leaf), "_"); scat(leaf, sizeof(leaf), safe);
        scat(leaf, sizeof(leaf), "_"); scat(leaf, sizeof(leaf), size_text(b->sizeCode));
        scat(leaf, sizeof(leaf), ".bin");
        join(b->file, sizeof(b->file), set->folder, leaf);
        len = File_WriteFrom(b->file, work, b->bytes);
        if (len != b->bytes) return 0;
        len = File_ReadInto(b->file, work, workCap);
        if (len != b->bytes || Crc_Buffer(work, len) != b->crc32) return 0;
        ++count;
        if (s_progress) s_progress("Saving BIOS + Recovery", count, EOS_BACKUP_USER_BANKS + 2);
    }

    /* Recovery is part of every Loader-update safety set even though the current
       Loader image normally stops immediately below it. A failed descriptor or
       future image-layout change must never leave the only known-good recovery
       path outside the transaction. */
    recovery_info(&set->recovery);
    if (!read_logical(&set->recovery, work, workCap))
        return backup_fail("Recovery bank could not be read");
    set->recovery.crc32 = Crc_Buffer(work, set->recovery.bytes);
    join(set->recovery.file, sizeof(set->recovery.file), set->folder, "recovery.bin");
    len = File_WriteFrom(set->recovery.file, work, set->recovery.bytes);
    if (len != set->recovery.bytes) return backup_fail("Recovery backup file write failed");
    len = File_ReadInto(set->recovery.file, work, workCap);
    if (len != set->recovery.bytes || Crc_Buffer(work, len) != set->recovery.crc32)
        return backup_fail("Recovery backup verify failed");
    ++count;
    if (s_progress) s_progress("Saving BIOS + Recovery", count, EOS_BACKUP_USER_BANKS + 2);

    /* XbDiag is stored outside the Loader image, but a persistent firmware
       snapshot also restores the config page that records its state. Save the
       bank when installed so a later manual restore cannot produce metadata
       that says XbDiag exists while its bytes are missing or different. */
    xbdiag_info(&set->xbdiag);
    if (set->xbdiag.present) {
        if (!read_logical(&set->xbdiag, work, workCap))
            return backup_fail("XbDiag bank could not be read");
        set->xbdiag.crc32 = Crc_Buffer(work, set->xbdiag.bytes);
        join(set->xbdiag.file, sizeof(set->xbdiag.file), set->folder, "xbdiag.bin");
        len = File_WriteFrom(set->xbdiag.file, work, set->xbdiag.bytes);
        if (len != set->xbdiag.bytes) return backup_fail("XbDiag backup file write failed");
        len = File_ReadInto(set->xbdiag.file, work, workCap);
        if (len != set->xbdiag.bytes || Crc_Buffer(work, len) != set->xbdiag.crc32)
            return backup_fail("XbDiag backup verify failed");
        ++count;
        if (s_progress) s_progress("Saving BIOS + Recovery + XbDiag", count, EOS_BACKUP_USER_BANKS + 2);
    }

    set->bankCount = count;
    set->valid = 1;
    if (!write_snapshot(set, work, workCap)) { set->valid = 0; return backup_fail("Snapshot metadata write failed"); }
    /* Manifest is written last and remains the human-readable completion marker. */
    if (!write_manifest(set)) { set->valid = 0; return backup_fail("Backup manifest write failed"); }
    if (s_progress) s_progress("Firmware snapshot complete", 1, 1);
    return 1;
}

int Backup_CreateLoaderSet(EosBackupSet* set, unsigned char* work, int workCap)
{
    return backup_create_set(set, work, workCap, "loader_update_");
}

int Backup_CreateFirmwareSet(EosBackupSet* set, unsigned char* work, int workCap)
{
    return backup_create_set(set, work, workCap, "firmware_backup_");
}

int Backup_LoadFirmwareSet(const char* snapshotPath, EosBackupSet* set)
{
    EosBackupDisk disk;
    char folder[EOS_BACKUP_PATH_MAX];
    int got, i, n;
    DWORD crc;

    s_lastError[0] = 0;
    if (!snapshotPath || !set) return backup_fail("Invalid firmware snapshot path");
    got = File_ReadInto(snapshotPath, (unsigned char*)&disk, (int)sizeof(disk));
    if (got != (int)sizeof(disk)) return backup_fail("Firmware snapshot metadata could not be read");
    if (disk.magic != EOS_BACKUP_DISK_MAGIC || disk.version != EOS_BACKUP_DISK_VERSION ||
        disk.setBytes != (DWORD)sizeof(EosBackupSet))
        return backup_fail("Unsupported firmware snapshot format");
    crc = (DWORD)Crc_Buffer((const unsigned char*)&disk.set, (int)sizeof(disk.set));
    if (crc != disk.setCrc) return backup_fail("Firmware snapshot metadata CRC mismatch");
    if (!disk.set.valid) return backup_fail("Firmware snapshot is incomplete");

    *set = disk.set;
    scopy(folder, sizeof(folder), snapshotPath);
    n = slen(folder);
    while (n > 0 && folder[n - 1] != '\\') --n;
    if (n <= 0) return backup_fail("Firmware snapshot folder is invalid");
    folder[n - 1] = 0;
    scopy(set->folder, sizeof(set->folder), folder);

    /* Rebase payload paths to the selected snapshot's folder. This keeps the
       backup portable if its complete directory was moved or copied. */
    for (i = 0; i < EOS_BACKUP_USER_BANKS; ++i) {
        if (set->bank[i].present)
            rebase_snapshot_file(set->bank[i].file, sizeof(set->bank[i].file), folder, disk.set.bank[i].file);
    }
    if (set->recovery.present)
        rebase_snapshot_file(set->recovery.file, sizeof(set->recovery.file), folder, disk.set.recovery.file);
    if (set->xbdiag.present)
        rebase_snapshot_file(set->xbdiag.file, sizeof(set->xbdiag.file), folder, disk.set.xbdiag.file);
    scopy(s_lastFolder, sizeof(s_lastFolder), folder);
    return 1;
}

static int load_saved_settings(const EosBackupSet* set, unsigned char* out)
{
    char path[EOS_BACKUP_PATH_MAX];
    int got, i, allff = 1, all00 = 1;
    unsigned sum = 0, stored;
    if (!set || !out) return -1;
    join(path, sizeof(path), set->folder, "settings.bin");
    if (GetFileAttributesA(path) == 0xFFFFFFFF) return 0; /* old snapshot: no settings payload */
    got = File_ReadInto(path, out, 256);
    if (got != 256) return -1;
    for (i = 0; i < 256; ++i) { if (out[i] != 0xFF) allff = 0; if (out[i] != 0x00) all00 = 0; }
    if (allff || all00) return 1;
    if (!(out[0] == 'E' && out[1] == 'O' && out[2] == 'S' && out[3] == 'S')) return -1;
    for (i = 0; i < 254; ++i) sum += out[i];
    stored = (unsigned)out[254] | ((unsigned)out[255] << 8);
    return ((sum & 0xFFFF) == stored) ? 1 : -1;
}

static int validate_restore_set(const EosBackupSet* set, unsigned char* work, int workCap)
{
    int i, got;
    const EosBackupBank* b;
    const EosBackupBank* r;

    /* Preflight every payload before the first destructive write. This makes a
       later missing/corrupt file fail closed instead of producing a partial
       restore. The files are read again during programming so each write still
       uses freshly CRC-checked bytes. */
    for (i = 0; i < EOS_BACKUP_USER_BANKS; ++i) {
        b = &set->bank[i];
        if (!b->present) continue;
        if (b->bytes <= 0 || b->bytes > workCap)
            return backup_fail("Backup BIOS has invalid size");
        if (b->state == EOS_SLOT_ANCHOR) {
            if (b->physBase < EOS_NEWRGN_BASE || b->physBase >= EOS_NEWRGN_BASE + 0x100000)
                return backup_fail("Oversized BIOS has invalid physical placement");
        }
        else if (native_start_page(b->slot) < 0)
            return backup_fail("Native BIOS has invalid slot");
        got = File_ReadInto(b->file, work, workCap);
        if (got != b->bytes) return backup_fail("Backup BIOS file could not be read");
        if (Crc_Buffer(work, got) != b->crc32) return backup_fail("Backup BIOS CRC mismatch");
    }

    r = &set->recovery;
    if (!r->present || r->ef != EOS_BACKUP_RECOVERY_EF ||
        r->bytes != EOS_BACKUP_RECOVERY_BYTES)
        return backup_fail("Recovery backup is missing or invalid");
    got = File_ReadInto(r->file, work, workCap);
    if (got != r->bytes) return backup_fail("Recovery backup file could not be read");
    if (Crc_Buffer(work, got) != r->crc32) return backup_fail("Recovery backup CRC mismatch");

    if (set->xbdiag.present) {
        b = &set->xbdiag;
        if (b->ef != EOS_BACKUP_XBDIAG_EF || b->bytes != EOS_BACKUP_XBDIAG_BYTES)
            return backup_fail("XbDiag backup is invalid");
        got = File_ReadInto(b->file, work, workCap);
        if (got != b->bytes) return backup_fail("XbDiag backup file could not be read");
        if (Crc_Buffer(work, got) != b->crc32) return backup_fail("XbDiag backup CRC mismatch");
    }
    got = load_saved_settings(set, work);
    if (got < 0) return backup_fail("Settings backup is missing data or corrupt");
    return 1;
}

int Backup_RestoreLoaderSet(const EosBackupSet* set, unsigned char* work, int workCap)
{
    int i, restored = 0;
    int nativeTouched = 0;
    int newRegionTouched = 0;
    int recoveryTouched = 0;
    int xbdiagTouched = 0;

    s_lastError[0] = 0;
    if (!set || !set->valid || !work || workCap < 1024 * 1024)
        return backup_fail("Invalid backup set or work buffer");
    if (!validate_restore_set(set, work, workCap)) return 0;

    /* DATA FIRST, MAPPING LAST.
       The previous implementation activated the saved descriptor before writing
       native banks, then issued EF-based flash commands. That created a circular
       dependency: the very descriptor being restored could redirect those writes.
       Native BIOS bytes are now restored physically through bank E, while oversized
       images use the dedicated new-region bank. Only after every byte verifies do
       we restore the bank table and finally activate the descriptor. */
    for (i = 0; i < EOS_BACKUP_USER_BANKS; ++i) {
        const EosBackupBank* b = &set->bank[i];
        int got, rc, startPage;
        if (!b->present) continue;

        got = File_ReadInto(b->file, work, workCap);
        if (got != b->bytes) return backup_fail("Backup BIOS file could not be read");
        if (Crc_Buffer(work, got) != b->crc32) return backup_fail("Backup BIOS CRC mismatch");

        if (b->state == EOS_SLOT_ANCHOR) {
            if (!current_matches(b)) {
                if (b->physBase < EOS_NEWRGN_BASE || b->physBase >= EOS_NEWRGN_BASE + 0x100000)
                    return backup_fail("Oversized BIOS has invalid physical placement");
                startPage = (int)((b->physBase - EOS_NEWRGN_BASE) / 256);
                rc = Flash_WriteImageAtNoSync(EOS_BANK_NEWREGION, startPage, work, got);
                if (rc != EOS_FLASH_OK) return backup_fail("Oversized BIOS flash write failed");
                if (!verify_at(EOS_BANK_NEWREGION, startPage, work, got))
                    return backup_fail("Oversized BIOS verify failed");
                newRegionTouched = 1;
            }
        }
        else {
            startPage = native_start_page(b->slot);
            if (startPage < 0) return backup_fail("Native BIOS has invalid slot");

            rc = Flash_WriteImageAtNoSync(NATIVE_PHYS_BANK, startPage, work, got);
            if (rc != EOS_FLASH_OK) return backup_fail("Native BIOS physical write failed");
            if (!verify_at(NATIVE_PHYS_BANK, startPage, work, got))
                return backup_fail("Native BIOS physical verify failed");
            nativeTouched = 1;
        }

        ++restored;
        if (s_progress) s_progress("Restoring BIOS + Recovery", restored, set->bankCount > 0 ? set->bankCount : 1);
    }

    /* Recovery is verified/restored before metadata and descriptor commit. It is a
       fixed system bank (EF A), so descriptor contents can never redirect it. */
    {
        const EosBackupBank* r = &set->recovery;
        int got, rc;
        if (!r->present || r->ef != EOS_BACKUP_RECOVERY_EF ||
            r->bytes != EOS_BACKUP_RECOVERY_BYTES)
            return backup_fail("Recovery backup is missing or invalid");
        got = File_ReadInto(r->file, work, workCap);
        if (got != r->bytes) return backup_fail("Recovery backup file could not be read");
        if (Crc_Buffer(work, got) != r->crc32) return backup_fail("Recovery backup CRC mismatch");
        if (!current_matches(r)) {
            rc = Flash_WriteImageAtNoSync(r->ef, 0, work, got);
            if (rc != EOS_FLASH_OK) return backup_fail("Recovery bank flash write failed");
            if (!verify_at(r->ef, 0, work, got)) return backup_fail("Recovery bank verify failed");
            recoveryTouched = 1;
        }
        ++restored;
        if (s_progress) s_progress("Restoring BIOS + Recovery", restored,
            set->bankCount > 0 ? set->bankCount : 1);
    }

    /* Restore XbDiag when it was part of the snapshot. It is a fixed system
       bank and is restored before config metadata for the same reason as Recovery. */
    if (set->xbdiag.present) {
        const EosBackupBank* x = &set->xbdiag;
        int got, rc;
        got = File_ReadInto(x->file, work, workCap);
        if (got != x->bytes) return backup_fail("XbDiag backup file could not be read");
        if (Crc_Buffer(work, got) != x->crc32) return backup_fail("XbDiag backup CRC mismatch");
        if (!current_matches(x)) {
            rc = Flash_WriteImageAtNoSync(x->ef, 0, work, got);
            if (rc != EOS_FLASH_OK) return backup_fail("XbDiag bank flash write failed");
            if (!verify_at(x->ef, 0, work, got)) return backup_fail("XbDiag bank verify failed");
            xbdiagTouched = 1;
        }
        ++restored;
        if (s_progress) s_progress("Restoring BIOS + Recovery + XbDiag", restored,
            set->bankCount > 0 ? set->bankCount : 1);
    }

    /* Refresh SDRAM only after all writes, avoiding repeated full-bank reloads. */
    if (nativeTouched && Flash_Sync(NATIVE_PHYS_BANK) != EOS_FLASH_OK)
        return backup_fail("Native BIOS SDRAM sync failed");
    if (newRegionTouched && Flash_SyncNewRegion() != EOS_FLASH_OK)
        return backup_fail("Oversized BIOS SDRAM sync failed");
    if (recoveryTouched && Flash_Sync(EOS_BACKUP_RECOVERY_EF) != EOS_FLASH_OK)
        return backup_fail("Recovery bank SDRAM sync failed");
    if (xbdiagTouched && Flash_Sync(EOS_BACKUP_XBDIAG_EF) != EOS_FLASH_OK)
        return backup_fail("XbDiag bank SDRAM sync failed");

    /* Restore the bank table before the descriptor. If metadata write fails, the
       descriptor is still untouched and the user can retry from the preserved set. */
    if (set->configValid) {
        if (!write_raw_page(EOS_CONFIG_BANK, set->configPage))
            return backup_fail("Bank-table metadata restore failed");
    }

    {
        int sr = load_saved_settings(set, work);
        if (sr < 0) return backup_fail("Settings backup is corrupt");
        if (sr > 0 && !write_raw_page(EOS_SETTINGS_BANK, work))
            return backup_fail("Settings metadata restore failed");
    }

    /* Descriptor is the final commit point. set->descriptorPage is the reconciled
       automatic-restore copy; descriptor.bin on disk remains the untouched raw page. */
    if (set->descriptorValid) {
        if (!write_raw_page(EOS_BANK_DESCRIPTOR, set->descriptorPage))
            return backup_fail("Descriptor restore failed");
        Flash_ReloadDescriptor();
    }
    else {
        if (Desc_Erase() != EOS_FLASH_OK) return backup_fail("Legacy descriptor reset failed");
    }

    if (Config_Load() != 0) return backup_fail("Restored bank table could not be reloaded");
    s_lastError[0] = 0;
    return 1;
}

int Backup_ResetFactoryUserBanks(void)
{
    int rc1, rc2;
    rc1 = Desc_Erase();
    Bank_ResetUserBanks();
    rc2 = Config_Save();
    return (rc1 == EOS_FLASH_OK && rc2 == EOS_FLASH_OK) ? 1 : 0;
}

int Backup_SaveBankManual(int bankIndex, unsigned char* work, int workCap,
    char* outPath, int outCap)
{
    EosLayout lay;
    EosBackupBank b;
    char dir[EOS_BACKUP_PATH_MAX], safe[64], leaf[120], path[EOS_BACKUP_PATH_MAX];
    int slot, i, got;

    if (outPath && outCap > 0) outPath[0] = 0;
    if (bankIndex < 0 || bankIndex >= Bank_Count() || !work) return 0;
    if (!Bank_Occupied(bankIndex)) return 0;

    ZeroMemory(&b, sizeof(b));
    slot = (int)Bank_Ef(bankIndex) - 0x3;
    if (slot >= 0 && slot < 4) {
        if (Desc_Load(&lay) && lay.valid) {
            if (Bank_Occupied(bankIndex) &&
                (lay.slot[slot].state == EOS_SLOT_FREE || lay.slot[slot].state == EOS_SLOT_NATIVE)) {
                unsigned int base = (unsigned int)(slot * 0x040000);
                lay.slot[slot].state = EOS_SLOT_NATIVE;
                lay.slot[slot].sizeCode = EOS_SZC_256K;
                lay.slot[slot].physBase = base;
            }
        }
        else Desc_InitEmpty(&lay);
        if (!logical_info(slot, &lay, &b)) return 0;
    }
    else {
        int pg, pages;
        b.present = 1;
        b.tableIndex = bankIndex;
        b.slot = -1;
        b.ef = Bank_Ef(bankIndex);
        b.sizeCode = Bank_SizeCode(bankIndex);
        b.bytes = Bank_CapacityBytes(bankIndex);
        b.state = EOS_SLOT_NATIVE;
        b.color = 0xFFFFFFu;
        scopy(b.name, sizeof(b.name), Bank_Name(bankIndex));
        if (b.bytes <= 0 || b.bytes > workCap) return 0;
        pages = b.bytes / 256;
        for (pg = 0; pg < pages; ++pg) {
            if (Flash_ReadPage(b.ef, pg, work + pg * 256) != EOS_FLASH_OK) return 0;
            if (s_progress && ((pg & 63) == 0 || pg + 1 == pages))
                s_progress("Reading bank", pg + 1, pages);
        }
    }

    if (b.bytes > workCap) return 0;
    if (slot >= 0 && slot < 4) {
        if (!read_logical(&b, work, workCap)) return 0;
    }

    if (!ensure_dir("D:\\backups")) return 0;
    join(dir, sizeof(dir), "D:\\backups", "manual");
    if (!ensure_dir(dir)) return 0;
    safe_name(safe, sizeof(safe), b.name);

    for (i = 1; i <= 99; ++i) {
        if (slot >= 0) { scopy(leaf, sizeof(leaf), "bank"); append_dec(leaf, sizeof(leaf), slot + 1); }
        else { scopy(leaf, sizeof(leaf), "system_"); append_dec(leaf, sizeof(leaf), (int)(b.ef & 0x0F)); }
        scat(leaf, sizeof(leaf), "_"); scat(leaf, sizeof(leaf), safe);
        scat(leaf, sizeof(leaf), "_"); scat(leaf, sizeof(leaf), size_text(b.sizeCode));
        scat(leaf, sizeof(leaf), "_"); if (i < 10) scat(leaf, sizeof(leaf), "0"); append_dec(leaf, sizeof(leaf), i);
        scat(leaf, sizeof(leaf), ".bin");
        join(path, sizeof(path), dir, leaf);
        if (!File_Exists(path)) break;
    }
    if (i > 99) return 0;
    b.crc32 = Crc_Buffer(work, b.bytes);
    got = File_WriteFrom(path, work, b.bytes);
    if (got != b.bytes) return 0;
    got = File_ReadInto(path, work, workCap);
    if (got != b.bytes || Crc_Buffer(work, got) != b.crc32) return 0;
    if (outPath) scopy(outPath, outCap, path);
    return 1;
}

int Backup_HasAny(void)
{
    int i, kind;
    char leaf[40], folder[EOS_BACKUP_PATH_MAX], manifest[EOS_BACKUP_PATH_MAX];
    const char* prefix;
    DWORD a;

    // Count only completed full backup sets (manifest written last).
    for (kind = 0; kind < 2; ++kind) {
        prefix = (kind == 0) ? "loader_update_" : "firmware_backup_";
        for (i = 1; i <= 99; ++i) {
            scopy(leaf, sizeof(leaf), prefix);
            if (i < 10) scat(leaf, sizeof(leaf), "0");
            append_dec(leaf, sizeof(leaf), i);
            join(folder, sizeof(folder), "D:\\backups", leaf);
            join(manifest, sizeof(manifest), folder, "manifest.txt");
            if (File_Exists(manifest)) return 1;
        }
    }

    // Manual backups use collision-safe .bin files in this folder. We cannot
    // cheaply enumerate them without adding another file-browser dependency,
    // but an existing manual folder still indicates a maintenance backup area.
    a = GetFileAttributesA("D:\\backups\\manual");
    return (a != 0xFFFFFFFF && (a & FILE_ATTRIBUTE_DIRECTORY)) ? 1 : 0;
}

// ---- backup management ----------------------------------------------------
// Keep this intentionally scoped to artifacts EOS itself creates under
// D:\\backups. Unknown user files/folders are never surfaced or deleted.
static int backup_starts(const char* s, const char* p)
{
    int i = 0;
    if (!s || !p) return 0;
    while (p[i]) { if (s[i] != p[i]) return 0; ++i; }
    return 1;
}

static int backup_is_dot(const char* s)
{
    return s && s[0] == '.' && (s[1] == 0 || (s[1] == '.' && s[2] == 0));
}

static int backup_delete_tree(const char* path)
{
    WIN32_FIND_DATA fd;
    HANDLE h;
    char pat[EOS_BACKUP_PATH_MAX + 4];
    char child[EOS_BACKUP_PATH_MAX];
    DWORD a;
    int ok = 1;

    if (!path || !path[0]) return 0;
    a = GetFileAttributesA(path);
    if (a == 0xFFFFFFFF) return 1;
    if (!(a & FILE_ATTRIBUTE_DIRECTORY)) return DeleteFileA(path) ? 1 : 0;

    scopy(pat, sizeof(pat), path);
    scat(pat, sizeof(pat), "\\*");
    h = FindFirstFileA(pat, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (backup_is_dot(fd.cFileName)) continue;
            join(child, sizeof(child), path, fd.cFileName);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                if (!backup_delete_tree(child)) ok = 0;
            }
            else if (!DeleteFileA(child)) ok = 0;
        } while (FindNextFileA(h, &fd));
        FindClose(h);
    }
    if (!RemoveDirectoryA(path)) ok = 0;
    return ok;
}

static void backup_swap_entry(EosBackupEntry* a, EosBackupEntry* b)
{
    EosBackupEntry t = *a; *a = *b; *b = t;
}

static int backup_cmp_desc(const char* a, const char* b)
{
    int i = 0;
    while (a[i] && b[i] && a[i] == b[i]) ++i;
    if (a[i] == b[i]) return 0;
    return ((unsigned char)a[i] > (unsigned char)b[i]) ? -1 : 1;
}

int Backup_ListEntries(EosBackupEntry* out, int maxEntries)
{
    WIN32_FIND_DATA fd, md;
    HANDLE h, mh;
    char path[EOS_BACKUP_PATH_MAX], pat[EOS_BACKUP_PATH_MAX + 4];
    int n = 0, i, j;

    if (!out || maxEntries <= 0) return 0;
    scopy(pat, sizeof(pat), "D:\\backups\\*");
    h = FindFirstFileA(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;

    do {
        if (backup_is_dot(fd.cFileName)) continue;
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;

        if (backup_starts(fd.cFileName, "loader_update_") ||
            backup_starts(fd.cFileName, "firmware_backup_")) {
            if (n >= maxEntries) continue;
            join(out[n].path, sizeof(out[n].path), "D:\\backups", fd.cFileName);
            out[n].isFolder = 1;
            if (backup_starts(fd.cFileName, "loader_update_")) scopy(out[n].label, sizeof(out[n].label), "Loader  ");
            else scopy(out[n].label, sizeof(out[n].label), "Firmware  ");
            scat(out[n].label, sizeof(out[n].label), fd.cFileName);
            ++n;
        }
        else if (fd.cFileName[0] == 'm' && fd.cFileName[1] == 'a' &&
            fd.cFileName[2] == 'n' && fd.cFileName[3] == 'u' &&
            fd.cFileName[4] == 'a' && fd.cFileName[5] == 'l' && fd.cFileName[6] == 0) {
            join(path, sizeof(path), "D:\\backups", "manual");
            scopy(pat, sizeof(pat), path); scat(pat, sizeof(pat), "\\*");
            mh = FindFirstFileA(pat, &md);
            if (mh != INVALID_HANDLE_VALUE) {
                do {
                    if (backup_is_dot(md.cFileName) || (md.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
                    if (n >= maxEntries) continue;
                    join(out[n].path, sizeof(out[n].path), path, md.cFileName);
                    out[n].isFolder = 0;
                    scopy(out[n].label, sizeof(out[n].label), "Bank  ");
                    scat(out[n].label, sizeof(out[n].label), md.cFileName);
                    ++n;
                } while (FindNextFileA(mh, &md));
                FindClose(mh);
            }
        }
    } while (FindNextFileA(h, &fd));
    FindClose(h);

    for (i = 0; i < n - 1; ++i)
        for (j = i + 1; j < n; ++j)
            if (backup_cmp_desc(out[i].label, out[j].label) > 0) backup_swap_entry(&out[i], &out[j]);
    return n;
}

int Backup_DeleteEntry(const EosBackupEntry* entry)
{
    if (!entry || !entry->path[0]) return 0;
    return backup_delete_tree(entry->path);
}

int Backup_DeleteAll(void)
{
    static EosBackupEntry e[EOS_BACKUP_LIST_MAX];
    int n, i, ok = 1;
    n = Backup_ListEntries(e, EOS_BACKUP_LIST_MAX);
    for (i = 0; i < n; ++i) if (!Backup_DeleteEntry(&e[i])) ok = 0;
    RemoveDirectoryA("D:\\backups\\manual");
    RemoveDirectoryA("D:\\backups");
    return ok;
}

