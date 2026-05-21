# CLAUDE.md — MQL5 repo (Exness account, macOS + Wine)

## Build & test MQL5 headlessly (no MetaTrader GUI required)
- **Compile:** `bash Experts/AIEA/tools/compile.sh "<abs path to .mq5>"` → `[compile] PASS` / per-line errors. (homebrew `wine` + throwaway prefix `~/.wine_orb` holding a copy of the real `Include/`.)
- Do NOT run homebrew `wine` against the MetaQuotes bundle prefix (wineserver version mismatch); the bundle's `wine64` opens the GUI instead of batch-compiling.
- **Strategy Tester headless:** bundled wine64 (`/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine64`) + `WINEPREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"`, run `terminal64.exe "/config:C:\Program Files\MetaTrader 5\<x>.ini"`. Use a `[Tester]` ini with `ShutdownTerminal=1`; `[TesterInputs]` overrides EA inputs. Auto-logs into the saved Exness account and downloads history on demand.

## Tester gotchas (each cost real debugging time)
- Symbol is **`GBPUSDm`** (Exness "m" suffix), not `GBPUSD`.
- **`MQL5/Profiles/Tester/<expert>.set` silently overrides compiled defaults** when `[TesterInputs]` is absent — delete it to test true defaults.
- Use **Model=1 (1-min OHLC)** for multi-year runs (real-tick cache is sparse).
- Results: parse `Tester/Agent-127.0.0.1-3000/logs/<YYYYMMDD>.log` (UTF-16) for `final balance`; `rm` it before each run to isolate. `/config Report=` HTML didn't reliably generate.
- Sequential terminal launches occasionally fail silently (no log) — retry 2–3×.

## Conventions
- EAs may be single-file `.mq5` (e.g. `Experts/AIEA/LondonORB_EA.mq5`) — keep clean commented sections; modular isn't required.
- `.ex5` are build artifacts — don't commit.
- End commit messages with the `Co-Authored-By: Claude ...` line.
