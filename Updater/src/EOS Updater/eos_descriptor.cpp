// eos_descriptor.cpp -- Eos dynamic bank-layout descriptor (loader side).
//
// 64-byte on-flash format (bank 0xF, little-endian; mirrors eos_bank_ctrl.v):
//   0x00  MAGIC 'E','O','S','B'
//   0x04  VERSION = 1
//   0x05  SLOT_COUNT = 4
//   0x06  reserved (0)
//   per slot (8 bytes each) @ 0x08, 0x10, 0x18, 0x20:
//     [0] state     0=free 1=native256 2=oversized-anchor 3=shadowed
//     [1] size_code 0=256K 1=512K 2=1M
//     [2..3] reserved
//     [4..6] phys_base (24-bit, relative to FLOOR, little-endian)
//     [7] reserved
//
// No CRT: this file uses only fixed-size buffers and the loader's flash driver.
#include <xtl.h>
#include "eos_bank.h"   // Bank_Ef for color slot mapping
#include "eos_descriptor.h"
#include "eos_flash.h"

#define DESC_MAGIC0 0x45   // 'E'
#define DESC_MAGIC1 0x4F   // 'O'
#define DESC_MAGIC2 0x53   // 'S'
#define DESC_MAGIC3 0x42   // 'B'
#define DESC_VERSION 0x01

#define DESC_BYTES  64
#define SLOT0_OFF   0x08
#define SLOT_STRIDE 0x08

// LED bank colors ride in the same descriptor page: a 4-byte sub-magic 'COLR'
// at 0x2C, then 4 x 3-byte RGB at 0x30. Absent sub-magic => colors unset (OFF).
#define COLR_MAGIC_OFF 0x2C
#define COLR_DATA_OFF  0x30
#define COLR_M0 0x43  // 'C'
#define COLR_M1 0x4F  // 'O'
#define COLR_M2 0x4C  // 'L'
#define COLR_M3 0x52  // 'R'

// New-region byte offset (relative to FLOOR) where oversized banks live. Matches
// the FPGA NEWRGN_OFF parameter (phys 0x5C0000 = FLOOR 0x200000 + 0x3C0000).
#define NEWRGN_OFF  0x3C0000

// ---- helpers --------------------------------------------------------------

static void put24le(unsigned char* p, unsigned int v)
{
    p[0] = (unsigned char)(v & 0xFF);
    p[1] = (unsigned char)((v >> 8) & 0xFF);
    p[2] = (unsigned char)((v >> 16) & 0xFF);
}

static unsigned int get24le(const unsigned char* p)
{
    return (unsigned int)p[0]
        | ((unsigned int)p[1] << 8)
        | ((unsigned int)p[2] << 16);
}

void Desc_InitEmpty(EosLayout* lay)
{
    { int _i; for (_i = 0; _i < EOS_DESC_SLOTS; ++_i) lay->color[_i] = 0xFFFFFFu; }
    int i;
    lay->valid = 1;
    for (i = 0; i < EOS_DESC_SLOTS; ++i) {
        lay->slot[i].state = EOS_SLOT_FREE;
        lay->slot[i].sizeCode = EOS_SZC_256K;
        lay->slot[i].physBase = 0;
    }
}

int Desc_SlotsFor(int sizeCode)
{
    if (sizeCode == EOS_SZC_1MB)  return 4;
    if (sizeCode == EOS_SZC_512K) return 2;
    return 1;   // 256K
}

// ---- load / save ----------------------------------------------------------

