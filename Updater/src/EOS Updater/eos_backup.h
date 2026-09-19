#pragma once
// eos_backup.h -- app-local BIOS backup/restore support used by Loader updates.
// Backups live beside the updater under D:\backups after Mount_SelfToD().

#include "eos_bank.h"

#define EOS_BACKUP_USER_BANKS 4
#define EOS_BACKUP_PATH_MAX   300
#define EOS_BACKUP_RECOVERY_EF 0x0A
#define EOS_BACKUP_RECOVERY_BYTES (256 * 1024)
#define EOS_BACKUP_XBDIAG_EF   0x0D
#define EOS_BACKUP_XBDIAG_BYTES (256 * 1024)

#define EOS_BACKUP_LIST_MAX    64
#define EOS_BACKUP_LABEL_MAX   96

typedef struct EosBackupEntry {
    char label[EOS_BACKUP_LABEL_MAX];
    char path[EOS_BACKUP_PATH_MAX];
    int  isFolder;
} EosBackupEntry;

typedef struct EosBackupBank {
    int present;
    int tableIndex;
    int slot;
    unsigned char ef;
    int sizeCode;
    int bytes;
    int state;
    unsigned int physBase;
    unsigned int color;
    unsigned long crc32;
    char name[EOS_BANK_NAMELEN];
    char file[EOS_BACKUP_PATH_MAX];
} EosBackupBank;

typedef struct EosBackupSet {
    int valid;
    int bankCount;
    int descriptorValid;
    int configValid;
    char folder[EOS_BACKUP_PATH_MAX];
    unsigned char descriptorPage[256];
    unsigned char configPage[256];
    EosBackupBank bank[EOS_BACKUP_USER_BANKS];
    EosBackupBank recovery;          // mandatory raw Recovery-bank safety image
    EosBackupBank xbdiag;            // optional XbDiag system bank, if installed
} EosBackupSet;

typedef void (*BackupProgressCb)(const char* stage, int done, int total);
void Backup_SetProgressCb(BackupProgressCb cb);

// Create a complete pre-Loader backup set. Returns 1 only when the descriptor,
// bank table, settings page, every occupied logical BIOS bank, Recovery, and installed XbDiag were saved successfully.
int Backup_CreateLoaderSet(EosBackupSet* set, unsigned char* work, int workCap);

// Create a persistent maintenance snapshot using the same complete transaction
// as a Loader update. The snapshot metadata is saved beside the bank images as
// firmware.eosbak so it can be selected and restored in a later updater run.
int Backup_CreateFirmwareSet(EosBackupSet* set, unsigned char* work, int workCap);

// Load/validate a firmware.eosbak snapshot. Paths are rebased to the selected
// snapshot folder so an intact backup folder can be moved as a unit.
int Backup_LoadFirmwareSet(const char* snapshotPath, EosBackupSet* set);

// Restore logical BIOS banks from a set using physical flash paths first, then
// restore Recovery, bank-table metadata and commit the descriptor last. Oversized banks are
// CRC-checked and left untouched when they survived the Loader update unchanged.
// Returns 1 only when the final state verifies.
int Backup_RestoreLoaderSet(const EosBackupSet* set, unsigned char* work, int workCap);

// Deliberately return only user BIOS banks (1-4) to factory/default layout.
// System-bank metadata and unrelated settings remain intact.
int Backup_ResetFactoryUserBanks(void);

// Manual single-bank backup into D:\backups\manual, using a collision-safe name.
int Backup_SaveBankManual(int bankIndex, unsigned char* work, int workCap,
    char* outPath, int outCap);

int Backup_HasAny(void);

// Backup-management helpers. Full firmware/loader snapshots are represented as
// one folder entry; manual single-bank .bin files are represented individually.
int Backup_ListEntries(EosBackupEntry* out, int maxEntries);
int Backup_DeleteEntry(const EosBackupEntry* entry);
int Backup_DeleteAll(void);
const char* Backup_LastFolder(void);
const char* Backup_LastError(void);