# London ORB EA — Design Spec

- **วันที่:** 2026-05-21
- **สถานะ:** อนุมัติแล้ว (รอรีวิว spec → เขียนแผน implementation)
- **ไฟล์เป้าหมาย:** `Experts/AIEA/LondonORB_EA.mq5` (single-file EA)
- **แพลตฟอร์ม:** MetaTrader 5 / MQL5

---

## 1. ภาพรวมและเป้าหมาย

EA เทรดแบบ **Opening Range Breakout (ORB)** ในช่วงเปิดตลาด **London** บนคู่ **GBPUSD** (single-symbol, ตั้ง symbol/พารามิเตอร์ผ่าน input)

**เป้าหมาย:** สร้างเฟรมเวิร์กเทรดที่ *ทดสอบได้ คุมความเสี่ยงเข้มงวด และมี logic ชัดเจน* เพื่อนำไปพิสูจน์ edge ผ่าน backtest → walk-forward → demo → live เงินน้อย

> **ข้อจำกัดความรับผิดที่ต้องเข้าใจ:** ไม่มีระบบเทรดใดรับประกันกำไร spec นี้ออกแบบ *กลไกการเทรดและการจัดการความเสี่ยง* ที่ถูกต้องและทดสอบได้ ความสามารถในการทำกำไรจริงต้องพิสูจน์ด้วยข้อมูลย้อนหลังและ forward test — ตัวเลข default ทั้งหมดเป็นจุดตั้งต้นสำหรับ optimize ไม่ใช่ค่าที่การันตีผล

## 2. ขอบเขต (Scope)

**อยู่ใน v1:**
- ORB ช่วง London เท่านั้น, single-symbol, ≤ 1 ไม้/วัน
- % risk position sizing + daily drawdown circuit breaker
- SL อีกฝั่งของกรอบ (หรือ ATR), TP แบบ R-multiple, break-even, trailing
- Force-close ท้ายวัน (กันถือข้ามคืน) — เปิด/ปิดได้
- ตัวกรอง 4 ตัว toggle อิสระ: ATR/Range size, Higher-TF trend, News, Retest
- Spread guard ขั้นต่ำ
- Dashboard เบาๆ ผ่าน `Comment()` (เปิด/ปิดได้)

**ไม่อยู่ใน v1 (future):**
- Multi-symbol / portfolio
- NY session, multiple trades/day
- Partial TP / pyramiding
- Object-based dashboard panel

## 3. สเปกกลยุทธ์

**Flow ต่อวัน:**
```
[เริ่มวันใหม่] reset state, จำ equity ต้นวัน, entryState = IDLE, tradedToday = false
   ↓
[OR Window]  (default 10:00–10:30 server time)
   เก็บ High/Low ของแท่งที่ปิดในช่วงนี้ → ORHigh / ORLow
   ↓
[OR finalize] ตรวจ Range size filter → ถ้าไม่ผ่าน ข้ามวันนี้
   ↓
[Trading Window] (default จนถึง 14:00 server time) — ทุกแท่ง "ปิดแล้ว":
   เงื่อนไข breakout: Close > ORHigh + buffer (BUY) | Close < ORLow − buffer (SELL)
   + ผ่าน Higher-TF trend filter + ผ่าน News filter + spread OK + ยังไม่เทรดวันนี้ + ไม่ชน daily DD
      ├─ InpUseRetest = false → เข้าเลย
      └─ InpUseRetest = true  → ARMED → รอราคาย่อแตะขอบกรอบ (±tolerance) → ยืนยันทิศ → เข้า
                                  (timeout ภายใน N แท่ง หรือหมด trading window → ยกเลิก, entryState = IDLE)
   ↓
[เปิดไม้] lot จาก %risk; SL = อีกฝั่งกรอบ ± SLbuffer (หรือ ATR); TP = entry ± R·(ระยะ SL)
   ↓
[บริหารไม้] ราคาถึง +BE_TriggerR → ย้าย SL = entry ; ถึง +TrailStartR → trailing ตาม TrailDist
   ↓
[Force-close (optional)] ปิดไม้ที่ยังเปิดก่อนถึง InpForceCloseHour
```

