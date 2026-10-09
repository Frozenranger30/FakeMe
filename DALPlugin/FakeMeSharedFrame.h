#pragma once
#include <stdint.h>
#include <stdatomic.h>

// Shared memory name and layout — used by both the DAL plugin (C) and the Swift app.
#define FAKEME_SHM_NAME   "/com.fakeme.sharedframe"
#define FAKEME_WIDTH      1280
#define FAKEME_HEIGHT     720
#define FAKEME_BPR        (FAKEME_WIDTH * 4)           // bytes per row (BGRA)
#define FAKEME_FRAME_SZ   (FAKEME_HEIGHT * FAKEME_BPR) // one raw frame
#define FAKEME_SHM_SZ     (sizeof(FakeMeSharedFrame))

#pragma pack(push, 1)
typedef struct {
    _Atomic(uint64_t) writeIndex;   // incremented after each complete frame write
    uint32_t          width;
    uint32_t          height;
    uint32_t          bytesPerRow;
    uint8_t           pixels[FAKEME_FRAME_SZ]; // BGRA row-major
} FakeMeSharedFrame;
#pragma pack(pop)
