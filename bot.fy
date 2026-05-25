import time
import requests
from datetime import datetime

# ── CONFIG ────────────────────────────────────────────────────────────────────
TWELVE_KEY = "70de0808e92b43679c4bc30323c705fa"
TG_TOKEN   = "8943634417:AAFZ3tdavZW2HM3JzQEFXyeroBbalczlFEI"
TG_CHAT    = "8021006007"

# Signal rules
MIN_CONFIDENCE  = 75
COOLDOWN_MINS   = 20
MAX_PER_HOUR    = 5
SCAN_DELAY_SECS = 5  # delay between each pair scan

# All pairs
REGULAR_PAIRS = ["EUR/USD","GBP/USD","USD/JPY","AUD/USD","BTC/USD","ETH/USD"]
OTC_PAIRS     = ["EUR/USD OTC","GBP/USD OTC","USD/JPY OTC","AUD/CAD OTC","EUR/JPY OTC"]
ALL_PAIRS     = REGULAR_PAIRS + OTC_PAIRS

SYMBOL_MAP = {
    "EUR/USD":"EUR/USD","GBP/USD":"GBP/USD","USD/JPY":"USD/JPY",
    "AUD/USD":"AUD/USD","BTC/USD":"BTC/USD","ETH/USD":"ETH/USD",
    "EUR/USD OTC":"EUR/USD","GBP/USD OTC":"GBP/USD",
    "USD/JPY OTC":"USD/JPY","AUD/CAD OTC":"AUD/CAD","EUR/JPY OTC":"EUR/JPY"
}

# ── STATE ─────────────────────────────────────────────────────────────────────
last_signal_time = {}
signal_timestamps = []
scan_count = 0
signal_count = 0

# ── TELEGRAM ──────────────────────────────────────────────────────────────────
def send_telegram(message):
    try:
        url = f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage"
        data = {"chat_id": TG_CHAT, "text": message, "parse_mode": "HTML"}
        requests.post(url, json=data, timeout=10)
    except Exception as e:
        print(f"Telegram error: {e}")

def build_tg_message(sig):
    direction  = sig["direction"]
    pair       = sig["pair"]
    strength   = sig["strength"]
    confidence = sig["confidence"]
    expiry     = sig["expiry_minutes"]
    score      = sig["score"]
    confs      = sig["confluences"]
    rsi_val    = sig.get("rsi", "—")
    support    = sig.get("support", "—")
    resistance = sig.get("resistance", "—")
    pattern    = sig.get("pattern", "No pattern")
    sig_time   = sig["time"]

    emoji    = "🟢" if direction == "CALL" else "🔴"
    arrow    = "▲ CALL" if direction == "CALL" else "▼ PUT"
    s_emoji  = "✅✅✅" if strength == "ULTRA STRONG" else "✅✅" if strength == "STRONG" else "⚡"
    risk     = "VERY LOW RISK" if strength == "ULTRA STRONG" else "LOW RISK" if strength == "STRONG" else "MEDIUM RISK"
    bars     = "█" * min(score, 6) + "░" * max(6 - score, 0)
    otc_tag  = " [OTC 24/7]" if "OTC" in pair else ""
    confs_text = "\n".join([f"✓ {c}" for c in confs])

    return f"""{emoji} <b>{strength} SIGNAL</b> {s_emoji}

<b>Pair:</b> {pair}{otc_tag}
<b>Direction:</b> {arrow}

<b>Timeframes Confirmed:</b>
✅ H1 (1 Hour) — Trend Direction
✅ M5 (5 Min) — Setup Confirmation  
✅ M1 (1 Min) — Entry Timing

<b>Expiry:</b> {expiry} MINUTES EXACT
<b>Enter within:</b> 60 seconds NOW!

<b>Confidence:</b> {confidence}%
<b>Score:</b> {score}/6  [{bars}]
<b>Risk:</b> {risk}

<b>Confluences ({len(confs)}):</b>
{confs_text}

<b>RSI (M5):</b> {rsi_val}
<b>Support:</b> {support}
<b>Resistance:</b> {resistance}
<b>Pattern:</b> {pattern}

🕐 <b>Time:</b> {sig_time}
⚠️ <i>Always confirm on chart. Manage your risk.</i>"""

