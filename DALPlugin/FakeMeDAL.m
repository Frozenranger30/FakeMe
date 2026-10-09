// FakeMeDAL.m — CoreMediaIO DAL Plugin (FakeMe Virtual Camera)
// Reads frames from POSIX shared memory written by FakeMe.app.
// No Developer Account required — DAL plugins load unsigned.
// Deprecated API, but still functional on macOS 12–15.

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreMediaIO/CMIOHardwarePlugIn.h>
#import <CoreMediaIO/CMIOSampleBuffer.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <dispatch/dispatch.h>
#import <sys/mman.h>
#import <fcntl.h>
#import "FakeMeSharedFrame.h"

// ── Object IDs ────────────────────────────────────────────────────────────────
#define kDeviceObjectID   ((CMIOObjectID)200)
#define kStreamObjectID   ((CMIOObjectID)201)

// ── Plugin-global state ────────────────────────────────────────────────────────
static CMIOHardwarePlugInRef  gPlugInRef      = NULL;
static CMIOObjectID           gPluginObjectID = 0;

static int                    gShmFd     = -1;
static FakeMeSharedFrame     *gShm       = NULL;

static CMSimpleQueueRef       gFrameQueue     = NULL;
static CMFormatDescriptionRef gFmtDesc        = NULL;
static dispatch_source_t      gFrameTimer     = NULL;
static uint64_t               gFrameSeq       = 0;
static uint64_t               gFrameCount     = 0;
static CMIODeviceStreamQueueAlteredProc gAlteredProc    = NULL;
static void                  *gAlteredRefCon  = NULL;

// ── Shared memory ─────────────────────────────────────────────────────────────
static void shmTryOpen(void) {
    if (gShm) return;
    gShmFd = shm_open(FAKEME_SHM_NAME, O_RDONLY, 0600);
    if (gShmFd < 0) return;
    gShm = mmap(NULL, FAKEME_SHM_SZ, PROT_READ, MAP_SHARED, gShmFd, 0);
    if (gShm == MAP_FAILED) {
        gShm = NULL; close(gShmFd); gShmFd = -1;
    }
}

// ── Format description ────────────────────────────────────────────────────────
static CMFormatDescriptionRef getFormatDesc(void) {
    if (!gFmtDesc) {
        CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
            kCVPixelFormatType_32BGRA, FAKEME_WIDTH, FAKEME_HEIGHT, NULL, &gFmtDesc);
    }
    return gFmtDesc;
}

// ── Frame delivery ────────────────────────────────────────────────────────────
static void deliverFrame(void) {
    if (!gFrameQueue) return;
    if (CMSimpleQueueGetCount(gFrameQueue) >= CMSimpleQueueGetCapacity(gFrameQueue)) return;

    shmTryOpen();

    CVPixelBufferRef pixBuf = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, FAKEME_WIDTH, FAKEME_HEIGHT,
        kCVPixelFormatType_32BGRA, NULL, &pixBuf);
    if (!pixBuf) return;

    CVPixelBufferLockBaseAddress(pixBuf, 0);
    void *dst = CVPixelBufferGetBaseAddress(pixBuf);
    if (dst) {
        if (gShm) memcpy(dst, (const void *)gShm->pixels, FAKEME_FRAME_SZ);
        else      memset(dst, 0, FAKEME_FRAME_SZ);
    }
    CVPixelBufferUnlockBaseAddress(pixBuf, 0);

    CMSampleTimingInfo timing = {
        .duration              = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMake((int64_t)gFrameCount++, 30),
        .decodeTimeStamp       = kCMTimeInvalid,
    };
    CMSampleBufferRef sampleBuf = NULL;
    OSStatus err = CMIOSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault, pixBuf, getFormatDesc(),
        &timing, gFrameSeq++, 0, &sampleBuf);
    CVPixelBufferRelease(pixBuf);

    if (err == noErr && sampleBuf) {
        CMSimpleQueueEnqueue(gFrameQueue, sampleBuf);
        CFRelease(sampleBuf);
        if (gAlteredProc) gAlteredProc(kStreamObjectID, gFrameQueue, gAlteredRefCon);
    }
}

