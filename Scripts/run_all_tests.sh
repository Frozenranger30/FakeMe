#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=========================================================================="
echo "  FakeMe Milestone 1 Master Regression & Adversarial Verification Suite   "
echo "=========================================================================="
cd "${ROOT_DIR}"

echo -e "\n[1/5] Building Package..."
swift build

echo -e "\n[2/5] Running All 58 XCTest Unit & Adversarial Tests..."
swift test

echo -e "\n[3/5] Running ThreadSanitizer Concurrency Suite..."
swift test --sanitize=thread

echo -e "\nRe-building package without TSAN for script link compatibility..."
swift build

echo -e "\n[4/5] Running AC3 Mathematical Verification..."
swift Scripts/verify_crossfade.swift

echo -e "\n[5/5] Running Standalone Empirical Adversarial Stress Harnesses..."
swiftc -o /tmp/stress_test_m1_bin Scripts/stress_test_m1.swift Sources/FakeMeCore/Video/*.swift -framework CoreVideo -framework CoreMedia -framework CoreImage -framework AVFoundation
/tmp/stress_test_m1_bin

swift Scripts/adversarial_crossfade_test.swift

swiftc -I .build/out/Products/Debug -L .build/out/Products/Debug -lFakeMeCore Scripts/adversarial_memory_stability.swift -o /tmp/adversarial_memory_stability
/tmp/adversarial_memory_stability

echo -e "\n=========================================================================="
echo "  VERDICT: 100% PASS ACROSS ALL UNIT, ADVERSARIAL, AND TSAN SUITES        "
echo "=========================================================================="
