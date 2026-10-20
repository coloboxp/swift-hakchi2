/*
 * Minimal wrapper around the LZMA SDK encoder (public domain, see ../README.md).
 * Only this header is exposed to Swift as the `LzmaSDK` module.
 */
#ifndef LZMA_SHIM_H
#define LZMA_SHIM_H

#include <stddef.h>
#include <stdint.h>

#define LZMA_SHIM_PROPS_SIZE 5

/*
 * Compress `src` as a raw LZMA stream (no header, no end marker), the way 7z
 * stores LZMA data. Uses the SDK default properties (level 5) like tiny7z,
 * with the dictionary reduced to the input size.
 *
 * dest/destLen: output buffer and its capacity; on success destLen is the
 *               compressed size.
 * props:        receives the 5 LZMA property bytes (stored in the 7z header).
 * Returns 0 on success, otherwise an SDK SRes error code
 * (7 = output buffer too small).
 */
int lzma_shim_encode(const uint8_t *src, size_t srcLen,
                     uint8_t *dest, size_t *destLen,
                     uint8_t props[LZMA_SHIM_PROPS_SIZE]);

#endif
