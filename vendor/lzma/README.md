# LZMA SDK (encoder only)

Used to write `.7z` game archives (Hakchi2-CE's "Compress games"), because
SWCompression can read 7z but not write it.

- **Source:** official 7-Zip repository by Igor Pavlov, <https://github.com/ip7z/7zip>,
  tag `26.04`, folder `C/`. Files: `LzmaEnc.c/.h`, `LzFind.c/.h`, `LzFindOpt.c`,
  `LzFindMt.h`, `LzHash.h`, `CpuArch.c/.h`, `7zTypes.h`, `7zWindows.h`, `Precomp.h`,
  `Compiler.h`, `RotateDefs.h`. They are unmodified.
- **License:** public domain. Every file header says "Igor Pavlov : Public domain",
  and the LZMA SDK page (<https://www.7-zip.org/sdk.html>) states that the LZMA SDK
  is placed in the public domain.
- **Build:** compiled single-threaded (`Z7_ST`). `src/lzma_shim.c` (ours) wraps
  `LzmaEncode` with malloc-based allocators; only `include/lzma_shim.h` is exposed
  to Swift as the `LzmaSDK` module.
