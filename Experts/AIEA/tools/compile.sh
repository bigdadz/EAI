#!/bin/bash
# Headless MQL5 compile for this macOS + Wine setup.
# Usage: tools/compile.sh <absolute-path-to-.mq5-inside-the-real-MQL5-tree>
# Exit 0 = 0 errors; non-zero = compile errors (details printed).
#
# How it works: homebrew `wine` cannot batch-compile against the MetaQuotes
# bundle prefix (wineserver version mismatch) and won't follow symlinks for
# the /compile target, so we keep a throwaway prefix with a local copy of the
# real Include folder, mirror the source into it, and compile there. The real
# MetaEditor64.exe is invoked via its unix path; /include points at the
# sandbox MQL5 dir; detailed errors go to a per-build log we parse.
set -euo pipefail

REAL="/Users/bigdadz/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5"
MQL5_REAL="$REAL/MQL5"
ME="$REAL/MetaEditor64.exe"

export WINEPREFIX="/Users/bigdadz/.wine_orb"
export WINEDEBUG=-all
export WINEDLLOVERRIDES="mscoree=d;mshtml=d"
SB="$WINEPREFIX/drive_c/mt"          # sandbox; C:\mt
SB_MQL5="$SB/MQL5"

SRC="${1:?usage: compile.sh <abs path to .mq5 in MQL5 tree>}"
case "$SRC" in
  "$MQL5_REAL"/*) REL="${SRC#"$MQL5_REAL"/}" ;;
  *) echo "ERROR: source must live under $MQL5_REAL"; exit 2 ;;
esac

# One-time: sandbox + Include copy
if [ ! -d "$SB_MQL5/Include" ]; then
  mkdir -p "$SB_MQL5"
  echo "[compile] seeding sandbox Include (one-time)..."
  cp -R "$MQL5_REAL/Include" "$SB_MQL5/Include"
fi

# Mirror the source into the sandbox at the same relative path
mkdir -p "$SB_MQL5/$(dirname "$REL")"
cp "$SRC" "$SB_MQL5/$REL"

BUILD_LOG="$SB/build.log"
rm -f "$BUILD_LOG"
wine "$ME" /compile:"C:/mt/MQL5/$REL" /include:'C:/mt/MQL5' /log:'C:/mt/build.log' 2>/dev/null || true

OUT=$( iconv -f UTF-16LE -t UTF-8 "$BUILD_LOG" 2>/dev/null || cat "$BUILD_LOG" )
echo "$OUT" | grep -E "error|warning|Result" || true

if echo "$OUT" | grep -qE "Result: 0 errors"; then
  echo "[compile] PASS: $REL"
  exit 0
else
  echo "[compile] FAIL: $REL"
  exit 1
fi
