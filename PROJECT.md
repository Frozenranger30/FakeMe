# Project: FakeMe macOS Virtual Camera Application

## Architecture

FakeMe is a native macOS application that captures webcam video, records clips on command, smoothly crossfades between live feed and playback, controlled via global hotkeys (`Fn+F11`, `Fn+F12`), provides a floating on-screen status HUD and settings window, exposes the processed feed as a macOS system Virtual Camera (`CMIOExtension`), and packages into an installable `.dmg`.

### High-Level Components & Data Flow

```
+----------------------------------------------------------------------------------------------------+
|                                           FakeMe macOS App                                         |
|                                                                                                    |
|  [Physical Camera / AVCaptureSession]                                                              |
|                     │                                                                              |
|                     ▼ (Live CVPixelBuffer)                                                         |
|             [VideoPipeline] <══════════════ [VideoRecordingBuffer (CVPixelBufferPool)]            |
|                     │                                  │ (Recorded Frames)                         |
|                     ├───► [CrossfadeEngine] ◄──────────┘                                           |
|                     │     (CIDissolveTransition)                                                   |
|                     ▼                                                                              |
|           [Active Output Buffer]                                                                   |
|              ├──► [Main Preview Window (MTKView / NSImageView)]                                    |
|              └──► [CMIO Extension Mach Stream / Virtual Camera Publisher] ──► System Virtual Camera|
|                                                                                                    |
|  [Global Hotkeys (CGEventTap)] ──► [AppStateMachine] ──► Updates Mode & Timers                     |
|  (Fn+F11: Rec, Fn+F12: Play)              │                                                        |
|                                           ├──► [Floating HUD NSPanel] (Dynamic Island pill)        |
|                                           ├──► [Settings Window (SwiftUI)]                         |
|                                           └──► [/tmp/fake_me_status.json] (Atomic status IPC)      |
+----------------------------------------------------------------------------------------------------+
```

---

## Feature Inventory

| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Camera Video Capture | Capture 720p/30fps webcam feed via `AVCaptureSession` with `VideoFrameProvider` abstraction | M1 | ORIGINAL_REQUEST § R1 |
| 2 | Synthetic Frame Provider | Deterministic frame generator for headless tests and simulated camera input | M1 | Survey explorer_2 |
| 3 | In-Memory Frame Recording | High-performance `CVPixelBufferPool` buffer with 0 ms seek latency | M1 | ORIGINAL_REQUEST § R2, Survey explorer_2 |
| 4 | Core Image Crossfade Engine | `CIDissolveTransition` with linear color space producing seamless crossfade | M1 | ORIGINAL_REQUEST § R3, Survey explorer_2 |
| 5 | Post-Playback Timer & Auto-Switch | Countdown timer holding last frame before automatic crossfade return to live | M1 | ORIGINAL_REQUEST § R3 |
| 6 | Application State Machine | 6-state machine (`idleLive`, `recording`, `transitioningToPlayback`, `playingBack`, `postPlaybackHold`, `transitioningToLive`) | M2 | Survey explorer_3 |
| 7 | Global Hotkey Interception | `CGEventTap` for keycodes 103 (`Fn+F11`) and 111 (`Fn+F12`) with event swallowing | M2 | ORIGINAL_REQUEST § R2, Survey explorer_3 |
| 8 | Hotkey IPC & Status Publisher | `DistributedNotificationCenter` test gateway and atomic status publisher to `/tmp/fake_me_status.json` | M2 | Survey explorer_3 |
| 9 | Floating Status Indicator | Borderless, non-activating `NSPanel` at `.floating` level displaying mode and timer countdown | M3 | ORIGINAL_REQUEST § R4 |
| 10 | Settings Configuration Window | SwiftUI settings window with `@AppStorage` for record duration, crossfade duration, and countdown | M3 | ORIGINAL_REQUEST § R4 |
| 11 | Main Live Preview Window | Real-time preview of the processed camera stream with interactive control buttons | M3 | ORIGINAL_REQUEST § R1, R4 |
| 12 | CoreMediaIO Virtual Camera Extension | `CMIOExtension` bundle with `CMIOExtensionProvider`, `CMIOExtensionDevice`, and `CMIOExtensionStream` | M4 | ORIGINAL_REQUEST § R1, Survey spec_miner_1 |
| 13 | Extension Activation & Registration | Host app `OSSystemExtensionRequest` activation manager | M4 | ORIGINAL_REQUEST § R1, Survey spec_miner_1 |
| 14 | DMG Packaging Pipeline | `package_dmg.sh` script creating mountable compressed `UDZO` DMG with `.app` and `/Applications` link | M5 | ORIGINAL_REQUEST § R5, Survey explorer_3 |
| 15 | Virtual Camera Listing Acceptance Test | Test script verifying virtual camera device discovery via `AVCaptureDevice.DiscoverySession` | E2E Track / M6 | ORIGINAL_REQUEST Acceptance AC1 |
| 16 | Hotkey & State Transition Acceptance Test | Automated test verifying state transitions on simulated `Fn+F11`/`Fn+F12` | E2E Track / M6 | ORIGINAL_REQUEST Acceptance AC2 |
| 17 | Video Pipeline Crossfade Acceptance Test | Mathematical assertion of monotonic pixel blending during crossfade | E2E Track / M6 | ORIGINAL_REQUEST Acceptance AC3 |
| 18 | DMG Validity & Mount Acceptance Test | Automated script mounting DMG, checking bundle integrity and code signature | E2E Track / M6 | ORIGINAL_REQUEST Acceptance AC4 |