**กฎสำคัญ:**
- ประเมินสัญญาณบน **แท่งที่ปิดแล้วเท่านั้น** (ห้าม act บนแท่งกำลังก่อตัว) — กัน repaint/สัญญาณหลอก
- เวลาทั้งหมดอิง **เวลา server ของโบรกเกอร์** (ผู้ใช้ต้องตั้งให้ตรง — ดู §8)
- 1 ไม้/วัน: เมื่อเปิดไม้แล้ว `tradedToday = true` จนกว่าจะขึ้นวันใหม่

## 4. สถาปัตยกรรม (Single-file)

```
LondonORB_EA.mq5
├─ #property (copyright, version, description) + #include <Trade/Trade.mqh>
├─ enums:
│    ENUM_SIGNAL       { SIGNAL_NONE, SIGNAL_BUY, SIGNAL_SELL }
│    ENUM_BUFFER_MODE  { BUFFER_POINTS, BUFFER_ATR }
│    ENUM_SL_MODE      { SL_RANGE_OPPOSITE, SL_ATR }
│    ENUM_DD_ACTION    { DD_STOP_ONLY, DD_CLOSE_ALL }
│    ENUM_ENTRY_STATE  { ENTRY_IDLE, ENTRY_ARMED, ENTRY_DONE }
├─ input groups: General / Session / Range+Signal / Risk / Exit+Trailing / Filters / Display
├─ globals: CTrade trade; ORHigh; ORLow; rangeReady; entryState; armedDir; tradedToday;
│            dayStartEquity; lastBarTime; lastDay; ddStopped; atrHandle; trendEmaHandle
├─ Lifecycle: OnInit() · OnDeinit(reason) · OnTick() · OnTimer()
└─ Helpers (ฟังก์ชันเล็ก โฟกัสเดียว):
     Time/Session : IsNewBar() · IsNewDay() · InORWindow() · InTradingWindow() · PastForceClose()
     Range        : UpdateOpeningRange() · FinalizeRange() · RangeSizeOK()
     Signal       : CheckBreakout() → ENUM_SIGNAL ·  TrendFilterOK(dir) · NewsBlocked() · RetestConfirmed(dir)
     Risk         : CalculateLot(slPoints) · IsDailyDDExceeded()
     Trade        : OpenTrade(signal) · ManageTrailing() · CloseAll() · SpreadOK() · ValidateStops()
     Display      : UpdateDashboard()
```

`OnTick()` orchestration order: new-day reset → daily DD check → update/finalize range ตาม session phase → manage trailing (ไม้ที่เปิดอยู่ ทำทุก tick) → ถ้าแท่งใหม่ & ใน trading window & ยังไม่เทรด: ประเมิน breakout + filters + retest state machine → เปิดไม้ → force-close ถ้าเลยเวลา → update dashboard

## 5. พารามิเตอร์ (Inputs)

### General
| Input | Default | คำอธิบาย |
|---|---|---|
| `InpMagic` | 20260521 | magic number |
| `InpDeviation` | 20 | slippage (points) |
| `InpMaxTradesPerDay` | 1 | จำนวนไม้สูงสุด/วัน |
| `InpTimeframe` | PERIOD_M5 | TF สำหรับ OR/signal |
| `InpDebugMode` | false | log ละเอียด |

### Session (⚠️ เวลา server ของโบรกเกอร์ — default อิง Exness ≈ GMT+0, ดู §8)
| Input | Default | คำอธิบาย |
|---|---|---|
| `InpORStartHour` / `InpORStartMin` | 8 / 0 | เริ่มเก็บกรอบ OR (London open บน Exness GMT+0) |
| `InpOREndHour` / `InpOREndMin` | 8 / 30 | จบกรอบ OR |
| `InpTradeEndHour` / `InpTradeEndMin` | 12 / 0 | หยุดรับไม้ใหม่ |
| `InpForceCloseEnable` | true | บังคับปิดท้ายวัน |
| `InpForceCloseHour` / `InpForceCloseMin` | 20 / 0 | เวลาบังคับปิด |

