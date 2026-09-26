#!/bin/zsh
# 3.0 Phase C-1: the ArchiveCore boundary, enforced by grep.
#
# The files listed in ARCHIVE_CORE_FILES.txt are the future `ArchiveCore`
# package: store, index, parsers, import, export, receipts, layout. They may
# not import a UI framework and may not name a page-owned or app-shell type.
# The build (Xcode Cloud: ci_scripts/ci_post_clone.sh; locally: this script)
# fails on the first violation, so the boundary cannot drift back while the
# physical package move waits for a pass in which tests run continuously.
#
# Usage: Scripts/check_archive_core_boundary.sh   (exit 0 = clean)
set -euo pipefail
cd "$(dirname "$0")/.."
MANIFEST="Scripts/ARCHIVE_CORE_FILES.txt"
FORBIDDEN_IMPORTS='^import (SwiftUI|AppKit|UIKit|Combine)'
FORBIDDEN_TYPES='\b(StoreManager|PersonaManager|ForensicManager|ModuleRegistry|AppStateManager|ContentViewModel|ImportQueue|EnterpriseConfig|HMACChainAuditLog|CollaborationManager|DigestScheduler)\b'
status=0
while IFS= read -r file; do
  [[ -z "$file" || "$file" == \#* ]] && continue
  path="maxmailin/$file"
  if [[ ! -f "$path" ]]; then echo "MISSING  $path"; status=1; continue; fi
  if grep -nE "$FORBIDDEN_IMPORTS" "$path"; then echo "^ UI import in core file: $file"; status=1; fi
  if grep -nE "$FORBIDDEN_TYPES" "$path" | grep -vE '^\s*[0-9]+:\s*//' ; then echo "^ app-layer type in core file: $file"; status=1; fi
done < "$MANIFEST"
if [[ $status -eq 0 ]]; then echo "ArchiveCore boundary: clean ($(grep -cvE '^(#|$)' "$MANIFEST") files)"; fi
exit $status