// ── IUnknown ──────────────────────────────────────────────────────────────────
static HRESULT QueryInterface(void *self, REFIID iid, LPVOID *ppv) {
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, iid);
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(uuid, kCMIOHardwarePlugInTypeID)) { *ppv = self; r = S_OK; }
    CFRelease(uuid);
    return r;
}
static ULONG AddRef(void *s)  { (void)s; return 1; }
static ULONG Release(void *s) { (void)s; return 1; }

// ── Lifecycle ─────────────────────────────────────────────────────────────────
static OSStatus Initialize(CMIOHardwarePlugInRef self) {
    gPlugInRef = self;
    CMIOObjectID pub[] = { kDeviceObjectID };
    CMIOObjectsPublishedAndDied(self, gPluginObjectID, 1, pub, 0, NULL);
    CMIOObjectID stream[] = { kStreamObjectID };
    CMIOObjectsPublishedAndDied(self, kDeviceObjectID, 1, stream, 0, NULL);
    return noErr;
}

static OSStatus InitializeWithObjectID(CMIOHardwarePlugInRef self, CMIOObjectID objectID) {
    gPluginObjectID = objectID;
    return Initialize(self);
}

static OSStatus Teardown(CMIOHardwarePlugInRef self) {
    (void)self;
    if (gFrameTimer)  { dispatch_source_cancel(gFrameTimer); gFrameTimer = NULL; }
    if (gFrameQueue)  { CFRelease(gFrameQueue); gFrameQueue = NULL; }
    if (gFmtDesc)     { CFRelease(gFmtDesc);    gFmtDesc = NULL; }
    if (gShm)         { munmap(gShm, FAKEME_SHM_SZ); gShm = NULL; }
    if (gShmFd >= 0)  { close(gShmFd); gShmFd = -1; }
    return noErr;
}

static void ObjectShow(CMIOHardwarePlugInRef s, CMIOObjectID o) { (void)s;(void)o; }

// ── Properties ────────────────────────────────────────────────────────────────
static Boolean ObjectHasProperty(CMIOHardwarePlugInRef self, CMIOObjectID oid,
    const CMIOObjectPropertyAddress *a)
{
    (void)self;
    switch (oid) {
    case kDeviceObjectID:
        switch (a->mSelector) {
        case kCMIOObjectPropertyClass:
        case kCMIOObjectPropertyOwner:
        case kCMIOObjectPropertyName:
        case kCMIOObjectPropertyOwnedObjects:
        case kCMIODevicePropertyDeviceUID:
        case kCMIODevicePropertyDeviceIsAlive:
        case kCMIODevicePropertyDeviceHasChanged:
        case kCMIODevicePropertyTransportType:
        case kCMIODevicePropertyLinkedCoreAudioDeviceUID:
        case kCMIODevicePropertyStreams:            return TRUE;
        default:                                   return FALSE;
        }
    case kStreamObjectID:
        switch (a->mSelector) {
        case kCMIOObjectPropertyClass:
        case kCMIOObjectPropertyOwner:
        case kCMIOObjectPropertyName:
        case kCMIOObjectPropertyOwnedObjects:
        case kCMIOStreamPropertyDirection:
        case kCMIOStreamPropertyFormatDescription:
        case kCMIOStreamPropertyFormatDescriptions:
        case kCMIOStreamPropertyFrameRate:
        case kCMIOStreamPropertyFrameRates:
        case kCMIOStreamPropertyMinimumFrameRate:
        case kCMIOStreamPropertyFrameRateRanges:   return TRUE;
        default:                                   return FALSE;
        }
    default: // plugin object
        switch (a->mSelector) {
        case kCMIOObjectPropertyClass:
        case kCMIOObjectPropertyOwner:
        case kCMIOObjectPropertyOwnedObjects:
        case kCMIOPlugInPropertyBundleID:          return TRUE;
        default:                                   return FALSE;
        }
    }
}

