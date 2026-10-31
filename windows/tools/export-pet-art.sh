#!/usr/bin/env bash
# Exporta a arte do corvo (Sources/MacPet/Pet/PetArt.swift) para windows/shared/pet-art.json.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .build
swiftc -O -o .build/export-pet-art windows/tools/export-pet-art/main.swift Sources/MacPet/Pet/PetArt.swift
.build/export-pet-art windows/shared/pet-art.json
