#!/bin/zsh
# Xcode Cloud: runs after clone, before the build. Fails the workflow when a
# file in the ArchiveCore set imports a UI framework or names an app-layer
# type (3.0 Phase C-1 boundary rule).
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/check_archive_core_boundary.sh