static OSStatus ObjectIsPropertySettable(CMIOHardwarePlugInRef self, CMIOObjectID oid,
    const CMIOObjectPropertyAddress *a, Boolean *out)
{
    (void)self;(void)oid;(void)a; *out = FALSE; return noErr;
}

static OSStatus ObjectGetPropertyDataSize(CMIOHardwarePlugInRef self, CMIOObjectID oid,
    const CMIOObjectPropertyAddress *a,
    UInt32 qualSz, const void *qual, UInt32 *outSz)
{
    (void)self;(void)qualSz;(void)qual;
    switch (oid) {
    case kDeviceObjectID:
        switch (a->mSelector) {
        case kCMIOObjectPropertyClass:                    *outSz=sizeof(CMIOClassID); return noErr;
        case kCMIOObjectPropertyOwner:                    *outSz=sizeof(CMIOObjectID); return noErr;
        case kCMIOObjectPropertyName:                     *outSz=sizeof(CFStringRef); return noErr;
        case kCMIOObjectPropertyOwnedObjects:             *outSz=sizeof(CMIOObjectID); return noErr;
        case kCMIODevicePropertyDeviceUID:                *outSz=sizeof(CFStringRef); return noErr;
        case kCMIODevicePropertyDeviceIsAlive:            *outSz=sizeof(UInt32); return noErr;
        case kCMIODevicePropertyDeviceHasChanged:         *outSz=sizeof(UInt32); return noErr;
        case kCMIODevicePropertyTransportType:            *outSz=sizeof(UInt32); return noErr;
        case kCMIODevicePropertyLinkedCoreAudioDeviceUID: *outSz=sizeof(CFStringRef); return noErr;
        case kCMIODevicePropertyStreams:                  *outSz=sizeof(CMIOStreamID); return noErr;
        default: return kCMIOHardwareUnknownPropertyError;
        }
    case kStreamObjectID:
        switch (a->mSelector) {
        case kCMIOObjectPropertyClass:             *outSz=sizeof(CMIOClassID); return noErr;
        case kCMIOObjectPropertyOwner:             *outSz=sizeof(CMIOObjectID); return noErr;
        case kCMIOObjectPropertyName:              *outSz=sizeof(CFStringRef); return noErr;
        case kCMIOObjectPropertyOwnedObjects:      *outSz=0; return noErr;
        case kCMIOStreamPropertyDirection:         *outSz=sizeof(UInt32); return noErr;
        case kCMIOStreamPropertyFormatDescription:
        case kCMIOStreamPropertyFormatDescriptions:*outSz=sizeof(CFTypeRef); return noErr;
        case kCMIOStreamPropertyFrameRate:
        case kCMIOStreamPropertyFrameRates:
        case kCMIOStreamPropertyMinimumFrameRate:  *outSz=sizeof(Float64); return noErr;
        case kCMIOStreamPropertyFrameRateRanges:   *outSz=sizeof(AudioValueRange); return noErr;
        default: return kCMIOHardwareUnknownPropertyError;
        }
    default: // plugin
        switch (a->mSelector) {
        case kCMIOObjectPropertyClass:             *outSz=sizeof(CMIOClassID); return noErr;
        case kCMIOObjectPropertyOwner:             *outSz=sizeof(CMIOObjectID); return noErr;
        case kCMIOObjectPropertyOwnedObjects:      *outSz=sizeof(CMIOObjectID); return noErr;
        case kCMIOPlugInPropertyBundleID:          *outSz=sizeof(CFStringRef); return noErr;
        default: return kCMIOHardwareUnknownPropertyError;
        }
    }
}