### Range / Signal
| Input | Default | คำอธิบาย |
|---|---|---|
| `InpBufferMode` | BUFFER_ATR | โหมด buffer ทะลุกรอบ |
| `InpBufferPoints` | 50 | buffer (points) เมื่อ BUFFER_POINTS |
| `InpBufferATRmult` | 0.10 | buffer = ATR×ค่านี้ เมื่อ BUFFER_ATR |
| `InpRequireBarClose` | true | ต้องปิดแท่งเหนือ/ใต้กรอบ (ไม่ใช้แค่ wick) |
| `InpATRPeriod` | 14 | ATR period (ใช้ buffer/range/SL) |

### Risk
| Input | Default | คำอธิบาย |
|---|---|---|
| `InpRiskPercent` | 1.0 | %เสี่ยงต่อไม้ (จาก balance) |
| `InpMaxDailyDDPercent` | 3.0 | เพดาน drawdown ต่อวัน |
| `InpDDAction` | DD_STOP_ONLY | เมื่อชน DD: หยุด หรือ ปิดทั้งหมด |

### Exit / Trailing
| Input | Default | คำอธิบาย |
|---|---|---|
| `InpSLMode` | SL_RANGE_OPPOSITE | ที่วาง SL |
| `InpSLBufferPoints` | 30 | buffer เพิ่มจากขอบกรอบสำหรับ SL |
| `InpSLATRmult` | 1.5 | SL = ATR×ค่านี้ เมื่อ SL_ATR |
| `InpTP_R` | 1.8 | TP เป็นกี่เท่าของระยะ SL (R) |
| `InpBE_TriggerR` | 1.0 | ถึงกี่ R จึงย้าย SL ไป break-even |
| `InpTrailStartR` | 1.2 | ถึงกี่ R จึงเริ่ม trailing |
| `InpTrailDistPoints` | 200 | ระยะ trailing (points) |

### Filters (toggle อิสระทุกตัว)
| Input | Default | คำอธิบาย |
|---|---|---|
| `InpMaxSpreadPoints` | 40 | spread guard — ข้ามถ้าเกิน (ตั้ง `0` = ปิด guard) |
| `InpUseRangeFilter` | true | กรองขนาดกรอบ OR |
| `InpMinRangeATR` | 0.5 | กรอบต้อง ≥ ATR×ค่านี้ |
| `InpMaxRangeATR` | 3.0 | กรอบต้อง ≤ ATR×ค่านี้ |
| `InpUseTrendFilter` | true | กรองตามเทรนด์ HTF |
| `InpTrendTF` | PERIOD_H1 | TF เทรนด์ |
| `InpTrendEMA` | 50 | EMA period เทรนด์ |
| `InpUseNewsFilter` | true | งดเทรดรอบข่าวแรง |
| `InpNewsMinsBefore` | 30 | งดก่อนข่าว (นาที) |
| `InpNewsMinsAfter` | 30 | งดหลังข่าว (นาที) |
| `InpNewsCurrencies` | "GBP,USD" | สกุลข่าวที่สนใจ |
| `InpUseRetest` | true | ต้องรอ retest ก่อนเข้า |
| `InpRetestTolerancePoints` | 50 | ระยะที่ถือว่า "ย่อแตะขอบ" |
| `InpRetestTimeoutBars` | 6 | ถ้าไม่ retest ภายในกี่แท่ง → ยกเลิก |

### Display
| Input | Default | คำอธิบาย |
|---|---|---|
| `InpShowDashboard` | true | แสดงสถานะผ่าน Comment() |

## 6. รายละเอียดตัวกรอง

