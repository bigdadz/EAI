# CLAUDE.md — MQL5 repo (two setups: Exness/macOS+Wine, IUX/Windows-native)

> Two machines share this repo. **macOS + Wine** (Exness account) — see the macOS sections below.
> **Windows (native MT5)** (IUXMarkets-Live account) — see "## Windows (native MT5)". Each platform
> has its own tooling and its own symbol-naming convention; don't mix them.

## Repo layout
- **This repo IS the `MQL5/Experts/EAI/` folder.** Clone it directly into the MT5 data folder's `Experts/` dir (`git clone <url>` from inside `<MT5 data>/MQL5/Experts/` → produces `EAI/`). Repo root holds the EAs (`LondonORB_EA.mq5`, `PortfolioORB_EA.mq5`); `tools/`, `tests/`, `docs/` are siblings.
- All repo-relative commands below run from the repo root (= `MQL5/Experts/EAI/`).
- **EAs:** `LondonORB_EA.mq5` — single-symbol London ORB, 1 trade/day. `PortfolioORB_EA.mq5` — multi-symbol ORB: per-symbol OR window + state, account-level DD breaker, correlation guard.
- **Designs & backtest results live in `docs/superpowers/`** (`specs/` = designs + results, `plans/` = build plans). Note: those docs predate the rename and still reference the old `Experts/AIEA/` paths — historical, not current.

## Build & test MQL5 headlessly (no MetaTrader GUI required)
- **Compile:** `bash tools/compile.sh "<abs path to .mq5>"` → `[compile] PASS` / per-line errors. (homebrew `wine` + throwaway prefix `~/.wine_orb` holding a copy of the real `Include/`.)
- Do NOT run homebrew `wine` against the MetaQuotes bundle prefix (wineserver version mismatch); the bundle's `wine64` opens the GUI instead of batch-compiling.
- **`compile.sh` builds into the sandbox prefix (`~/.wine_orb/drive_c/mt/MQL5/...`), NOT the real tree.** The Strategy Tester loads `.ex5` from the real tree, so after compiling you MUST copy the fresh `.ex5` over: `cp ~/.wine_orb/drive_c/mt/MQL5/Experts/EAI/<EA>.ex5 MQL5/Experts/EAI/`. Skipping this silently tests a stale build.
- **Strategy Tester headless:** bundled wine64 (`/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine64`) + `WINEPREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"`, run `terminal64.exe "/config:C:\Program Files\MetaTrader 5\<x>.ini"`. Use a `[Tester]` ini with `ShutdownTerminal=1`; `[TesterInputs]` overrides EA inputs. Auto-logs into the saved Exness account and downloads history on demand.

## Tester gotchas (each cost real debugging time)
- Symbol is **`GBPUSDm`** (Exness "m" suffix), not `GBPUSD`.
- **`MQL5/Profiles/Tester/<expert>.set` silently overrides compiled defaults** when `[TesterInputs]` is absent — delete it to test true defaults.
- Use **Model=1 (1-min OHLC)** for multi-year runs (real-tick cache is sparse).
- Results: parse `Tester/Agent-127.0.0.1-3000/logs/<YYYYMMDD>.log` (UTF-16) for `final balance`; `rm` it before each run to isolate. The agent log has ONLY `final balance` (no DD/PF).
- For full stats use `Report=<name>` + `ReplaceReport=1` in `[Tester]` → generates `<name>.htm` in the MT5 root (this DID work reliably). Parse: UTF-16, `tr -d '\n'` first, values are in `<b>…</b>` right after each label (e.g. `Equity Drawdown Maximal:</td> … <b>2 293.31 (17.79%)</b>`).
- A killed sweep leaves a terminal-rewritten `<expert>.set` (terminal saves inputs on exit) and an un-restored backup — `sweep.sh` moves the `.set` aside (trap-restores on clean exit); if killed, restore manually.
- Sequential terminal launches occasionally fail silently (no log) — retry 2–3×.

