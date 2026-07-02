// eos_config.h -- Eos loader config persistence (Eos flash config bank).
//
// Single source of truth for per-bank {occupied, size, name}. Stored on a
// dedicated config bank that the FPGA flash engine can reach but never serves
// (config bank 0xB, above the served 2MB range). Read back via the engine read
// path, so names travel with the chip across consoles. The loader calls
// Config_Load() once at boot and Config_Save() after any rename / flash /
// delete so the launch list, management view, and HTTP all read the same table.
#pragma once

#define EOS_CONFIG_BANK   0x0B   // bank table  (engine-reachable, not served)
#define EOS_SETTINGS_BANK 0x0C   // settings    (separate 64K erase block)

// Read both config regions into the bank table + settings cache. Returns 0 if a
// valid bank record was loaded, <0 if absent/invalid (in-RAM defaults kept).
int Config_Load(void);

// Serialize the BANK TABLE to bank 0xB (erase + program + verify). Settings are
// untouched -- they live in their own erase block. Returns 0 / EOS_FLASH_* error.
int Config_Save(void);

// Serialize the SETTINGS block to bank 0xC. The bank table is untouched.
int Config_SaveSettings(void);
int Config_ClearAll(void);   // factory-reset both config banks
int Config_ResetSettings(void);   // reset settings block (0xC) only; banks untouched

// --- persisted loader settings (stored in the settings block, bank 0xC) ------
int  Config_GetThemeIdx(void);
void Config_SetThemeIdx(int idx);   // clamps, persists settings only

// Background music (persisted in the settings block). Enable flag + one selected
// track path. Setters persist immediately (settings bank only).
#define EOS_BGM_PATH_MAX 224
int         Config_GetBgmOn(void);
void        Config_SetBgmOn(int on);
const char* Config_GetBgmPath(void);
void        Config_SetBgmPath(const char* path);