# ── TWELVE DATA API ───────────────────────────────────────────────────────────
def fetch_candles(pair, interval, size=60):
    symbol = SYMBOL_MAP.get(pair, pair)
    url = f"https://api.twelvedata.com/time_series"
    params = {
        "symbol": symbol,
        "interval": interval,
        "outputsize": size,
        "apikey": TWELVE_KEY
    }
    try:
        r = requests.get(url, params=params, timeout=15)
        data = r.json()
        if "values" not in data:
            return None
        candles = []
        for v in reversed(data["values"]):
            candles.append({
                "open":  float(v["open"]),
                "close": float(v["close"]),
                "high":  float(v["high"]),
                "low":   float(v["low"]),
            })
        return candles
    except Exception as e:
        print(f"API error ({pair} {interval}): {e}")
        return None

# ── INDICATORS ────────────────────────────────────────────────────────────────
def calc_ema(closes, period):
    if len(closes) < period:
        return []
    k = 2 / (period + 1)
    ema = sum(closes[:period]) / period
    result = [None] * (period - 1)
    result.append(ema)
    for price in closes[period:]:
        ema = price * k + ema * (1 - k)
        result.append(ema)
    return result

def calc_rsi(closes, period=14):
    if len(closes) < period + 1:
        return None
    gains = losses = 0
    for i in range(1, period + 1):
        diff = closes[i] - closes[i-1]
        if diff > 0: gains += diff
        else: losses -= diff
    avg_gain = gains / period
    avg_loss = losses / period
    for i in range(period + 1, len(closes)):
        diff = closes[i] - closes[i-1]
        avg_gain = (avg_gain * (period-1) + max(diff, 0)) / period
        avg_loss = (avg_loss * (period-1) + max(-diff, 0)) / period
    if avg_loss == 0:
        return 100
    rs = avg_gain / avg_loss
    return 100 - 100 / (1 + rs)

def calc_bb(closes, period=20, mult=2):
    if len(closes) < period:
        return None
    sl = closes[-period:]
    mean = sum(sl) / period
    std = (sum((x - mean)**2 for x in sl) / period) ** 0.5
    return {"upper": mean + mult*std, "middle": mean, "lower": mean - mult*std}

def calc_stoch_rsi(closes, period=14):
    rsi_vals = []
    for i in range(period, len(closes)+1):
        r = calc_rsi(closes[:i], period)
        if r is not None:
            rsi_vals.append(r)
    if len(rsi_vals) < period:
        return None
    sl = rsi_vals[-period:]
    mn, mx = min(sl), max(sl)
    if mx == mn:
        return 50
    return ((sl[-1] - mn) / (mx - mn)) * 100

def detect_sr(candles, lookback=30):
    recent = candles[-lookback:]
    return {
        "support":    min(c["low"]  for c in recent),
        "resistance": max(c["high"] for c in recent)
    }

def detect_pattern(candles):
    if len(candles) < 3:
        return None
    p2, p1, c = candles[-3], candles[-2], candles[-1]
    body  = lambda x: abs(x["close"] - x["open"])
    rng   = lambda x: x["high"] - x["low"]
    bull  = lambda x: x["close"] > x["open"]
    bear  = lambda x: x["close"] < x["open"]

    if bear(p1) and bull(c) and c["open"] < p1["close"] and c["close"] > p1["open"]:
        return {"pattern": "Bullish Engulfing", "direction": "CALL"}
    if bull(p1) and bear(c) and c["open"] > p1["close"] and c["close"] < p1["open"]:
        return {"pattern": "Bearish Engulfing", "direction": "PUT"}
    if body(c) < rng(c)*0.3 and (c["low"] - min(c["open"],c["close"])) > body(c)*2:
        return {"pattern": "Hammer/Pin Bar", "direction": "CALL"}
    if body(c) < rng(c)*0.3 and (c["high"] - max(c["open"],c["close"])) > body(c)*2:
        return {"pattern": "Shooting Star", "direction": "PUT"}
    if bear(p2) and body(p1) < body(p2)*0.3 and bull(c) and c["close"] > (p2["open"]+p2["close"])/2:
        return {"pattern": "Morning Star", "direction": "CALL"}
    if bull(p2) and body(p1) < body(p2)*0.3 and bear(c) and c["close"] < (p2["open"]+p2["close"])/2:
        return {"pattern": "Evening Star", "direction": "PUT"}
    return None