int Desc_Load(EosLayout* out)
{
    unsigned char pg[256];
    int i, rc;

    Desc_InitEmpty(out);
    out->valid = 0;   // assume invalid until MAGIC checks out

    // The descriptor lives in the first page of bank 0xF. One page read covers
    // the whole 64-byte structure.
    rc = Flash_ReadPage(EOS_BANK_DESCRIPTOR, 0, pg);
    if (rc != EOS_FLASH_OK)
        return 0;   // read failed -> treat as no descriptor (legacy)

    if (pg[0] != DESC_MAGIC0 || pg[1] != DESC_MAGIC1 ||
        pg[2] != DESC_MAGIC2 || pg[3] != DESC_MAGIC3 ||
        pg[4] != DESC_VERSION)
        return 0;   // blank/invalid -> legacy

    for (i = 0; i < EOS_DESC_SLOTS; ++i) {
        const unsigned char* e = pg + SLOT0_OFF + i * SLOT_STRIDE;
        out->slot[i].state = (unsigned char)(e[0] & 0x03);
        out->slot[i].sizeCode = (unsigned char)(e[1] & 0x03);
        out->slot[i].physBase = get24le(e + 4);
    }
    // LED colors: only if the 'COLR' sub-magic is present (older descriptors
    // won't have it -> leave the InitEmpty defaults of 0xFFFFFF = OFF).
    if (pg[COLR_MAGIC_OFF + 0] == COLR_M0 && pg[COLR_MAGIC_OFF + 1] == COLR_M1 &&
        pg[COLR_MAGIC_OFF + 2] == COLR_M2 && pg[COLR_MAGIC_OFF + 3] == COLR_M3) {
        for (i = 0; i < EOS_DESC_SLOTS; ++i) {
            const unsigned char* c = pg + COLR_DATA_OFF + i * 3;
            out->color[i] = ((unsigned int)c[0] << 16) | ((unsigned int)c[1] << 8) | c[2];
        }
    }
    out->valid = 1;
    return 1;
}

int Desc_Save(const EosLayout* lay)
{
    unsigned char pg[256];
    int i, rc;

    for (i = 0; i < 256; ++i) pg[i] = 0x00;

    pg[0] = DESC_MAGIC0; pg[1] = DESC_MAGIC1;
    pg[2] = DESC_MAGIC2; pg[3] = DESC_MAGIC3;
    pg[4] = DESC_VERSION;
    pg[5] = EOS_DESC_SLOTS;

    for (i = 0; i < EOS_DESC_SLOTS; ++i) {
        unsigned char* e = pg + SLOT0_OFF + i * SLOT_STRIDE;
        e[0] = lay->slot[i].state;
        e[1] = lay->slot[i].sizeCode;
        put24le(e + 4, lay->slot[i].physBase);
    }

    // LED bank colors: sub-magic + 4x RGB (0xFFFFFF = OFF/unset).
    pg[COLR_MAGIC_OFF + 0] = COLR_M0; pg[COLR_MAGIC_OFF + 1] = COLR_M1;
    pg[COLR_MAGIC_OFF + 2] = COLR_M2; pg[COLR_MAGIC_OFF + 3] = COLR_M3;
    for (i = 0; i < EOS_DESC_SLOTS; ++i) {
        unsigned char* c = pg + COLR_DATA_OFF + i * 3;
        c[0] = (unsigned char)((lay->color[i] >> 16) & 0xFF);
        c[1] = (unsigned char)((lay->color[i] >> 8) & 0xFF);
        c[2] = (unsigned char)(lay->color[i] & 0xFF);
    }

    // Erase the descriptor bank, program the single page, sync.
    rc = Flash_WriteImageNoSync(EOS_BANK_DESCRIPTOR, pg, 256);
    if (rc != EOS_FLASH_OK) return rc;

    // Tell the FPGA to re-read it so geometry updates without a reboot.
    Flash_ReloadDescriptor();
    return EOS_FLASH_OK;
}

// Hard reset: erase the descriptor block so it reads blank (invalid MAGIC) and
// the FPGA + loader fall back to pure legacy static geometry. Recovery path for
// when the descriptor holds bad state. Does NOT touch any BIOS banks or the new
// region -- only the 64K descriptor block at bank 0xF.
int Desc_Erase(void)
{
    int rc = Flash_EraseBank(EOS_BANK_DESCRIPTOR);
    if (rc != EOS_FLASH_OK) return rc;
    Flash_ReloadDescriptor();   // FPGA re-reads -> blank -> legacy
    return EOS_FLASH_OK;
}