1. **Range size** (`RangeSizeOK`): หลัง finalize, `rangeSize = ORHigh − ORLow`; ผ่านเมื่อ `InpMinRangeATR×ATR ≤ rangeSize ≤ InpMaxRangeATR×ATR`. ถ้าไม่ผ่าน → ข้ามทั้งวัน (กรอบเล็ก=ชอป, ใหญ่=SL กว้างเกิน)
2. **Higher-TF trend** (`TrendFilterOK`): EMA(`InpTrendEMA`) บน `InpTrendTF`; BUY ผ่านเมื่อ close(HTF) > EMA, SELL ผ่านเมื่อ close(HTF) < EMA
3. **News** (`NewsBlocked`): ใช้ MQL5 Calendar (`CalendarValueHistory`) กรองเฉพาะ high-impact ของสกุลใน `InpNewsCurrencies`; บล็อกช่วง ±(before/after). **Caveat:** Calendar ใน Strategy Tester มีข้อจำกัด/อาจไม่มีข้อมูล → ถ้าดึงไม่ได้ ให้ `log warning + return false (ไม่บล็อก)` เพื่อไม่ให้ระบบพัง และให้ผู้ใช้รู้ว่า news filter ไม่ทำงานใน run นั้น
4. **Retest** (state machine): breakout ที่ผ่าน filter → `entryState = ARMED`, เก็บ `armedDir` + ขอบกรอบที่ทะลุ. ในแท่งถัดไป ถ้าราคาย่อกลับมาภายใน `InpRetestTolerancePoints` ของขอบ แล้วแท่งปิดยืนยันทิศเดิม → เข้า (`ENTRY_DONE`). ถ้าเกิน `InpRetestTimeoutBars` หรือหมด trading window → `ENTRY_IDLE` (ยกเลิก ไม่เทรดวันนั้น)

## 7. การจัดการความผิดพลาด

- ตรวจ `atrHandle` / `trendEmaHandle` ตอน `OnInit` → `INVALID_HANDLE` คืน `INIT_FAILED`
- `CopyBuffer` / `CopyRates` คืนค่าน้อยกว่าที่ขอ → ข้าม tick นั้นอย่างปลอดภัย (ไม่เข้าไม้)
- ก่อนส่งคำสั่ง: ตรวจ `SYMBOL_TRADE_STOPS_LEVEL` / freeze level, spread guard, normalize ราคา/lot ตาม `SYMBOL_VOLUME_MIN/MAX/STEP` และ `Digits`
- จัดการ retcode จาก `CTrade` (log เมื่อ fail, ไม่ retry ถี่จนสแปม)
- New-day / new-bar detection ทนข้ามสุดสัปดาห์ (เทียบ `TimeToStruct().day` หรือวันเริ่มจาก `iTime`)
- Daily DD: คำนวณจาก equity เทียบ `dayStartEquity`; เมื่อชน → ตาม `InpDDAction`

## 8. การตั้งเวลา Server (Exness) — ต้องยืนยันก่อนใช้/เทสต์

เวลา session เป็น **เวลา server ของโบรกเกอร์** ไม่ใช่เวลาท้องถิ่น/GMT

**Exness:** server time ของ Exness โดยทั่วไป = **GMT+0** (ต่างจากโบรกยุโรปส่วนใหญ่ที่ GMT+2/+3) และ Exness มี DST (FX ส่วนใหญ่ตาม US DST) → นาฬิกา server อาจขยับ ~1 ชม. ตามฤดู. London open = 08:00 London time ⇒ บน server GMT+0 ≈ 08:00 server. Default ใน §5 ตั้งไว้ตามนี้ (OR 08:00–08:30)

**กลไก self-calibration (อยู่ใน EA):** `OnInit` จะ `Print` เวลา server ปัจจุบัน (`TimeTradeServer()`) และ offset โดยประมาณ (`TimeTradeServer() − TimeGMT()`, ใช้ได้บน live; ใน tester จะเป็น 0) เพื่อให้ผู้ใช้เทียบแล้วปรับ input ได้ทันทีโดยไม่ต้องเดา

