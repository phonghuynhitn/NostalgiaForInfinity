#!/usr/bin/env bash
# Close Binance USDT-M futures position: RIFUSDT long (reduce-only market sell).
#
# Usage:
#   export BINANCE_API_KEY='your_key'
#   export BINANCE_API_SECRET='your_secret'
#   ./tools/close_rifusdt.sh            # preview / dry info
#   ./tools/close_rifusdt.sh --execute  # actually close
#
# Optional overrides:
#   SYMBOL=RIFUSDT AMOUNT=15201 SIDE=SELL ./tools/close_rifusdt.sh --execute

set -euo pipefail

API_KEY="${BINANCE_API_KEY:-${FREQTRADE__EXCHANGE__KEY:-}}"
API_SECRET="${BINANCE_API_SECRET:-${FREQTRADE__EXCHANGE__SECRET:-}}"
BASE_URL="${BINANCE_FAPI_URL:-https://fapi.binance.com}"

SYMBOL="${SYMBOL:-RIFUSDT}"
AMOUNT="${AMOUNT:-15201}"
SIDE="${SIDE:-SELL}"   # SELL closes a LONG; BUY closes a SHORT
RECV_WINDOW="${RECV_WINDOW:-10000}"

EXECUTE=0
if [[ "${1:-}" == "--execute" ]]; then
  EXECUTE=1
fi

if [[ -z "$API_KEY" || -z "$API_SECRET" ]]; then
  echo "Missing API credentials."
  echo "Set BINANCE_API_KEY and BINANCE_API_SECRET (virtual subaccount keys)."
  exit 1
fi

if [[ "$API_KEY" == "KEY" || "$API_KEY" == "Put_Your_Exchange_Key_Here" || "$API_KEY" == *CHANGE_ME* ]]; then
  echo "API key looks like a placeholder. Use the real virtual subaccount key."
  exit 1
fi

sign() {
  local query="$1"
  printf '%s' "$query" | openssl dgst -sha256 -hmac "$API_SECRET" | awk '{print $2}'
}

timestamp_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

echo "=== Close plan ==="
echo "symbol : $SYMBOL"
echo "side   : $SIDE (reduceOnly MARKET)"
echo "amount : $AMOUNT"
echo "url    : $BASE_URL"

if [[ "$EXECUTE" -ne 1 ]]; then
  echo
  echo "Preview only. Run again with --execute to send the order."
  exit 0
fi

TS="$(timestamp_ms)"
QUERY="symbol=${SYMBOL}&side=${SIDE}&type=MARKET&quantity=${AMOUNT}&reduceOnly=true&newOrderRespType=RESULT&recvWindow=${RECV_WINDOW}&timestamp=${TS}"
SIG="$(sign "$QUERY")"

echo
echo "Submitting reduce-only market close..."
RESP="$(curl -sS -X POST "${BASE_URL}/fapi/v1/order?${QUERY}&signature=${SIG}" \
  -H "X-MBX-APIKEY: ${API_KEY}")"

echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"

# Basic success check
if echo "$RESP" | grep -q '"orderId"'; then
  echo
  echo "Order submitted."
  exit 0
fi

echo
echo "Close failed (no orderId in response)."
exit 2
