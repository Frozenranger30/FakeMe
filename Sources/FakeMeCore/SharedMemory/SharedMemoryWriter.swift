import Foundation
import CoreVideo
import Darwin
import FakeMeCBridge

/// Writes rendered CVPixelBuffers into POSIX shared memory so the DAL plugin can read them.
/// Layout matches FakeMeSharedFrame.h:
///   offset  0: writeIndex (UInt64, atomic)
///   offset  8: width  (UInt32)
///   offset 12: height (UInt32)
///   offset 16: bytesPerRow (UInt32)
///   offset 20: pixels (BGRA, width * height * 4 bytes)
public final class SharedMemoryWriter {
    private static let shmName  = "/com.fakeme.sharedframe"
    private static let width    = 1280
    private static let height   = 720
    private static let bpr      = width * 4
    private static let frameSz  = height * bpr
    private static let totalSz  = 20 + frameSz   // header + pixels

    private var fd: Int32 = -1
    private var base: UnsafeMutableRawPointer?

    public init() {}

    @discardableResult
    public func open() -> Bool {
        fd = fakeme_shm_create()
        guard fd >= 0 else { return false }
        ftruncate(fd, off_t(Self.totalSz))
        let mapped = mmap(nil, Self.totalSz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard mapped != MAP_FAILED else {
            Darwin.close(fd); fd = -1; return false
        }
        base = mapped
        // Write static header
        base!.storeBytes(of: UInt64(0),              toByteOffset:  0, as: UInt64.self)
        base!.storeBytes(of: UInt32(Self.width),     toByteOffset:  8, as: UInt32.self)
        base!.storeBytes(of: UInt32(Self.height),    toByteOffset: 12, as: UInt32.self)
        base!.storeBytes(of: UInt32(Self.bpr),       toByteOffset: 16, as: UInt32.self)
        return true
    }

    /// Write a CVPixelBuffer into shared memory. Callable from any thread.
    public func write(_ pixelBuffer: CVPixelBuffer) {
        guard let base else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let src = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let srcBPR = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let srcH   = CVPixelBufferGetHeight(pixelBuffer)
        let copyH  = min(srcH, Self.height)
        let copyW  = min(srcBPR, Self.bpr)
        let dst    = base + 20  // skip 20-byte header

        if srcBPR == Self.bpr {
            dst.copyMemory(from: src, byteCount: copyH * Self.bpr)
        } else {
            for row in 0..<copyH {
                (dst + row * Self.bpr).copyMemory(from: src + row * srcBPR, byteCount: copyW)
            }
        }

        // Release fence: pixels must be visible before writeIndex increments
        OSMemoryBarrier()
        let idxPtr = base.assumingMemoryBound(to: UInt64.self)
        idxPtr.pointee &+= 1
    }

    public func close() {
        if let b = base { munmap(b, Self.totalSz); base = nil }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        fakeme_shm_unlink()
    }

    deinit { close() }
}