def has_volatility(candles, n=5):
    if len(candles) < n:
        return False
    last = candles[-n:]
    avg_body  = sum(abs(c["close"]-c["open"]) for c in last) / n
    avg_range = sum(c["high"]-c["low"] for c in last) / n
    return avg_range > 0 and (avg_body / avg_range) > 0.2

def get_decimal_places(pair):
    if "JPY" in pair: return 3
    if "BTC" in pair or "ETH" in pair: return 2
    return 5

# ── H1 ANALYSIS (Trend Direction) ────────────────────────────────────────────
def analyze_h1(candles):
    if not candles or len(candles) < 30:
        return None
    closes = [c["close"] for c in candles]
    e9  = calc_ema(closes, 9)
    e21 = calc_ema(closes, 21)
    e50 = calc_ema(closes, 50)
    rv  = calc_rsi(closes)
    if not e9 or not e21 or not e50:
        return None
    v9, v21, v50 = e9[-1], e21[-1], e50[-1]

    if v9 > v21 and v21 > v50:
        direction = "CALL"
        confs = ["H1 EMA Bullish Stack (9>21>50)"]
    elif v9 < v21 and v21 < v50:
        direction = "PUT"
        confs = ["H1 EMA Bearish Stack (9<21<50)"]
    else:
        return None  # No clear H1 trend

    if rv is not None:
        if rv < 50 and direction == "CALL":
            confs.append(f"H1 RSI Bullish Zone ({rv:.1f})")
        elif rv > 50 and direction == "PUT":
            confs.append(f"H1 RSI Bearish Zone ({rv:.1f})")

    return {"direction": direction, "confs": confs}

# ── M5 ANALYSIS (Setup Confirmation) ─────────────────────────────────────────
def analyze_m5(candles, pair):
    if not candles or len(candles) < 50:
        return None
    if not has_volatility(candles):
        return None
    closes = [c["close"] for c in candles]
    curr   = candles[-1]
    e9     = calc_ema(closes, 9)
    e21    = calc_ema(closes, 21)
    e50    = calc_ema(closes, 50)
    rv     = calc_rsi(closes)
    sv     = calc_stoch_rsi(closes)
    bv     = calc_bb(closes)
    sr     = detect_sr(candles)
    cp     = detect_pattern(candles)

    if not e9 or not e21 or not e50:
        return None
    v9, v21, v50 = e9[-1], e21[-1], e50[-1]

    call = put = 0
    confs = []

    # 1. EMA Stack (required)
    if v9 > v21 and v21 > v50:
        call += 2
        confs.append(("M5 EMA Bullish Stack", "CALL"))
    elif v9 < v21 and v21 < v50:
        put += 2
        confs.append(("M5 EMA Bearish Stack", "PUT"))
    else:
        return None

    # 2. RSI
    if rv is not None:
        if rv < 35:
            call += 1
            confs.append((f"M5 RSI Oversold ({rv:.1f})", "CALL"))
        elif rv > 65:
            put += 1
            confs.append((f"M5 RSI Overbought ({rv:.1f})", "PUT"))

    # 3. StochRSI
    if sv is not None:
        if sv < 25:
            call += 1
            confs.append(("M5 StochRSI Oversold", "CALL"))
        elif sv > 75:
            put += 1
            confs.append(("M5 StochRSI Overbought", "PUT"))

    # 4. Bollinger Bands
    if bv:
        if curr["close"] < bv["lower"]:
            call += 1
            confs.append(("M5 BB Lower Touch", "CALL"))
        elif curr["close"] > bv["upper"]:
            put += 1
            confs.append(("M5 BB Upper Touch", "PUT"))

    # 5. Support/Resistance
    price_range = sr["resistance"] - sr["support"] or 0.001
    if abs(curr["close"] - sr["support"]) < price_range * 0.05:
        call += 1
        confs.append(("M5 Price at Key Support", "CALL"))
    elif abs(curr["close"] - sr["resistance"]) < price_range * 0.05:
        put += 1
        confs.append(("M5 Price at Key Resistance", "PUT"))

    # 6. Candle Pattern
    if cp and cp["direction"] != "NEUTRAL":
        if cp["direction"] == "CALL":
            call += 1
            confs.append((f"M5 {cp['pattern']}", "CALL"))
        else:
            put += 1
            confs.append((f"M5 {cp['pattern']}", "PUT"))

    direction = "CALL" if call > put else "PUT" if put > call else None
    if not direction:
        return None

    dp = get_decimal_places(pair)
    return {
        "direction": direction,
        "confs":     [c[0] for c in confs if c[1] == direction],
        "score":     max(call, put),
        "rsi":       f"{rv:.1f}" if rv else "—",
        "stoch_rsi": f"{sv:.1f}" if sv else "—",
        "support":   f"{sr['support']:.{dp}f}",
        "resistance":f"{sr['resistance']:.{dp}f}",
        "pattern":   cp["pattern"] if cp else "No pattern"
    }