---

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Core Video & Transition Engine | Capture pipeline, synthetic frame provider, circular recording buffer, CIDissolveTransition crossfade engine, post-playback timer | none | DONE |
| M2 | State Machine & Hotkey Controller | 6-state machine, CGEventTap global hotkey interceptor for keycodes 103/111, event suppression, IPC notification bridge, status file writer | none | PLANNED |
| M3 | UI & Floating HUD & Settings | Floating on-screen status NSPanel, SwiftUI Settings view, Main preview window with manual fallback buttons | M1, M2 | PLANNED |
| M4 | Virtual Camera CMIO Extension | CMIOExtension target, CMIOExtensionProvider/Device/Stream, host activation manager, frame publisher | M1 | PLANNED |
| M5 | App Packaging & DMG Generation | Application bundle staging, codesigning, `package_dmg.sh` generating mountable UDZO DMG with `/Applications` link | M3, M4 | PLANNED |
| M6 | Final Integration & E2E Acceptance Pass | 100% E2E test pass (Tiers 1-4) and Tier 5 adversarial coverage hardening | M5, E2E Track (TEST_READY.md) | PLANNED |

---

## Interface Contracts

### 1. `VideoPipeline` ↔ `AppStateMachine`
- `AppStateMachine` emits state changes:
  - `startRecording(duration: TimeInterval)`
  - `startPlayback()`
  - `cancelToLive()`
- `VideoPipeline` calls back:
  - `onRecordingComplete()`
  - `onPlaybackComplete()`
  - `onTransitionComplete()`
  - `onFrameRendered(CVPixelBuffer)`

### 2. `VideoPipeline` ↔ `VirtualCameraPublisher`
- Function: `func publishFrame(_ pixelBuffer: CVPixelBuffer, at timestamp: CMTime)`
- Format: `kCVPixelFormatType_32BGRA` or `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`, 1280x720, 30 fps.

### 3. `AppStateMachine` ↔ `UI (Floating HUD & Settings)`
- Observable properties:
  - `@Published var currentState: AppState` (`.idleLive`, `.recording`, `.transitioningToPlayback`, `.playingBack`, `.postPlaybackHold`, `.transitioningToLive`)
  - `@Published var remainingSeconds: Double`
  - `@Published var recordingDuration: Double` (default 5.0s)
  - `@Published var transitionDuration: Double` (default 1.0s)
  - `@Published var returnTimerDuration: Double` (default 3.0s)

