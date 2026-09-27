#!/bin/zsh
# 3.0 Phase C-1: the ArchiveCore boundary.
#
# ArchiveCore is a real local Swift package (Packages/ArchiveCore): store,
# index, parsers, import, export, receipts, layout. The compiler is now the
# primary enforcement — the package cannot see the app module at all. This
# script is the second line: it fails on a UI-framework import or a named
# page-owned / app-shell type appearing in any package source, and on a
# manifest entry that no longer exists, so the boundary cannot drift back
# through a copy-paste. Xcode Cloud runs it from ci_scripts/ci_post_clone.sh.
#
# Usage: Scripts/check_archive_core_boundary.sh   (exit 0 = clean)
set -euo pipefail
cd "$(dirname "$0")/.."
PACKAGE_DIR="Packages/ArchiveCore/Sources/ArchiveCore"
MANIFEST="Scripts/ARCHIVE_CORE_FILES.txt"
FORBIDDEN_IMPORTS='^import (SwiftUI|AppKit|UIKit|Combine)'
FORBIDDEN_TYPES='\b(StoreManager|PersonaManager|ForensicManager|ModuleRegistry|AppStateManager|ContentViewModel|ImportQueue|EnterpriseConfig|HMACChainAuditLog|CollaborationManager|DigestScheduler|EmailStore\.shared|StorageActivationCoordinator|MemoryPressureHandler|ExportManager)\b'
violations=0
[[ -d "$PACKAGE_DIR" ]] || { echo "MISSING package directory $PACKAGE_DIR"; exit 1; }
count=0
for path in "$PACKAGE_DIR"/*.swift; do
  count=$((count + 1))
  if /usr/bin/grep -nE "$FORBIDDEN_IMPORTS" "$path"; then echo "^ UI import in core file: ${path##*/}"; violations=1; fi
  if /usr/bin/grep -nE "$FORBIDDEN_TYPES" "$path" | /usr/bin/grep -vE '^\s*[0-9]+:\s*//' ; then echo "^ app-layer type in core file: ${path##*/}"; violations=1; fi
done
# Every manifest entry must be a file in the package (the manifest is the
# human-readable inventory; the package directory is the truth).
while IFS= read -r file; do
  [[ -z "$file" || "$file" == \#* ]] && continue
  if [[ ! -f "$PACKAGE_DIR/$file" ]]; then echo "MISSING  $PACKAGE_DIR/$file (listed in $MANIFEST)"; violations=1; fi
done < "$MANIFEST"
if [[ $violations -eq 0 ]]; then echo "ArchiveCore boundary: clean ($count package files)"; fi
exit $violations
