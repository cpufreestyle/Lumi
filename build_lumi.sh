#!/bin/bash
cd "/Users/a1-6/AI Shared/repo/Lumi/Lumi"
export TOOLCHAINS=$(xcodebuild -find-toolchain org.swift.5611.26.5 2>/dev/null || true)
if [ -z "$TOOLCHAINS" ]; then
  export TOOLCHAINS=$(xcodebuild -find-toolchain 6.1.1 2>/dev/null || true)
fi
swift build 2>&1 | tail -30
echo "EXIT=${PIPESTATUS[0]}"
