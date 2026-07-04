// eos_descriptor.h -- Eos dynamic bank-layout descriptor (loader side).
//
// The FPGA reads a 64-byte descriptor from bank 0xF (phys 0x6C0000) at boot and
// on demand (Flash_ReloadDescriptor). It governs the geometry (base/size) of the
// 4 user slots. Oversized banks (512K/1MB) physically live in the NEW REGION
// (bank 0x0, phys 0x5C0000) but are pointed at a visible slot and shown as
// consuming the right number of slots against a fixed 1MB budget.
//
// This module owns building / reading / writing that descriptor and the budget
// math (free slots, what fits, grey-out). The user always sees 4 slots + a 1MB
// ceiling; the extra region is invisible remap headroom.
#pragma once

// Visible user slots. Fixed at 4 (the 1MB budget = 4x256K worth).
#define EOS_DESC_SLOTS      4

// Bank IDs the FPGA exposes for the dynamic machinery.
#define EOS_BANK_NEWREGION  0x00   // 1MB oversized-bank area (phys 0x5C0000)
#define EOS_BANK_DESCRIPTOR 0x0F   // 64K descriptor block   (phys 0x6C0000)

// New region layout (phys 0x5C0000 = FLOOR + 0x3C0000). It holds oversized
// banks as two 512K halves: half 0 @ +0x00000, half 1 @ +0x80000. A 1MB bank
// uses the whole region @ +0x00000. The new-region offset is DERIVED from the
// anchor slot so two 512K banks never collide and mapping is deterministic.
#define EOS_NEWRGN_BASE  0x3C0000   // new-region base, relative to FLOOR
#define EOS_NEWRGN_HALF  0x80000    // 512K half stride

// Slot states (mirror the FPGA DS_* encoding).
#define EOS_SLOT_FREE     0   // empty
#define EOS_SLOT_NATIVE   1   // native 256K in the main partition
#define EOS_SLOT_ANCHOR   2   // anchor of an oversized bank (bytes in new region)
#define EOS_SLOT_SHADOW   3   // greyed: consumed by a preceding oversized anchor

// Size codes (mirror EOS_BANK_SIZE_* and the FPGA szc encoding).
#define EOS_SZC_256K   0
#define EOS_SZC_512K   1
#define EOS_SZC_1MB    2

// One visible slot's descriptor entry.
typedef struct {
    unsigned char state;      // EOS_SLOT_*
    unsigned char sizeCode;   // EOS_SZC_* (meaningful for NATIVE/ANCHOR)
    unsigned int  physBase;   // phys base RELATIVE TO FLOOR (matches FPGA space)
} EosSlot;

// The in-memory layout (4 slots). Kept in sync with the descriptor block.
typedef struct {
    int     valid;                    // 1 = a valid descriptor was loaded
    EosSlot slot[EOS_DESC_SLOTS];     // slots 0..3  == visible banks 1..4
} EosLayout;

// ---- lifecycle ------------------------------------------------------------

// Read + parse the descriptor from bank 0xF into `out`. If the block is blank
// or invalid, out->valid is set 0 and all slots are FREE (caller may then treat
// geometry as legacy/empty). Returns 1 if a valid descriptor was found, else 0.
int  Desc_Load(EosLayout* out);

// Serialize `lay` to the 64-byte format and write it to bank 0xF, then trigger
// the FPGA re-read. Returns 0 on success (EOS_FLASH_OK).
int  Desc_Save(const EosLayout* lay);

// Hard reset: erase the descriptor block -> blank -> legacy static geometry.
// Recovery for bad descriptor state. Does not touch BIOS banks or new region.
int  Desc_Erase(void);

// ---- budget / query -------------------------------------------------------

// Number of 256K slots a size code consumes against the 1MB budget.
int  Desc_SlotsFor(int sizeCode);          // 256K->1, 512K->2, 1MB->4

// Free slots remaining against the 1MB budget (counts FREE slots only; SHADOW
// and occupied slots are not free). Range 0..4.
int  Desc_FreeSlots(const EosLayout* lay);

// Can a bank of this size be placed right now? (enough contiguous/among-free
// budget). Returns 1 if it fits, else 0. If it fits, *anchorSlot receives the
// 0-based index of the first slot it would occupy.
int  Desc_CanPlace(const EosLayout* lay, int sizeCode, int* anchorSlot);

// ---- mutation (in-memory; call Desc_Save to persist) ----------------------

// Place a native 256K bank at the first free slot. Returns slot index or -1.
int  Desc_PlaceNative(EosLayout* lay, unsigned int physBaseRelFloor);

// Place an oversized (512K/1MB) bank at a SPECIFIC visible slot (overwrite: the
// target footprint is freed first). Enforces the alignment ruleset. Returns the
// new-region byte offset (rel FLOOR) to write the bytes to, or (unsigned)-1.
unsigned int Desc_PlaceOversizedAt(EosLayout* lay, int slot, int sizeCode);

// Legacy: place at the first legal anchor slot. Returns anchor slot or -1.
int  Desc_PlaceOversized(EosLayout* lay, int sizeCode, unsigned int newRegionBaseRelFloor);

// Free a slot (and, if it was an anchor, its shadow slots). Returns 1 if freed.
int  Desc_FreeSlot(EosLayout* lay, int slot);

// Free any bank whose footprint overlaps [at, at+need). Used to OVERWRITE a
// slot/run without a manual delete first. Returns # of banks freed.
int  Desc_FreeFootprint(EosLayout* lay, int at, int need);

// Compute the new-region byte offset (relative to FLOOR) for an oversized
// bank anchored at `slot` with `sizeCode`. 512K@slot0/1 -> +0, 512K@slot2/3
// -> +0x80000, 1MB -> +0. Returns the absolute-rel-FLOOR base.
unsigned int Desc_NewRegionBase(int slot, int sizeCode);

// Validate placing `sizeCode` at a SPECIFIC visible `slot` per the ruleset:
//   256K: any slot; 512K: even slot (0 or 2) only, needs slot+next free after
//   an overwrite-free of the target footprint; 1MB: slot 0, whole budget.
// Returns 1 if allowed (after conceptually freeing the target footprint).
int  Desc_CanPlaceAt(const EosLayout* lay, int slot, int sizeCode);

// Initialize an empty (all-free) layout.
void Desc_InitEmpty(EosLayout* lay);