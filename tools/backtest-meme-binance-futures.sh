#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_TIMERANGE="${TIMERANGE:-20250101-20260528}"
DEFAULT_STRATEGY="${STRATEGY:-NostalgiaForInfinityX7}"

export BASE_CONFIG="${BASE_CONFIG:-configs/recommended_config_backtest_meme.json}"
export PAIRLIST_CONFIG="${PAIRLIST_CONFIG:-configs/pairlist-backtest-static-binance-futures-usdt-meme.json}"
export DRY_RUN_WALLET="${DRY_RUN_WALLET:-150}"
export NOTES="${NOTES:-meme-binance-futures-${DEFAULT_TIMERANGE}}"
export RUN_LOG_FILE="${RUN_LOG_FILE:-${ROOT_DIR}/user_data/logs/backtest-${DEFAULT_STRATEGY}-meme-${DEFAULT_TIMERANGE}.log}"

exec "${ROOT_DIR}/tools/backtest-lite-binance-futures.sh" "$@"
