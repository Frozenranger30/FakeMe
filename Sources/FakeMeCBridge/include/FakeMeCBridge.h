#pragma once
#include <stdint.h>

// Thin C wrappers around variadic POSIX calls that Swift cannot call directly.

/// Opens (or creates) the FakeMe shared memory segment for read+write.
/// Returns the file descriptor, or -1 on error.
int fakeme_shm_create(void);

/// Opens the FakeMe shared memory segment read-only.
/// Returns the file descriptor, or -1 on error.
int fakeme_shm_open_read(void);

/// Unlinks (removes) the shared memory segment.
void fakeme_shm_unlink(void);

/// Returns the expected total byte size of the shared memory region.
uint64_t fakeme_shm_size(void);