# ── M1 ANALYSIS (Entry Timing) ────────────────────────────────────────────────
def analyze_m1(candles):
    if not candles or len(candles) < 20:
        return None
    if not has_volatility(candles):
        return None
    closes = [c["close"] for c in candles]
    curr   = candles[-1]
    e9     = calc_ema(closes, 9)
    e21    = calc_ema(closes, 21)
    rv     = calc_rsi(closes, 7)
    bv     = calc_bb(closes, 15)
    cp     = detect_pattern(candles)

    if not e9 or not e21:
        return None
    v9, v21 = e9[-1], e21[-1]

    call = put = 0
    confs = []

    if v9 > v21:
        call += 1
        confs.append(("M1 EMA Bull Cross", "CALL"))
    elif v9 < v21:
        put += 1
        confs.append(("M1 EMA Bear Cross", "PUT"))

    if rv is not None:
        if rv < 35:
            call += 1
            confs.append((f"M1 RSI Oversold ({rv:.1f})", "CALL"))
        elif rv > 65:
            put += 1
            confs.append((f"M1 RSI Overbought ({rv:.1f})", "PUT"))

    if bv:
        if curr["close"] < bv["lower"]:
            call += 1
            confs.append(("M1 BB Lower Touch", "CALL"))
        elif curr["close"] > bv["upper"]:
            put += 1
            confs.append(("M1 BB Upper Touch", "PUT"))

    if cp and cp["direction"] != "NEUTRAL":
        if cp["direction"] == "CALL":
            call += 1
            confs.append((f"M1 {cp['pattern']}", "CALL"))
        else:
            put += 1
            confs.append((f"M1 {cp['pattern']}", "PUT"))

    direction = "CALL" if call > put else "PUT" if put > call else None
    if not direction:
        return None

    return {
        "direction": direction,
        "confs":     [c[0] for c in confs if c[1] == direction],
        "score":     max(call, put)
    }

