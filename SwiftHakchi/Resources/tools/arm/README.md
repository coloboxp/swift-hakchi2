# ARM helper tools

These ARM Linux binaries are uploaded to the console for recovery tasks. They are
copied unchanged from the Hakchi2-CE repository
(<https://github.com/TeamShinkansen/Hakchi2-CE>, `hakchi_gui/tools/arm/` and
`tools/mksquashfs`), which redistributes them the same way.

| File | Used for | Upstream project (license) |
|---|---|---|
| `kexec.static` | Memboot from a running console (shell memboot) | kexec-tools (GPL-2.0) |
| `unpackbootimg.static` | Boot the original kernel when no backup2 exists | AOSP mkbootimg tools (Apache-2.0) |
| `sfdisk.static` | Partition an SD card | util-linux (GPL-2.0) |
| `mke2fs.static` | Format an SD card | e2fsprogs (GPL-2.0) |
| `mksquashfs` | Dump the system software as `.hsqs` | squashfs-tools (GPL-2.0) |

`detached-fallback` is not copied here: it is read from the bundled `hakchi.hmod`
(`bin/detached-fallback`, identical to <https://hakchi.net/hakchi/detached-fallback>).
