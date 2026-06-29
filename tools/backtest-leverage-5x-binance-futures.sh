#!/usr/bin/env bash
# Backtest Binance Futures with 5x leverage (NFI default is 3x).
#
# Usage:
#   ./tools/backtest-leverage-5x-binance-futures.sh
#
# Optional environment variables:
#   TIMERANGE=20240101-20241231
#   STRATEGY=NostalgiaForInfinityX7
#   BASE_CONFIG=configs/recommended_config_backtest_leverage-5x.json
#   PAIRLIST_CONFIG=configs/pairlist-backtest-static-binance-futures-usdt-lite.json
#   DRY_RUN_WALLET=10000
#   DOWNLOAD_DATA=true
#   QUIET_OUTPUT=false
#
# Mid bot profile:
#   BASE_CONFIG=configs/recommended_config_backtest_leverage-5x-mid.json ./tools/backtest-leverage-5x-binance-futures.sh
#
# Meme bot profile:
#   BASE_CONFIG=configs/recommended_config_backtest_leverage-5x-meme.json \
#   PAIRLIST_CONFIG=configs/pairlist-backtest-static-binance-futures-usdt-meme.json \
#   DRY_RUN_WALLET=150 ./tools/backtest-leverage-5x-binance-futures.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_TIMERANGE="${TIMERANGE:-20250101-20260528}"
DEFAULT_STRATEGY="${STRATEGY:-NostalgiaForInfinityX7}"

export BASE_CONFIG="${BASE_CONFIG:-configs/recommended_config_backtest_leverage-5x.json}"
export PAIRLIST_CONFIG="${PAIRLIST_CONFIG:-configs/pairlist-backtest-static-binance-futures-usdt-medium.json}"
export DRY_RUN_WALLET="${DRY_RUN_WALLET:-1000}"
export NOTES="${NOTES:-leverage-5x-binance-futures-${DEFAULT_TIMERANGE}}"
export RUN_LOG_FILE="${RUN_LOG_FILE:-${ROOT_DIR}/user_data/logs/backtest-${DEFAULT_STRATEGY}-leverage-5x-${DEFAULT_TIMERANGE}.log}"

exec "${ROOT_DIR}/tools/backtest-lite-binance-futures.sh" "$@"
