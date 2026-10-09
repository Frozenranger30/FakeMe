#include "include/FakeMeCBridge.h"
#include <sys/mman.h>
#include <fcntl.h>

#define FAKEME_SHM_NAME  "/com.fakeme.sharedframe"
#define FAKEME_WIDTH     1280
#define FAKEME_HEIGHT    720
#define FAKEME_BPR       (FAKEME_WIDTH * 4)
#define FAKEME_FRAME_SZ  (FAKEME_HEIGHT * FAKEME_BPR)
// header: 8 (writeIndex) + 4 (width) + 4 (height) + 4 (bytesPerRow) = 20 bytes
#define FAKEME_HEADER_SZ 20
#define FAKEME_TOTAL_SZ  (FAKEME_HEADER_SZ + FAKEME_FRAME_SZ)

int fakeme_shm_create(void) {
    return shm_open(FAKEME_SHM_NAME, O_CREAT | O_RDWR, 0600);
}

int fakeme_shm_open_read(void) {
    return shm_open(FAKEME_SHM_NAME, O_RDONLY, 0600);
}

void fakeme_shm_unlink(void) {
    shm_unlink(FAKEME_SHM_NAME);
}

uint64_t fakeme_shm_size(void) {
    return (uint64_t)FAKEME_TOTAL_SZ;
}