// ---- budget / placement ---------------------------------------------------

int Desc_FreeSlots(const EosLayout* lay)
{
    int i, n = 0;
    for (i = 0; i < EOS_DESC_SLOTS; ++i)
        if (lay->slot[i].state == EOS_SLOT_FREE) ++n;
    return n;
}

// Find a run of `need` consecutive FREE slots. Returns start index or -1.
// Oversized banks consume contiguous visible slots (anchor + shadows), so the
// budget must have `need` slots in a row from some position.
static int find_run(const EosLayout* lay, int need)
{
    int i, j, ok;
    for (i = 0; i + need <= EOS_DESC_SLOTS; ++i) {
        ok = 1;
        for (j = 0; j < need; ++j)
            if (lay->slot[i + j].state != EOS_SLOT_FREE) { ok = 0; break; }
        if (ok) return i;
    }
    return -1;
}

int Desc_CanPlace(const EosLayout* lay, int sizeCode, int* anchorSlot)
{
    int need = Desc_SlotsFor(sizeCode);
    int at = find_run(lay, need);
    if (at < 0) return 0;
    if (anchorSlot) *anchorSlot = at;
    return 1;
}

// New-region byte offset (rel FLOOR) for an oversized bank at `slot`.
//   1MB  -> whole region  (+0)
//   512K -> half 0 (slots 0/1) = +0 ; half 1 (slots 2/3) = +0x80000
unsigned int Desc_NewRegionBase(int slot, int sizeCode)
{
    if (sizeCode == EOS_SZC_1MB) return EOS_NEWRGN_BASE;
    if (slot >= 2)               return EOS_NEWRGN_BASE + EOS_NEWRGN_HALF;
    return EOS_NEWRGN_BASE;
}

// Would placing sizeCode at this specific slot be legal, assuming we first free
// the target footprint (overwrite semantics)? Enforces the alignment ruleset.
int Desc_CanPlaceAt(const EosLayout* lay, int slot, int sizeCode)
{
    int need = Desc_SlotsFor(sizeCode);
    EosLayout tmp;
    int i, j;

    if (slot < 0 || slot >= EOS_DESC_SLOTS) return 0;
    if (slot + need > EOS_DESC_SLOTS)       return 0;   // doesn't fit the budget

    // Alignment ruleset:
    //   256K -> any slot
    //   512K -> even boundary only (slot 0 or 2), so it aligns to a 512K half
    //   1MB  -> slot 0 only
    if (sizeCode == EOS_SZC_512K && (slot & 1)) return 0;
    if (sizeCode == EOS_SZC_1MB && slot != 0)  return 0;

    // Work on a copy: free the target footprint, then require the run to be free.
    tmp = *lay;
    Desc_FreeFootprint(&tmp, slot, need);
    for (j = 0; j < need; ++j)
        if (tmp.slot[slot + j].state != EOS_SLOT_FREE) return 0;

    // A 1MB needs the ENTIRE budget free (after freeing target footprint, no
    // other occupant may remain).
    if (sizeCode == EOS_SZC_1MB) {
        for (i = 0; i < EOS_DESC_SLOTS; ++i)
            if (tmp.slot[i].state != EOS_SLOT_FREE) return 0;
    }
    return 1;
}

// ---- mutation -------------------------------------------------------------

int Desc_PlaceNative(EosLayout* lay, unsigned int physBaseRelFloor)
{
    int at = find_run(lay, 1);
    if (at < 0) return -1;
    lay->slot[at].state = EOS_SLOT_NATIVE;
    lay->slot[at].sizeCode = EOS_SZC_256K;
    lay->slot[at].physBase = physBaseRelFloor;
    return at;
}

