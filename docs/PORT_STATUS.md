# Hakchi2-CE feature parity

This file tracks the port of Hakchi2-CE (C#, Windows) to Swift Hakchi2.
Reference source: <https://github.com/TeamShinkansen/Hakchi2-CE> (`hakchi_gui/`).

Legend: ✅ done · 🚧 in progress · ⬜ not started · ➖ not ported (Windows-only or obsolete, with the reason)

## Phase 1 — Foundation and emulation cores

| Feature | CE source | Status |
|---|---|---|
| System table (extensions, default core, code prefix, legacy execs) | `Apps/AppTypeCollection.cs` | ✅ |
| Core collection: built-in cores, `.info` files from the console (`/etc/libretro/info`), local `info/` folder, offline cache | `Apps/CoreCollection.cs`, `BuiltInCores.cs`, `CoreCommands.cs` | ✅ |
| Per-game `metadata.json` (System, Core, OriginalFilename, OriginalCrc32, CustomCoverArt) | `Apps/NesApplication.cs` | ✅ |
| `.desktop` round-trip keeps every field; Exec split into bin + args | `Apps/DesktopFile.cs` | ✅ |
| Sync uses each game's own Exec (only path prefixes are rewritten) | `Tasks/SyncTask.cs` | ✅ |
| Import: system detection by extension, CE default command lines, works offline | `NesApplication.Import` | ✅ |
| Import: unpack `.zip` / `.7z` (pick file when several) | `Tasks/AddGamesTask.cs` | ✅ |
| Multi-select in the games grid | `MainForm` | ✅ |
| Select emulation core dialog (context menu + after import for unknown systems) | `SelectCoreDialog.cs` | ✅ |
| `.clvg` game archive import, `.desktop` folder import, `.cue`/`.gdi`/`.m3u` multi-file games | `AddGamesTask`, `GetGameFiles` | ✅ |
| Repair games (automatic migration of older libraries; manual command in Phase 3) | `NesApplication.Repair` | 🚧 |

## Phase 2 — Sync engine

| Feature | CE source | Status |
|---|---|---|
| Incremental sync (remote file diff, upload only changes, cleanup) | `Tasks/SyncTask.cs` | ⬜ |
| Menu structure modes (no split, pages, folders, by letter, original games in root…) | `NesMenuCollection.Split` | ⬜ |
| Max games per folder, back button position, home folder, folder image sets | `ConfigIni`, `NesMenuFolder.cs` | ⬜ |
| Separate games for multiboot (`<sync>/<system-code>`) | `SyncTask` | ⬜ |
| Linked sync (`.storage`) on/off, always copy original games | `SyncTask` | ⬜ |
| Free-space check (memory stats) | `MemoryStats.cs` | ⬜ |
| Push console settings (`cfg_*`) after sync | `hakchi.SyncConfig` | ⬜ |
| Compress / decompress games (7z) | `NesApplication.Compress` | ⬜ |

## Phase 3 — Library and UI

| Feature | CE source | Status |
|---|---|---|
| Folders Manager (tree editor, auto-structure buttons, `folders*.htm`) | `FoldersManagerForm.cs` | ⬜ |
| Selection presets | `MainForm` | ⬜ |
| View: original games position, sort by name/core/console/region, group without box art | `MainForm` | ⬜ |
| Context menu: add/remove prefix, set region, archive `.clvg`, compress, delete box art, scan box art, repair games, show in Finder | `MainForm` | ⬜ |
| Detail panel: sort name, copyright, region, save count, compress toggle, size, cover from file/paste/drop | `MainForm` | ⬜ |
| Add custom app | `NewCustomGameForm.cs` | ⬜ |
| Restore original games | `MainForm` | ⬜ |
| Cover matching from local `art/` folder, prepare art folders | `NesApplication.FindCover`, `SelectSystemDialog` | ⬜ |
| IPS patches | `NesApplication.FindPatch` | ✅ |
| NES iNES checks, FDS header strip, SNES → SFROM conversion | `NesGame`, `FdsGame`, `SnesGame` | ✅ |
| Separate local game storage per console family | `ConfigIni.SeparateGameLocalStorage` | ⬜ |
| Game Genie codes | `GameGenie*` (disabled in CE) | ⬜ |

## Phase 4 — Settings

| Feature | CE source | Status |
|---|---|---|
| Controller hacks (reset combo, autofire, X/Y autofire, Famicom start) | `ConfigIni.consoleSettings` | ⬜ |
| Disable epilepsy protection, global extra command-line args | `ConfigIni` | ⬜ |
| Compress games / box art, center thumbnail, convert to SFROM, import scraper | `ConfigIni` | ⬜ |
| SEGA UI theme (Mega Drive) | `MainForm` | ⬜ |
| Save settings to mini now | `MainForm` | ⬜ |
| hakchi + romfiles.xml update check | `MainForm` | ⬜ |

## Phase 5 — Tools

| Feature | CE source | Status |
|---|---|---|
| Save-state manager (list, export/import `.clvs`, delete, screenshots of the selected save) | `SaveStateManager.cs` | ✅ |
| Take screenshot (framebuffer; copy, save, auto refresh) | `ScreenshotForm.cs` | ✅ |
| Save dmesg output | `MainForm` | ✅ |
| Boot splash: change / disable / reset | `MainForm` | ✅ |
| Switch running firmware (`.hsqs`) | `SelectFirmwareDialog.cs` | ✅ |
| Technical information (incl. memory stats, console settings, log; copy for bug reports) | `TechInfo.cs`, `MemoryStats.cs` | ✅ |
| Terminal (line-mode PTY shell) and console file browser — replace PuTTY and the FTP client | `MainForm` | ✅ |
| Format SD card (non-bootable layout, copy/store saves) | `Tasks/SDFormat` | ✅ |
| Format SD card: "Make card bootable" / "Copy everything from NAND" | `Tasks/SDFormat` | ➖ CE's own code no longer prepares the `/sd-temp` files this needs |
| Export games to a USB/SD volume (saves folder, linked export) — flat layout until the sync menu builder lands | `ExportGamesDialog.cs` | 🚧 |
| Help: Important message (MOTD), Technical information, project links | `MainForm`, `Motd.cs` | ✅ |
| Startup update of hakchi.hmod (`data/hakchi-latest.hmod`) and `romfiles.xml` | `MainForm` | ✅ |

## Phase 6 — Kernel and recovery

| Feature | CE source | Status |
|---|---|---|
| Recovery entry: shell memboot (kexec + detached-fallback) when online, FEL otherwise; "Recovery mode" title | `MembootTasks` | ✅ |
| Reset (reinstall with `mod_uninstall reset`) | `MembootTasks` | ✅ |
| Uninstall (flashes the stock kernel back) and "with kernel file" variant | `MembootTasks` | ✅ |
| Factory reset and "with kernel file" variant | `MembootTasks` | ✅ |
| Boot original / custom / recovery kernel from RAM | `MembootTasks` | ✅ |
| Dump original kernel (legacy) | `MembootTasks` | ✅ |
| Dump whole NAND (streamed to disk) | `MembootTasks` | ✅ |
| Dump / flash decrypted system software (incl. cryptsetup key-file, mksquashfs) | `MembootTasks` | ✅ |
| Dump / flash / format user data partition | `MembootTasks` | ✅ |
| Flash U-Boot normal / SD mode (Developer Tools, ⌃⌥⌘D) | `MembootTasks` | ✅ |
| Mega Drive rootfs check (Project Lunar, known system hashes) | `MembootTasks.CheckMdRootfs` | ✅ |
| Reboot in recovery offers to finish the boot sequence | `MainForm` | ✅ |

## Phase 7 — Modules

| Feature | CE source | Status |
|---|---|---|
| Mod Hub browse + install | `ModHub/` | ✅ |
| Local module library (`user_mods/`), install from library | `Hmod/SelectForm` | ⬜ |
| Uninstall modules | `ModTasks` | ✅ |
| Repository manager (add/edit/delete/reorder, `.hrepo` drop) | `RepoManagementForm.cs` | ⬜ |
| Mod Hub games tab (`.clvg`) | `ModHub/` | ⬜ |
| Modules report (HTML) | `MainForm` | ⬜ |
| Bluetooth controller pairing | `Wireless/Bluetooth` | ⬜ |

## Not ported

| Feature | Reason |
|---|---|
| FEL driver install (libwdi) | Windows-only; macOS needs no driver |
| SFROM Tool integration, PCM patch | Third-party Windows `.exe` |
| AutoUpdater.NET app updates | Windows-only; releases are on GitHub |
| Clovershell transport | Obsolete; hakchi uses RNDIS/SSH |
| Flash the whole NAND | Not implemented in CE either |
| Google Images box-art scraping | Scrapes Google's HTML (fragile, against its terms); TheGamesDB covers this |
