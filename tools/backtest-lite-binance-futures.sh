#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE="${IMAGE:-nfi-freqtrade}"
STRATEGY="${STRATEGY:-NostalgiaForInfinityX7}"
TIMERANGE="${TIMERANGE:-20250101-20260528}"
BASE_CONFIG="${BASE_CONFIG:-configs/recommended_config_major.json}"
PAIRLIST_CONFIG="${PAIRLIST_CONFIG:-configs/pairlist-backtest-static-binance-futures-usdt-medium.json}"
BACKTEST_DIR="${BACKTEST_DIR:-user_data/backtest_results}"
NOTES="${NOTES:-medium-binance-futures-${TIMERANGE}}"
DOWNLOAD_DATA="${DOWNLOAD_DATA:-false}"
TIMEFRAMES="${TIMEFRAMES:-5m 1m 15m 1h 4h 1d}"

STRATEGY_FILE="${ROOT_DIR}/${STRATEGY}.py"
if [[ ! -f "${STRATEGY_FILE}" ]]; then
  echo "Strategy file not found: ${STRATEGY_FILE}" >&2
  exit 1
fi

if [[ ! -f "${ROOT_DIR}/${BASE_CONFIG}" ]]; then
  echo "Base config not found: ${ROOT_DIR}/${BASE_CONFIG}" >&2
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

if [[ "${DOWNLOAD_DATA}" == "true" ]]; then
  docker run --rm -it \
    -v "${ROOT_DIR}/user_data:/freqtrade/user_data" \
    -v "${ROOT_DIR}/configs:/freqtrade/configs" \
    -v "${STRATEGY_FILE}:/freqtrade/${STRATEGY}.py:ro" \
    "${IMAGE}" download-data \
    --user-data-dir /freqtrade/user_data \
    --exchange binance \
    --trading-mode futures \
    --timeframes ${TIMEFRAMES} \
    --timerange "${TIMERANGE}" \
    -c "/freqtrade/${BASE_CONFIG}" \
    -c "/freqtrade/${PAIRLIST_CONFIG}"
fi

docker run --rm -it \
  -v "${ROOT_DIR}/user_data:/freqtrade/user_data" \
  -v "${ROOT_DIR}/configs:/freqtrade/configs" \
  -v "${STRATEGY_FILE}:/freqtrade/${STRATEGY}.py:ro" \
  "${IMAGE}" backtesting \
  --user-data-dir /freqtrade/user_data \
  --strategy "${STRATEGY}" \
  --strategy-path /freqtrade \
  --timerange "${TIMERANGE}" \
  -c "/freqtrade/${BASE_CONFIG}" \
  -c "/freqtrade/${PAIRLIST_CONFIG}" \
  --export signals \
  --cache none \
  --breakdown day \
  --backtest-directory "/freqtrade/${BACKTEST_DIR}" \
  --notes "${NOTES}" \
  "$@"