## Windows (native MT5) — IUXMarkets-Live account
Native MT5, so it's **simpler than macOS+Wine**: no Wine prefix, no sandbox `Include/` copy, and
**no `.ex5` copy step** — MetaEditor compiles in place into the real tree where the Tester looks.
- **Binaries:** `C:\Program Files\MetaTrader 5\{terminal64.exe, MetaEditor64.exe}` (override the dir with `$env:MT5_HOME`). **Data folder** = the `…\Terminal\<hash>` dir; this repo is at `<data>\MQL5\Experts\EAI`.
- **Tooling (PowerShell, in `tools/win/`):**
  - `tools/win/compile.ps1 [<.mq5>]` — headless compile → `[compile] PASS/FAIL` (defaults to `PortfolioORB_EA.mq5`).
  - `tools/win/test.ps1 -Symbol XAUUSD. -From 2026.01.01 -To 2026.05.23 [-Inputs @{ InpSymbols='XAUUSD.' }]` — one run; parses the HTML report (net profit / DD / PF / trades).
  - `tools/win/sweep.ps1 -Symbol XAUUSD. -From .. -To .. [-StartHours 6,7,8 -Windows 15,30,60 -MaxSpread 600 -Out gold.csv]` — OR-hour × window grid → CSV (drives PortfolioORB single-symbol via `[TesterInputs]`).
  - `tools/win/Mt5Common.ps1` — shared helpers (path resolution, UTF-16 log reader, HTML-report parser). Dot-sourced by the others.
  - `tools/DumpSymbols.mq5` — utility EA: prints all broker symbols (`SYM <name>`) to the tester log; run it on a known-good symbol to discover names.

### Windows tester gotchas (each cost real debugging time)
- **Symbols carry a TRAILING DOT:** `XAUUSD.`, `GBPUSD.`, `EURUSD.`, `BTCUSD.` — NOT `GBPUSDm` (that's Exness) and NOT plain `GBPUSD`. Forget the dot and the tester aborts with `symbol X not exist` **even though the journal says it synced 125 symbols**. The plain-named `bases\IUXMarkets-Live\history\GBPUSD` folders and the `British Pound`/`Euro` chart profiles are stale MetaQuotes demo leftovers — ignore them. A trailing-dot name makes MT5 **hash its history-folder name** (e.g. `0B1396DF…` = `BTCUSD.`). Confirm real names via `DumpSymbols`; chart symbol names are also plaintext in `MQL5\Profiles\Charts\<profile>\*.chr`.
- **Terminal must be CLOSED** before a `/config` run — a 2nd instance on the same data folder is silently ignored (no test runs). `compile/test/sweep.ps1` assert this and abort with a clear message.
- Logs/reports are **UTF-16** → `Get-Content -Encoding Unicode`. The HTML report lands in the **data-folder root** as `<Report>.htm`.
- The per-agent `final balance` log (`Tester\Agent-127.0.0.1-3000\logs`) may **not** be produced on this build — rely on the HTML report for stats (what `test.ps1`/`sweep.ps1` do).
- `Profiles\Tester\<expert>.set` override, `Model=1` for multi-month runs, and retry-on-silent-failure all apply same as macOS; `sweep.ps1` moves the `.set` aside (restores in `finally`).
- **Server timezone = UK time: GMT+0 (winter) / GMT+1 (summer), EU/UK DST** (springs forward last Sun of March, back last Sun of Oct). Measured from FX weekend gaps: weekly open Sun 22:00 server / close Fri 21:00 (and Sun 21:00 / Fri 20:00 during the Mar 8–29 window where US DST is on but EU isn't). This is the **same GMT+0 baseline the OR hours were tuned for on Exness**, so OR-start hours transfer to IUX 1:1 — no shift needed. (`TimeTradeServer()−TimeGMT()` is 0 in the tester, so timezone must be inferred from data; `tools/TZProbe.mq5` does this.) Only nuance: IUX uses EU-DST dates vs Exness's US-DST, a ~3-week/year 1h mismatch — negligible for ORB. The FX legs' 2026 losses are out-of-sample / broker differences, NOT a timezone misalignment.

## Conventions
- EAs may be single-file `.mq5` (e.g. `LondonORB_EA.mq5` at repo root) — keep clean commented sections; modular isn't required.
- The unit-test script lives under `tests/` (it's a Script, but kept inside this Experts subtree so the project stays self-contained — it shows under MT5's *Experts* navigator group, not *Scripts*).
- `.ex5` are build artifacts — don't commit.
- End commit messages with the `Co-Authored-By: Claude ...` line.