static OSStatus ObjectGetPropertyData(CMIOHardwarePlugInRef self, CMIOObjectID oid,
    const CMIOObjectPropertyAddress *a,
    UInt32 qualSz, const void *qual,
    UInt32 inSz, UInt32 *outSz, void *out)
{
    (void)self;(void)qualSz;(void)qual;(void)inSz;
    #define STORE(val) do { typeof(val) _v = (val); memcpy(out, &_v, sizeof(_v)); *outSz = sizeof(_v); return noErr; } while(0)
    switch (oid) {
    case kDeviceObjectID:
        switch (a->mSelector) {
        case kCMIOObjectPropertyClass:                    STORE((CMIOClassID)kCMIODeviceClassID);
        case kCMIOObjectPropertyOwner:                    STORE((CMIOObjectID)(gPluginObjectID ? gPluginObjectID : 1));
        case kCMIOObjectPropertyName:                     STORE((CFStringRef)CFSTR("FakeMe Virtual Camera"));
        case kCMIOObjectPropertyOwnedObjects:             STORE((CMIOObjectID)kStreamObjectID);
        case kCMIODevicePropertyDeviceUID:                STORE((CFStringRef)CFSTR("FakeMeVirtualCamera-v1"));
        case kCMIODevicePropertyDeviceIsAlive:            STORE((UInt32)1);
        case kCMIODevicePropertyDeviceHasChanged:         STORE((UInt32)0);
        case kCMIODevicePropertyTransportType:            STORE((UInt32)0x76697274); // 'virt'
        case kCMIODevicePropertyLinkedCoreAudioDeviceUID: STORE((CFStringRef)CFSTR(""));
        case kCMIODevicePropertyStreams:                  STORE((CMIOStreamID)kStreamObjectID);
        default: return kCMIOHardwareUnknownPropertyError;
        }
    case kStreamObjectID:
        switch (a->mSelector) {
        case kCMIOObjectPropertyClass:   STORE((CMIOClassID)kCMIOStreamClassID);
        case kCMIOObjectPropertyOwner:   STORE((CMIOObjectID)kDeviceObjectID);
        case kCMIOObjectPropertyName:    STORE((CFStringRef)CFSTR("FakeMe Output"));
        case kCMIOObjectPropertyOwnedObjects: *outSz = 0; return noErr;
        case kCMIOStreamPropertyDirection: STORE((UInt32)1);
        case kCMIOStreamPropertyFormatDescription: STORE(getFormatDesc());
        case kCMIOStreamPropertyFormatDescriptions: {
            CMFormatDescriptionRef fmt = getFormatDesc();
            CFArrayRef arr = CFArrayCreate(NULL, (const void **)&fmt, 1, &kCFTypeArrayCallBacks);
            STORE(arr);
        }
        case kCMIOStreamPropertyFrameRate:
        case kCMIOStreamPropertyMinimumFrameRate: STORE((Float64)30.0);
        case kCMIOStreamPropertyFrameRates:       STORE((Float64)30.0);
        case kCMIOStreamPropertyFrameRateRanges: {
            AudioValueRange r = { .mMinimum=30.0, .mMaximum=30.0 };
            STORE(r);
        }
        default: return kCMIOHardwareUnknownPropertyError;
        }
    default: // plugin
        switch (a->mSelector) {
        case kCMIOObjectPropertyClass:        STORE((CMIOClassID)kCMIOPlugInClassID);
        case kCMIOObjectPropertyOwner:        STORE((CMIOObjectID)kCMIOObjectSystemObject);
        case kCMIOObjectPropertyOwnedObjects: STORE((CMIOObjectID)kDeviceObjectID);
        case kCMIOPlugInPropertyBundleID:     STORE((CFStringRef)CFSTR("com.fakeme.dal"));
        default: return kCMIOHardwareUnknownPropertyError;
        }
    }
    #undef STORE
}

static OSStatus ObjectSetPropertyData(CMIOHardwarePlugInRef s, CMIOObjectID o,
    const CMIOObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 ds, const void *d)
{
    (void)s;(void)o;(void)a;(void)qs;(void)q;(void)ds;(void)d;
    return kCMIOHardwareIllegalOperationError;
}

