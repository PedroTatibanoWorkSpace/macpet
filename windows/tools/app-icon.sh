#!/usr/bin/env bash
# Gera os ícones do Cawde (src-tauri/icons) a partir do corvo do PetArt.swift.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .build
swiftc -O -o .build/cawde-icon windows/tools/app-icon/main.swift Sources/MacPet/Pet/PetArt.swift
.build/cawde-icon .build/cawde-icon.png
cd windows/app && pnpm tauri icon ../../.build/cawde-icon.png
