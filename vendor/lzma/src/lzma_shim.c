/* Wrapper around LzmaEncode with malloc-based allocators. See lzma_shim.h. */
#include <stdlib.h>

#include "../include/lzma_shim.h"
#include "LzmaEnc.h"

static void *ShimAlloc(ISzAllocPtr p, size_t size) {
    (void)p;
    return size == 0 ? NULL : malloc(size);
}

static void ShimFree(ISzAllocPtr p, void *address) {
    (void)p;
    free(address);
}

static const ISzAlloc g_Alloc = { ShimAlloc, ShimFree };

int lzma_shim_encode(const uint8_t *src, size_t srcLen,
                     uint8_t *dest, size_t *destLen,
                     uint8_t props[LZMA_SHIM_PROPS_SIZE]) {
    CLzmaEncProps encProps;
    LzmaEncProps_Init(&encProps);
    /* Default level 5, single thread; shrink the dictionary for small inputs
       so the console needs less memory to decode */
    encProps.reduceSize = srcLen;
    encProps.numThreads = 1;

    SizeT outLen = *destLen;
    SizeT propsSize = LZMA_SHIM_PROPS_SIZE;
    SRes res = LzmaEncode(dest, &outLen, src, srcLen, &encProps, props, &propsSize,
                          0 /* no end marker */, NULL, &g_Alloc, &g_Alloc);
    *destLen = outLen;
    return res;
}