// Place an oversized bank at a SPECIFIC visible slot (overwrite semantics: the
// target footprint is freed first). Enforces the alignment ruleset. Returns the
// new-region byte offset (rel FLOOR) where the caller must write the bytes, or
// (unsigned)-1 on failure.
unsigned int Desc_PlaceOversizedAt(EosLayout* lay, int slot, int sizeCode)
{
    int need = Desc_SlotsFor(sizeCode);
    unsigned int base;
    int j;

    if (sizeCode != EOS_SZC_512K && sizeCode != EOS_SZC_1MB) return (unsigned int)-1;
    if (!Desc_CanPlaceAt(lay, slot, sizeCode)) return (unsigned int)-1;

    Desc_FreeFootprint(lay, slot, need);
    base = Desc_NewRegionBase(slot, sizeCode);

    lay->slot[slot].state = EOS_SLOT_ANCHOR;
    lay->slot[slot].sizeCode = (unsigned char)sizeCode;
    lay->slot[slot].physBase = base;
    for (j = 1; j < need; ++j) {
        lay->slot[slot + j].state = EOS_SLOT_SHADOW;
        lay->slot[slot + j].sizeCode = EOS_SZC_256K;
        lay->slot[slot + j].physBase = 0;
    }
    return base;
}

int Desc_PlaceOversized(EosLayout* lay, int sizeCode, unsigned int newRegionBaseRelFloor)
{
    // Legacy entry: find the first legal anchor slot, then place there.
    int need = Desc_SlotsFor(sizeCode);
    int at;
    (void)newRegionBaseRelFloor;
    if (sizeCode != EOS_SZC_512K && sizeCode != EOS_SZC_1MB) return -1;
    for (at = 0; at + need <= EOS_DESC_SLOTS; ++at) {
        if (Desc_CanPlaceAt(lay, at, sizeCode)) {
            if (Desc_PlaceOversizedAt(lay, at, sizeCode) != (unsigned int)-1) return at;
        }
    }
    return -1;
}

int Desc_FreeSlot(EosLayout* lay, int slot)
{
    int span, j;
    if (slot < 0 || slot >= EOS_DESC_SLOTS) return 0;

    if (lay->slot[slot].state == EOS_SLOT_ANCHOR) {
        // Free the anchor and all its shadow slots.
        span = Desc_SlotsFor(lay->slot[slot].sizeCode);
        for (j = 0; j < span && (slot + j) < EOS_DESC_SLOTS; ++j) {
            lay->slot[slot + j].state = EOS_SLOT_FREE;
            lay->slot[slot + j].sizeCode = EOS_SZC_256K;
            lay->slot[slot + j].physBase = 0;
        }
        return 1;
    }
    if (lay->slot[slot].state == EOS_SLOT_NATIVE) {
        lay->slot[slot].state = EOS_SLOT_FREE;
        lay->slot[slot].sizeCode = EOS_SZC_256K;
        lay->slot[slot].physBase = 0;
        return 1;
    }
    // SHADOW or FREE: freeing a shadow directly is not allowed (free its anchor).
    return 0;
}

// Free the footprint that would collide with placing `need` slots starting at
// `at`. Any anchor whose span overlaps [at, at+need) is fully freed (anchor +
// its shadows), and any native in range is freed. This lets a flash OVERWRITE a
// slot (or a run of slots) without the user having to manually delete first --
// the target's current occupancy is cleared as part of placing the new bank.
// Returns the number of distinct banks that were freed.
int Desc_FreeFootprint(EosLayout* lay, int at, int need)
{
    int i, freed = 0;
    if (at < 0) return 0;
    // Walk the whole 4-slot budget: a 512K anchor sitting at `at-1` shadows `at`,
    // so we must find the OWNING anchor of any slot in range and free it wholly.
    for (i = 0; i < EOS_DESC_SLOTS; ++i) {
        int st = lay->slot[i].state;
        if (st == EOS_SLOT_ANCHOR) {
            int span = Desc_SlotsFor(lay->slot[i].sizeCode);
            int lo = i, hi = i + span;               // this anchor owns [lo,hi)
            int rlo = at, rhi = at + need;           // region we want to place
            // overlap?
            if (lo < rhi && rlo < hi) { Desc_FreeSlot(lay, i); ++freed; }
        }
        else if (st == EOS_SLOT_NATIVE) {
            if (i >= at && i < at + need) { Desc_FreeSlot(lay, i); ++freed; }
        }
    }
    return freed;
}