// ── Stream control ────────────────────────────────────────────────────────────
static OSStatus DeviceStartStream(CMIOHardwarePlugInRef s, CMIODeviceID d, CMIOStreamID st)
{
    (void)s;(void)d;(void)st;
    if (gFrameTimer) return noErr;
    dispatch_queue_t q = dispatch_queue_create("com.fakeme.dal.timer",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    gFrameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    uint64_t ns = (uint64_t)(NSEC_PER_SEC / 30);
    dispatch_source_set_timer(gFrameTimer, DISPATCH_TIME_NOW, ns, ns / 10);
    dispatch_source_set_event_handler(gFrameTimer, ^{ deliverFrame(); });
    dispatch_resume(gFrameTimer);
    return noErr;
}

static OSStatus DeviceStopStream(CMIOHardwarePlugInRef s, CMIODeviceID d, CMIOStreamID st)
{
    (void)s;(void)d;(void)st;
    if (gFrameTimer) { dispatch_source_cancel(gFrameTimer); gFrameTimer = NULL; }
    return noErr;
}

static OSStatus DeviceSuspend(CMIOHardwarePlugInRef s, CMIODeviceID d) { (void)s;(void)d; return noErr; }
static OSStatus DeviceResume(CMIOHardwarePlugInRef s, CMIODeviceID d)  { (void)s;(void)d; return noErr; }
static OSStatus DeviceProcessAVCCommand(CMIOHardwarePlugInRef s, CMIODeviceID d, CMIODeviceAVCCommand *c) { (void)s;(void)d;(void)c; return kCMIOHardwareIllegalOperationError; }
static OSStatus DeviceProcessRS422Command(CMIOHardwarePlugInRef s, CMIODeviceID d, CMIODeviceRS422Command *c) { (void)s;(void)d;(void)c; return kCMIOHardwareIllegalOperationError; }

static OSStatus StreamCopyBufferQueue(CMIOHardwarePlugInRef s, CMIOStreamID st,
    CMIODeviceStreamQueueAlteredProc proc, void *refCon, CMSimpleQueueRef *outQ)
{
    (void)s;(void)st;
    if (!outQ) return kCMIOHardwareIllegalOperationError;
    if (!gFrameQueue) CMSimpleQueueCreate(kCFAllocatorDefault, 60, &gFrameQueue);
    gAlteredProc   = proc;
    gAlteredRefCon = refCon;
    CFRetain(gFrameQueue);
    *outQ = gFrameQueue;
    return noErr;
}

static OSStatus StreamDeckPlay(CMIOHardwarePlugInRef s, CMIOStreamID i) { (void)s;(void)i; return kCMIOHardwareIllegalOperationError; }
static OSStatus StreamDeckStop(CMIOHardwarePlugInRef s, CMIOStreamID i) { (void)s;(void)i; return kCMIOHardwareIllegalOperationError; }
static OSStatus StreamDeckJog(CMIOHardwarePlugInRef s, CMIOStreamID i, SInt32 sp) { (void)s;(void)i;(void)sp; return kCMIOHardwareIllegalOperationError; }
static OSStatus StreamDeckCueTo(CMIOHardwarePlugInRef s, CMIOStreamID i, Float64 t, Boolean p) { (void)s;(void)i;(void)t;(void)p; return kCMIOHardwareIllegalOperationError; }

// ── Plugin interface ──────────────────────────────────────────────────────────
static CMIOHardwarePlugInInterface sFakeMeIface = {
    NULL, QueryInterface, AddRef, Release,
    Initialize, InitializeWithObjectID, Teardown,
    ObjectShow,
    ObjectHasProperty, ObjectIsPropertySettable,
    ObjectGetPropertyDataSize, ObjectGetPropertyData, ObjectSetPropertyData,
    DeviceSuspend, DeviceResume,
    DeviceStartStream, DeviceStopStream,
    DeviceProcessAVCCommand, DeviceProcessRS422Command,
    StreamCopyBufferQueue,
    StreamDeckPlay, StreamDeckStop, StreamDeckJog, StreamDeckCueTo,
};
static CMIOHardwarePlugInInterface *sFakeMeIfacePtr = &sFakeMeIface;

// ── Entry point ───────────────────────────────────────────────────────────────
void *CMIOHardwarePlugIn_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (!CFEqual(requestedTypeUUID, kCMIOHardwarePlugInTypeID)) return NULL;
    return &sFakeMeIfacePtr;
}

#pragma clang diagnostic pop
