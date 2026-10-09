# E2E Test Infra: FakeMe macOS Virtual Camera

## Test Philosophy
- Opaque-box, requirement-driven. Derived strictly from `ORIGINAL_REQUEST.md`.
- No dependency on internal implementation details.
- Methodology: Category-Partition + Boundary Value Analysis (BVA) + Pairwise Combinatorial Testing + Real-World Workload Testing.

## Feature Inventory
| # | Feature | Source (requirement) | Tier 1 | Tier 2 | Tier 3 |
|---|---------|---------------------|:------:|:------:|:------:|
| 1 | Camera Video Capture & Provider | ORIGINAL_REQUEST § R1 | 5 | 5 | ✓ |
| 2 | In-Memory Frame Recording | ORIGINAL_REQUEST § R2 | 5 | 5 | ✓ |
| 3 | CIDissolveTransition Crossfade | ORIGINAL_REQUEST § R3 | 5 | 5 | ✓ |
| 4 | Post-Playback Countdown & Auto-Switch | ORIGINAL_REQUEST § R3 | 5 | 5 | ✓ |
| 5 | State Machine Transitions | ORIGINAL_REQUEST § R2, R3 | 5 | 5 | ✓ |
| 6 | Global Hotkeys (Fn+F11, Fn+F12) | ORIGINAL_REQUEST § R2 | 5 | 5 | ✓ |
| 7 | Floating Status HUD & Settings UI | ORIGINAL_REQUEST § R4 | 5 | 5 | ✓ |
| 8 | CoreMediaIO Virtual Camera Device | ORIGINAL_REQUEST § R1, AC1 | 5 | 5 | ✓ |
| 9 | DMG Packaging & Mount Validity | ORIGINAL_REQUEST § R5, AC4 | 5 | 5 | ✓ |

## Test Architecture
- **Test Runner**:
  - Swift Test Runner: `swift test` running unit & component tests.
  - Acceptance Test Runner: `python3 -m unittest discover -s Tests/E2ETests` and acceptance scripts in `Scripts/`.
  - Pass/Fail semantics: Exit code 0 indicates all assertions passed; non-zero indicates failure.
- **Test Scripts Directory Layout**:
  - `Scripts/verify_virtual_camera.swift` (AC1: AVFoundation discovery test)
  - `Scripts/test_hotkeys_acceptance.py` (AC2: Synthetic event injection and state verification)
  - `Scripts/verify_crossfade.swift` (AC3: Monotonic pixel blend mathematical verification)
  - `Scripts/test_dmg_acceptance.py` (AC4: DMG build, mount, volume inspection, detachment)

## Real-World Application Scenarios (Tier 4)
| # | Scenario | Features Exercised | Complexity |
|---|----------|--------------------|------------|
| 1 | Normal Meeting Loop: Record 5s clip, crossfade to playback, hold timer, auto-switch to live | F1, F2, F3, F4, F5, F6, F7 | High |
| 2 | Interrupt Playback: Press Fn+F12 mid-playback to immediately abort back to live | F3, F5, F6, F7 | Medium |
| 3 | Fast Re-record: Press Fn+F11 mid-playback to cancel playback and start fresh recording | F2, F5, F6, F7 | Medium |
| 4 | Virtual Camera Discovery & Output: Query system AVFoundation devices while FakeMe is running | F1, F8 | Medium |
| 5 | Clean Install Simulation: Mount DMG, verify app bundle structure, inspect signatures | F9 | Low |

## Coverage Thresholds
- Tier 1: ≥5 per feature (Total ≥ 45)
- Tier 2: ≥5 per feature (Total ≥ 45)
- Tier 3: Pairwise coverage across major feature pairs (Total ≥ 10)
- Tier 4: ≥5 realistic end-to-end application scenarios (Total ≥ 5)
- **Target Total Minimum**: ≥ 105 tests across all tiers