### 4. `HotkeyController` ↔ `AppStateMachine`
- Global event handler:
  - Keycode 103 (`Fn+F11`) -> `stateMachine.handleHotkeyRecord()`
  - Keycode 111 (`Fn+F12`) -> `stateMachine.handleHotkeyPlaybackToggle()`
- IPC gateway:
  - DistributedNotification `com.fakeme.hotkey.f11` -> `handleHotkeyRecord()`
  - DistributedNotification `com.fakeme.hotkey.f12` -> `handleHotkeyPlaybackToggle()`
- Status publishing:
  - Writes atomic JSON to `/tmp/fake_me_status.json`:
    `{"state": "recording", "remaining": 4.2, "timestamp": 1234567.89}`

---

## Code Layout

```
/Users/frozenranger/Desktop/Fake me /
├── Package.swift                                # Swift Package Manager manifest
├── Makefile                                     # Unified build & test targets
├── Scripts/
│   ├── package_dmg.sh                           # Native hdiutil DMG packaging script
│   ├── verify_virtual_camera.swift              # AC1 verification script
│   ├── test_hotkeys_acceptance.py               # AC2 verification script
│   ├── verify_crossfade.swift                   # AC3 verification script
│   └── test_dmg_acceptance.py                  # AC4 verification script
├── Sources/
│   ├── FakeMeApp/                               # Main macOS application entry point & AppKit host
│   │   ├── main.swift
│   │   ├── AppDelegate.swift
│   │   └── Info.plist
│   ├── FakeMeCore/                              # Core library
│   │   ├── Video/
│   │   │   ├── VideoFrameProvider.swift         # Frame capture protocol
│   │   │   ├── CameraCaptureProvider.swift      # AVCaptureSession physical camera provider
│   │   │   ├── SyntheticFrameProvider.swift     # Synthetic test frame provider
│   │   │   ├── VideoRecordingBuffer.swift       # CVPixelBufferPool memory ring buffer
│   │   │   ├── CrossfadeEngine.swift            # CIDissolveTransition crossfade renderer
│   │   │   └── VideoPipeline.swift              # Main video compositor & pump
│   │   ├── State/
│   │   │   ├── AppState.swift                   # 6-state enum and state definitions
│   │   │   ├── AppStateMachine.swift            # State transitions, timers, and callbacks
│   │   │   └── StatusPublisher.swift            # Atomic /tmp/fake_me_status.json writer
│   │   ├── Hotkeys/
│   │   │   ├── HotkeyController.swift           # CGEventTap interceptor (keycodes 103/111)
│   │   │   └── HotkeyIPCBridge.swift            # DistributedNotificationCenter bridge
│   │   └── CameraExtension/
│   │       ├── CameraExtensionManager.swift     # OSSystemExtensionRequest activator
│   │       └── VirtualCameraPublisher.swift     # CoreMediaIO frame streamer
│   ├── FakeMeUI/                                # User Interface components
│   │   ├── FloatingHUD/
│   │   │   ├── FloatingHUDPanel.swift           # Borderless NSPanel configuration
│   │   │   └── FloatingHUDView.swift            # SwiftUI floating pill view
│   │   ├── Settings/
│   │   │   └── SettingsView.swift               # SwiftUI duration sliders & camera picker
│   │   └── Preview/
│   │       └── CameraPreviewView.swift          # Live preview renderer & control buttons
│   └── FakeMeCameraExtension/                   # CMIOExtension target
│       ├── main.swift
│       ├── Provider.swift                       # CMIOExtensionProvider
│       ├── Device.swift                         # CMIOExtensionDevice
│       ├── Stream.swift                         # CMIOExtensionStream
│       └── Info.plist
└── Tests/
    ├── FakeMeCoreTests/                         # Unit tests for core logic
    │   ├── VideoPipelineTests.swift
    │   ├── CrossfadeEngineTests.swift
    │   ├── RecordingBufferTests.swift
    │   └── StateMachineTests.swift
    └── E2ETests/                                # E2E Test Suite (Tiers 1-4)
        ├── Tier1_FeatureCoverage/
        ├── Tier2_BoundaryCorner/
        ├── Tier3_PairwiseCombinations/
        └── Tier4_RealWorldScenarios/
```
