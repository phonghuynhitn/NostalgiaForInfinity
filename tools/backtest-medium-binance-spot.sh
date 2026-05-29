#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE="${IMAGE:-nfi-freqtrade}"
STRATEGY="${STRATEGY:-NostalgiaForInfinityX7}"
TIMERANGE="${TIMERANGE:-20250101-20260528}"
PAIRLIST_CONFIG="${PAIRLIST_CONFIG:-configs/pairlist-backtest-static-binance-spot-usdt-medium.json}"
BACKTEST_DIR="${BACKTEST_DIR:-user_data/backtest_results}"
NOTES="${NOTES:-medium-binance-spot-${TIMERANGE}}"
DOWNLOAD_DATA="${DOWNLOAD_DATA:-false}"
TIMEFRAMES="${TIMEFRAMES:-5m 1m 15m 1h 4h 1d}"
DRY_RUN_WALLET="${DRY_RUN_WALLET:-1000}"
MAX_OPEN_TRADES="${MAX_OPEN_TRADES:-4}"
QUIET_OUTPUT="${QUIET_OUTPUT:-true}"
RUN_LOG_FILE="${RUN_LOG_FILE:-${ROOT_DIR}/user_data/logs/backtest-${STRATEGY}-spot-${TIMERANGE}.log}"

STRATEGY_FILE="${ROOT_DIR}/${STRATEGY}.py"
if [[ ! -f "${STRATEGY_FILE}" ]]; then
  echo "Strategy file not found: ${STRATEGY_FILE}" >&2
  exit 1
fi

if [[ ! -f "${ROOT_DIR}/${PAIRLIST_CONFIG}" ]]; then
  echo "Pairlist config not found: ${ROOT_DIR}/${PAIRLIST_CONFIG}" >&2
  exit 1
fi

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  docker build -f "${ROOT_DIR}/docker/Dockerfile.custom" -t "${IMAGE}" "${ROOT_DIR}"
fi

mkdir -p "${ROOT_DIR}/${BACKTEST_DIR}" "${ROOT_DIR}/user_data/logs"

CONFIG_ARGS=(
  -c /freqtrade/configs/trading_mode-spot.json
  -c /freqtrade/configs/exampleconfig.json
  -c /freqtrade/configs/exampleconfig_secret.json
  -c /freqtrade/configs/blacklist-binance.json
  -c "/freqtrade/${PAIRLIST_CONFIG}"
)

if [[ "${DOWNLOAD_DATA}" == "true" ]]; then
  docker run --rm -it \
    -v "${ROOT_DIR}/user_data:/freqtrade/user_data" \
    -v "${ROOT_DIR}/configs:/freqtrade/configs" \
    -v "${STRATEGY_FILE}:/freqtrade/${STRATEGY}.py:ro" \
    "${IMAGE}" download-data \
    --user-data-dir /freqtrade/user_data \
    --exchange binance \
    --trading-mode spot \
    --timeframes ${TIMEFRAMES} \
    --timerange "${TIMERANGE}" \
    "${CONFIG_ARGS[@]}"
fi

BACKTEST_CMD=(
docker run --rm -i
  -v "${ROOT_DIR}/user_data:/freqtrade/user_data"
  -v "${ROOT_DIR}/configs:/freqtrade/configs"
  -v "${STRATEGY_FILE}:/freqtrade/${STRATEGY}.py:ro"
  "${IMAGE}" backtesting
  --user-data-dir /freqtrade/user_data
  --strategy "${STRATEGY}"
  --strategy-path /freqtrade
  --timerange "${TIMERANGE}"
  "${CONFIG_ARGS[@]}"
  --max-open-trades "${MAX_OPEN_TRADES}"
  --export signals
  --dry-run-wallet "${DRY_RUN_WALLET}"
  --cache none
  --breakdown day
  --backtest-directory "/freqtrade/${BACKTEST_DIR}"
  --notes "${NOTES}"
)

if [[ "${QUIET_OUTPUT}" == "true" ]]; then
  set +e
  "${BACKTEST_CMD[@]}" --no-color "$@" > "${RUN_LOG_FILE}" 2>&1
  status=$?
  set -e
  if [[ ${status} -ne 0 ]]; then
    echo "Backtest failed with exit code ${status}. Full log: ${RUN_LOG_FILE}" >&2
    exit "${status}"
  fi

  awk '
    /BACKTESTING REPORT|LEFT OPEN TRADES REPORT|ENTER TAG STATS|EXIT REASON STATS|SUMMARY METRICS/ {
      show = 1
    }
    show {
      print
    }
  ' "${RUN_LOG_FILE}"
  echo "Full run log: ${RUN_LOG_FILE}" >&2
else
  "${BACKTEST_CMD[@]}" "$@"
fi