**ขั้นตอนผู้ใช้:**
1. เปิด EA / ดู log `OnInit` หรือ Market Watch clock → รู้เวลา server จริง
2. ปรับ `InpORStartHour`/`InpOREndHour`/`InpTradeEndHour`/`InpForceCloseHour` ให้ครอบ London open ของ server ตัวเอง
3. ตอน backtest ตั้งให้ตรงกับ server ของ tester (อาจต่างจาก live)
4. **DST:** ตรวจช่วงเปลี่ยนเวลา (มี.ค./ต.ค.–พ.ย.) ว่า server ขยับหรือไม่ แล้วปรับ ±1 ชม. หากจำเป็น — auto-DST เป็น future enhancement (ไม่อยู่ใน v1)

## 9. กลยุทธ์การทดสอบและพิสูจน์ผล

1. **Backtest:** GBPUSD, `InpTimeframe`=M5, model "Every tick based on real ticks", หลายปี (เช่น 2018–2025), spread สมจริง
2. **เมตริกที่บันทึก:** Net profit, Profit Factor (เป้า > 1.3), Max DD% (ยิ่งต่ำยิ่งดี), Win rate, Expectancy (R/trade), จำนวนเทรด (ต้องมากพอจะมีนัยสำคัญ — ระวัง over-filter ทำให้ไม้น้อย), Recovery factor
3. **A/B test ตัวกรอง:** เปิด/ปิดทีละตัว (Range / Trend / News / Retest) วัดว่าตัวไหนเพิ่ม edge จริง ตัวไหนแค่ตัดไม้ทิ้ง
4. **Walk-forward:** optimize พารามิเตอร์ *น้อยตัว* (buffer, TP_R, ความยาว OR, EMA period) บน in-sample → validate out-of-sample (กัน overfit)
5. **Demo forward** ≥ 1–2 เดือน → **Live ไม้เล็กสุด** → ขยายเมื่อ demo/live สอดคล้องกัน
6. **Unit-style checks** ใน `Scripts/UnitTests/`: ทดสอบ `CalculateLot()` ให้ %risk ออกมาถูกตามระยะ SL และ tick value; ทดสอบ logic finalize range / breakout ด้วยข้อมูลจำลอง

## 10. ค่า Default ตั้งต้น (ปรับได้ทั้งหมด — เป็นจุดเริ่ม optimize)

OR 08:00–08:30, trade ถึง 12:00, force-close 20:00 (server time, Exness GMT+0); buffer = ATR×0.10; TP = 1.8R; BE +1.0R; trailing เริ่ม +1.2R, ระยะ 200 pts; risk 1%/ไม้; daily DD 3%; ตัวกรองเปิดครบ 4 ตัว (toggle อิสระ); spread guard 40 pts (ตั้ง `InpMaxSpreadPoints=0` เพื่อปิด)

## 11. As-built notes (อัปเดตหลัง implement)

ส่วนที่ต่างจากแบบเดิมเล็กน้อย (functionally equivalent):
- **`InpMaxTradesPerDay` ถูกตัดออก** — กฎ 1 ไม้/วัน บังคับด้วย state (`g_tradedToday` + `ENTRY_DONE`) อยู่แล้ว input นี้ไม่ถูกใช้จริงจึงเอาออกกัน config หลอกตา
- **การสร้างกรอบ** ใช้ `FinalizeRange()` (CopyRates ครอบช่วง OR ทีเดียว) แทน accumulator แบบ incremental — ผลเท่ากัน เรียบง่ายกว่า
- **Daily-DD breaker เช็คทุก tick** (ไม่ใช่เฉพาะแท่งใหม่) เพื่อป้องกัน intra-bar crash ทันเวลา; latch ทั้งวันเมื่อ trip
- **`trade.SetTypeFillingBySymbol(_Symbol)`** ตั้งใน OnInit (Exness/ECN ต้องการ IOC/RETURN ไม่ใช่ FOK default)
- **ข้อจำกัดที่รู้:** ถ้าปิด `InpForceCloseEnable` แล้วถือไม้ข้ามวัน BE/trailing จะหยุดทำงานกับไม้นั้น (g_initialRisk reset เป็น 0) — ไม้ยังมี SL/TP เดิมป้องกันอยู่ ค่า default (force-close เปิด) ครอบกรณีนี้แล้ว