# ── COMBINED H1+M5+M1 SIGNAL ──────────────────────────────────────────────────
def analyze_triple(pair, h1_candles, m5_candles, m1_candles):
    global signal_timestamps

    # Cooldown check
    now = time.time()
    if pair in last_signal_time:
        if (now - last_signal_time[pair]) < (COOLDOWN_MINS * 60):
            return None

    # Max signals per hour
    signal_timestamps = [t for t in signal_timestamps if now - t < 3600]
    if len(signal_timestamps) >= MAX_PER_HOUR:
        return None

    # Analyze each timeframe
    h1 = analyze_h1(h1_candles)
    m5 = analyze_m5(m5_candles, pair)
    m1 = analyze_m1(m1_candles)

    if not h1 or not m5 or not m1:
        return None

    # All 3 must agree
    if not (h1["direction"] == m5["direction"] == m1["direction"]):
        return None

    direction  = h1["direction"]
    all_confs  = h1["confs"] + m5["confs"] + m1["confs"]
    total_score = h1.get("score", 1) + m5["score"] + m1["score"]
    confidence = min(int((total_score / 12) * 100), 97)

    if confidence < MIN_CONFIDENCE:
        return None
    if len(all_confs) < 4:
        return None

    # Strength based on all 3 agreeing + confidence
    if confidence >= 88:
        strength       = "ULTRA STRONG"
        expiry_minutes = 5
    elif confidence >= 78:
        strength       = "STRONG"
        expiry_minutes = 5
    else:
        strength       = "MODERATE"
        expiry_minutes = 10

    return {
        "direction":     direction,
        "strength":      strength,
        "confidence":    confidence,
        "score":         min(len(all_confs), 6),
        "confluences":   all_confs[:6],
        "rsi":           m5.get("rsi", "—"),
        "support":       m5.get("support", "—"),
        "resistance":    m5.get("resistance", "—"),
        "pattern":       m5.get("pattern", "No pattern"),
        "expiry_minutes":expiry_minutes,
        "time":          datetime.now().strftime("%H:%M:%S"),
        "pair":          pair
    }

# ── MAIN SCAN LOOP ────────────────────────────────────────────────────────────
def scan_pair(pair):
    global scan_count, signal_count

    print(f"[{datetime.now().strftime('%H:%M:%S')}] Scanning {pair}...")

    # Fetch all 3 timeframes
    h1_data = fetch_candles(pair, "1h",  60)
    time.sleep(0.5)
    m5_data = fetch_candles(pair, "5min", 60)
    time.sleep(0.5)
    m1_data = fetch_candles(pair, "1min", 30)

    scan_count += 1

    if not h1_data or not m5_data or not m1_data:
        print(f"  → No data for {pair}")
        return

    sig = analyze_triple(pair, h1_data, m5_data, m1_data)

    if sig:
        last_signal_time[pair] = time.time()
        signal_timestamps.append(time.time())
        signal_count += 1
        msg = build_tg_message(sig)
        send_telegram(msg)
        print(f"  🔥 SIGNAL FIRED! {sig['direction']} on {pair} | {sig['strength']} | {sig['confidence']}%")
    else:
        print(f"  → No signal for {pair}")

def main():
    print("=" * 50)
    print("  GRAND MASTER BOT v3 — H1+M5+M1")
    print("  Running 24/7 on Render Server")
    print("=" * 50)

    # Startup message
    send_telegram("""🤖 <b>Grand Master Bot v3 is LIVE on Server!</b>

✅ H1 + M5 + M1 Triple Timeframe
✅ Running 24/7 on Render (no browser needed)
✅ Constantly scanning all 11 pairs
✅ Fires instantly when all 3 timeframes agree
✅ All 6 Grand Master factors checked
✅ Real live prices from Twelve Data

<b>Pairs Being Scanned:</b>
EUR/USD · GBP/USD · USD/JPY · AUD/USD
BTC/USD · ETH/USD
EUR/USD OTC · GBP/USD OTC · USD/JPY OTC
AUD/CAD OTC · EUR/JPY OTC

<b>Signal Strengths:</b>
🔥 ULTRA STRONG = 5 min expiry
💪 STRONG = 5 min expiry
⚡ MODERATE = 10 min expiry

Signals will fire to this chat instantly! 🚀""")

    # Main loop — runs forever
    while True:
        for pair in ALL_PAIRS:
            try:
                scan_pair(pair)
                time.sleep(SCAN_DELAY_SECS)
            except Exception as e:
                print(f"Error scanning {pair}: {e}")
                time.sleep(5)

        print(f"\n[{datetime.now().strftime('%H:%M:%S')}] Cycle complete. Total scans: {scan_count} | Signals: {signal_count}\n")

if __name__ == "__main__":
    main()
    
