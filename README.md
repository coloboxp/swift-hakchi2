# Swift Hakchi2

A native macOS application for modding Nintendo mini consoles, built with Swift and SwiftUI. It is a ground-up rewrite of [Hakchi2 CE](https://github.com/TeamShinkansen/Hakchi2-CE) for macOS.

## About this fork

> **In short: this version does a lot more than the original Swift Hakchi2.** It can do almost everything the Windows program Hakchi2 CE can do, on a Mac. Get it from this fork's [Releases](https://github.com/coloboxp/swift-hakchi2/releases) page (v2.0.0 and later).

This is a personal fork of [mattackerman808/swift-hakchi2](https://github.com/mattackerman808/swift-hakchi2). The original app (v1.0) was a great start: it could install hakchi, add games and copy them to the console. This fork carries on from there and fills in the rest of Hakchi2 CE. It is maintained on its own and will not be merged back into the original project.

### What you get here that the original does not have

| | Original (v1.0) | This fork (v2.0) |
|---|---|---|
| Installing mods (hmods) | The install buttons did nothing | Works, from several online repositories or your own files |
| Copying games to the console | Wipes the game folder and uploads everything each time | Only uploads what changed, and never deletes games it can't put back |
| Getting games back from the console | Big games failed | Downloads games of any size |
| Picking the emulator for a game | Not possible | Choose the emulator (core) for each game |
| Kinds of games you can add | A few ROM types for a few consoles | About 20 systems, archives, CD images, game packs, patches and Game Genie codes |
| Folders on the console menu | All your games in one "More games" folder | Folders or pages, or your own folder layout |
| Console options and controller tweaks | Not possible | Set them from the app |
| Save states, screenshots, boot splash, SD cards | Not possible | All in the Tools menu |
| Fixing a broken console | Uninstall, factory reset and a kernel backup | Every recovery tool from Hakchi2 CE, such as starting from a rescue kernel and full backups |

Only the parts of Hakchi2 CE that make sense on Windows alone, or that are out of date, were left out. [`docs/PORT_STATUS.md`](docs/PORT_STATUS.md) lists every feature, what was left out and why, and which tests and validations are still missing.

## Supported Consoles

- NES Classic / Famicom Mini
- SNES Classic (USA / EUR) / Super Famicom Mini

## Features

- **Custom kernel** — install, repair, uninstall and factory reset, plus recovery tasks: boot kernels from RAM, dump and flash partitions, flash U-Boot
- **Game library** — import ROMs, archives, `.clvg` packs and CD images (`.cue`, `.gdi`, `.m3u`) for about 20 systems; CRC32 matching for name, publisher and box art; IPS patches; Game Genie codes; optional `.7z` compression
- **Emulation cores** — choose the libretro core per game; the list is read from the connected console
- **Incremental sync** — uploads only what changed; games with no local ROM keep their files on the console
- **Menu structure** — folders or pages with a game limit, a custom tree in the Folders Manager, folder images and selection presets
- **Console settings** — controller hacks and console options, read from and written to the console
- **Modules** — installed modules, a local module library, several online repositories, and Bluetooth pairing
- **Tools** — save-state manager, screenshots, a terminal and a file browser, boot splash, firmware switch, export to USB/SD and SD card formatting
- **Scraper** — search TheGamesDB for cover art, descriptions and metadata

## Requirements

- macOS 14.0 (Sonoma) or later
- Swift 5.9+
- USB-A cable (or USB-C adapter) to connect to the console

## Installation

Download the latest `.zip` from this fork's [Releases](https://github.com/coloboxp/swift-hakchi2/releases), extract it, and double-click **Swift Hakchi2.app**. The build is for Apple Silicon Macs. The releases of the original project do not contain the changes from this fork. You can also build it yourself (see [Building](#building)); `./install.sh` puts the app in `/Applications`.

Because the app is not signed with an Apple Developer certificate, macOS will block it on first launch. To allow it:

1. Open **System Settings > Privacy & Security**
2. Scroll down to **Security**
3. Click **Open Anyway** next to the message about Swift Hakchi2, or change the **Allow applications from** setting to include the app

Alternatively, right-click the app and choose **Open** to bypass the warning once.

## Building

Clone the repository and run:

```bash
git clone https://github.com/coloboxp/swift-hakchi2.git
cd swift-hakchi2
./run.sh
```

This builds the project, assembles a `.app` bundle, and launches it. To build a release copy and install it to `/Applications`:

```bash
./install.sh
```

For build-only or tests:

```bash
swift build              # Debug
swift build -c release   # Release
./scripts/test.sh        # Unit tests
HAKCHI_LIVE_TESTS=1 ./scripts/test.sh   # Also test against the live KMFD mod repository
```

**Command Line Tools only (no Xcode):** the macOS 27 SDK makes SwiftUI's `@State` a macro, and the Command Line Tools do not include the plugin that expands it. `run.sh` and `install.sh` switch to the newest installed macOS 26 SDK in that case (see `scripts/select-sdk.sh`). When you run `swift build` yourself, set it by hand:

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build
```

## Usage

### Window Layout

The main window is organized top to bottom:

1. **Action Bar** — Buttons for **Install Kernel**, **Connect/Disconnect**, **Memboot**, and **Reboot**
2. **Games Explorer** — Your ROM library displayed as a grid of cover art cards (left), with an editable detail panel (right). The header has **Add ROMs** and **Import from Console** buttons, plus a search field. You can select several games at once (Cmd-click or Shift-click).
3. **Console Game Bar** — A tray along the bottom labeled "Desired Console Config" that shows which games will be on your console after the next sync. Has **Custom Games** and **Default Games** tabs, and a centered **Sync** button.
4. **Status Bar** — Connection indicator (green = connected, orange = FEL mode, red = disconnected), console type, and game counts.

### Flashing the Console

1. Click **Install Kernel** in the action bar
2. Choose whether to back up the stock kernel (recommended for first-time setup)
3. If the console isn't in FEL mode, the app shows instructions and waits:
   - Power off the console and unplug USB
   - Hold the **RESET** button on the console
   - While holding RESET, plug in the USB cable
   - Release after 3 seconds
4. The app flashes the custom kernel automatically once the console is detected

Other kernel tasks are in the **Kernel** menu: Reset, Uninstall, Factory Reset (also with a kernel file you choose), Reboot and Shutdown. **Kernel > Advanced** has the recovery tasks: boot the original, custom or recovery kernel from RAM, dump the kernel or the whole NAND, dump and flash the system software and the user data partition, format user data, and flash U-Boot. Try the harmless ones (boot from RAM, dumps) before anything that writes to flash.

### Managing Games

- **Add ROMs** — Click "Add ROMs" in the Games Explorer header, or use **File > Add Games...**. ROMs, archives (`.zip`, `.7z`; RAR is not supported), `.clvg` packs, `.desktop` files and CD images are accepted. When a file fits more than one system, the app asks which one. **Add Games As-Is...** skips patching and compression.
- **Import from Console** — Copies existing custom games from a connected console into your library, including large ROMs
- **Emulation core** — Select one or more games and choose **Game > Select Emulation Core...** to change the libretro core and its command-line options
- **Game Genie** — Codes are stored per game and applied to a copy of the ROM during sync; the library file is not changed
- **Auto-matching** — Imported ROMs are matched by CRC32 against a built-in database to fill in name, publisher, release date, and cover art
- **Edit details** — Click any game card to select it. The detail panel shows editable fields for name, publisher, genre, release date, players, command line, and description. Click "Save" to persist changes.
- **Scraper** — Select a game and click "Search Online..." in the detail panel to search TheGamesDB for metadata and cover art. Requires an API key (see Settings).
- **Delete** — Right-click a game card and choose "Delete Game..." to remove it from the library (your original ROM file is not affected)

### Syncing Games to the Console

1. **Drag** game cards from the Games Explorer down into the Console Game Bar
2. The Console Game Bar shows your desired configuration — Custom Games tab for your imports, Default Games tab for stock titles
3. To remove a game, drag it off the Console Game Bar back up into the explorer area (a "Remove" label follows your cursor and a poof animation plays on drop)
4. Stock games can be hidden by dragging them off, or re-enabled via right-click → "Re-enable"
5. Click the **Sync** button in the Console Game Bar to upload everything to the console

Sync is incremental: the app compares the files on the console with the local ones and uploads only what changed. If a selected game has no ROM on the Mac, its files on the console are kept and the app warns you. The console has about 300 MB of usable storage.

### Menu Structure

The **Structure** menu decides how games appear on the console:

- **Maximum Games per Page/Folder** — split the list into pages or folders, or keep one page
- **Folders Manager...** — build your own folder tree; it is used when the folders mode is set to custom
- **Back Folder Button Position** and **Folder Images Set** — how folders look
- **Selection Presets** — save and restore which games are selected

### Modules (hmods)

Open the **Module Manager** from the Modules menu (Cmd+Shift+M):

- **Installed** — modules on the console; select any to uninstall
- **Library** — `.hmod` files you keep on the Mac, ready to install
- **Mod Hub** — browse the configured repositories (the KMFD repository by default). Add or remove repositories with **Modules > Manage Repositories...**
- **Apply & Reboot** — Installs and removals are staged on the console first. Click "Apply & Reboot": hakchi applies the changes while the console boots, then reboots once more. This takes about a minute.

The Modules menu also has **Bluetooth...** for pairing controllers and **Generate Modules Report...**.

### Tools

The **Tools** menu has a save-state manager, screenshots, dmesg output, a **Terminal** and a **Console Files** browser (instead of PuTTY and FTP), the boot splash, **Switch Running Firmware...**, **Export Games...** to a USB stick or SD card, and **Format SD Card...**.

### Settings

Open from the Swift Hakchi2 menu (Cmd+,):

- **Console** — Default console type (NES/SNES/Famicom/Super Famicom), TheGamesDB API key, and "Enrich Library Now" to fetch metadata for the whole library
- **Storage** — Upload games compressed, separate game storage per console, max game size (MB), and games folder path
- **Library** — What happens when games are added (7z compression, on by default as in CE; box-art options; SFROM conversion; online lookup), and how the explorer shows and sorts games
- **Advanced** — Purge all cover art (re-downloads from database), purge all imported games (clears library, does not delete original ROM files)
- **Console Settings** — Controller hacks and console options, read from the console when it connects and saved to it after a sync

## How It Works

The app communicates with the console through two USB protocols:

1. **FEL Mode** — When the console is in its Allwinner bootloader, the app uses the FEL protocol to initialize DRAM and boot a custom kernel image. The user enters FEL mode by holding Reset while powering on.

2. **RNDIS/SSH** — After memboot, the console exposes a USB RNDIS network gadget. The app runs a user-space TCP/IP stack over this link and opens an SSH session to execute commands and transfer files — no network drivers or kernel extensions required.

## Project Structure

```
SwiftHakchi/          Swift application
├── App/              Entry point and AppState (global coordinator)
├── Models/           Data models (Game, ConsoleType, DesktopFile, AppConfig)
├── Services/         Actor-based business logic (device, flash, games, SSH, FEL)
├── Views/            SwiftUI interface
├── Utilities/        Helpers (TarWriter, CRC32, Game Genie codecs, NES/FDS/SNES ROM formats, IPS)
└── Resources/        Binary payloads (fes1.bin, hakchi.hmod, basehmods.tar)

USBBridge/            C library — USB and network protocol stack
├── src/              IOKit USB, FEL, RNDIS, TCP/IP, SSH bridge, Clovershell
└── include/          Public headers consumed by Swift

vendor/               Vendored C dependencies
├── mbedtls/          MBedTLS (cryptography, used by libssh2)
├── libssh2/          LibSSH2 (SSH protocol)
└── lzma/             LZMA SDK (public domain, used to write .7z archives)

Tests/SwiftHakchiTests/   Unit tests (Swift Testing)
docs/PORT_STATUS.md       Hakchi2 CE feature parity, missing validations
```

## License

This project is not affiliated with Nintendo. Use at your own risk.