// ---- bank LED color palette + get/set --------------------------------------
// Index 0 = OFF (0xFFFFFF sentinel; gateware treats FF,FF,FF as off). 1..11 are
// selectable colors. Accent purple (168,85,247) included for brand consistency.
const unsigned int Eos_LedPalette[EOS_LED_PALETTE_N] = {
    0xFFFFFF, // 0  OFF (sentinel)
    0xFF0000, // 1  Red
    0xFF6000, // 2  Orange
    0xFFD000, // 3  Amber
    0x30FF00, // 4  Green
    0x00FFC0, // 5  Teal
    0x00C0FF, // 6  Cyan
    0x0040FF, // 7  Blue
    0xA855F7, // 8  Purple (accent 168,85,247)
    0xFF00E0, // 9  Magenta
    0xFF3080, // 10 Pink
    0xFEFEFE  // 11 White  (0xFEFEFE, not FFFFFF, so it is not the OFF sentinel)
};
const char* const Eos_LedPaletteName[EOS_LED_PALETTE_N] = {
    "Off","Red","Orange","Amber","Green","Teal","Cyan","Blue",
    "Purple","Magenta","Pink","White"
};

// Bank LED color get/set. `bankIdx` is a BANK TABLE INDEX (not a raw slot); the
// EF->slot mapping (0x3..0x6 -> 0..3) is done here so every caller can just pass a
// bank index. Non-user banks (no slot) read as OFF / ignore writes.
static int descColorSlot(int bankIdx)
{
    unsigned char ef = Bank_Ef(bankIdx);
    if (ef >= 0x3 && ef <= 0x6) return (int)(ef - 0x3);
    return -1;
}

unsigned int Desc_GetColor(int bankIdx)
{
    EosLayout lay;
    int slot = descColorSlot(bankIdx);
    if (slot < 0) return 0xFFFFFFu;
    Desc_Load(&lay);                 // fills defaults (OFF) if no descriptor
    return lay.color[slot];
}

int Desc_SetColor(int bankIdx, unsigned int rgb)
{
    EosLayout lay;
    int slot = descColorSlot(bankIdx);
    int i;
    if (slot < 0) return -1;
    Desc_Load(&lay);                 // preserve existing slots + other colors

    // CRITICAL: writing this descriptor flips the FPGA to descriptor_valid=true,
    // which makes it serve user banks from the descriptor's slot table. But native
    // 256K banks were historically NEVER persisted (see reconcileDescriptor) -- the
    // loaded descriptor may show them FREE while they actually hold a BIOS. If we
    // saved that as-is, an occupied native bank would be recorded FREE with a valid
    // descriptor -> the FPGA serves it empty -> reboot loop. So reconcile occupancy
    // into the layout first: every occupied user bank that isn't already ANCHOR/
    // SHADOW is marked NATIVE 256K with its correct base (slot N -> N*0x040000).
    for (i = 0; i < Bank_Count(); ++i) {
        unsigned char ef = Bank_Ef(i);
        int s;
        if (ef < 0x3 || ef > 0x6) continue;      // user banks only
        s = (int)(ef - 0x3);
        if (Bank_Occupied(i) && lay.slot[s].state == EOS_SLOT_FREE) {
            lay.slot[s].state = EOS_SLOT_NATIVE;
            lay.slot[s].sizeCode = EOS_SZC_256K;
            lay.slot[s].physBase = 0;
        }
    }

    lay.color[slot] = rgb & 0xFFFFFFu;
    return Desc_Save(&lay);          // rewrites whole page (slots+colors), reloads
}