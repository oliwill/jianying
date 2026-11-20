#!/bin/bash
# 拣影 —— 验收测试
set -e
cd "$(dirname "$0")/.."
mkdir -p .test/tmp
cp Tests/acceptance.swift .test/tmp/main.swift
swiftc -O -o .test/run Sources/Library.swift .test/tmp/main.swift \
  -framework AppKit -framework Photos -framework ImageIO -framework AVFoundation 2>&1 | grep -E "error:" || true
./.test/run
