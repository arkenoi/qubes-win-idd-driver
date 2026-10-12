#!/bin/bash
# evidence-receipt-gate.sh — Stop hook
# Blocks the turn if a golden-recreation claim was made without command output or screenshots.
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
# Simple check: if the transcript or recent commands mention recreate-goldens / seal / verify
# and no evidence files exist in scratchpad/, refuse.
# This is a coarse filter; the real rule is in the procedure.
EVIDENCE_DIR="$ROOT/scratchpad"
if [ -d "$EVIDENCE_DIR" ]; then
  # Look for recent shot or verify output files (last 2 hours)
  recent=$(find "$EVIDENCE_DIR" -name '*shot*' -o -name '*verify*' -o -name '*golden*' -mmin -120 2>/dev/null | head -1)
  if [ -z "$recent" ]; then
    # Check if any recreate language appeared; if the agent is claiming success, demand evidence.
    # For now, just warn loudly. A full transcript parse is heavier.
    echo "WARNING: evidence-receipt-gate: no recent shot/verify files in scratchpad/. If you claimed a golden recreate succeeded, paste the verify output and screenshot paths before ending the turn." >&2
  fi
fi
exit 0
