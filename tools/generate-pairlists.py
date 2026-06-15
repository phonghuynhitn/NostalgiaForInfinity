#!/usr/bin/env python3
"""Generate shared Freqtrade RemotePairList files for multi-bot deployments."""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sqlite3
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


LOGGER = logging.getLogger("generate-pairlists")


@dataclass(frozen=True)
class Candidate:
  symbol: str
  base: str
  quote_volume: float


def strip_json_comments(raw: str) -> str:
  """Remove JSONC-style comments without touching string contents."""
  result: list[str] = []
  in_string = False
  escaped = False
  i = 0

  while i < len(raw):
    char = raw[i]
    next_char = raw[i + 1] if i + 1 < len(raw) else ""

    if in_string:
      result.append(char)
      if escaped:
        escaped = False
      elif char == "\\":
        escaped = True
      elif char == '"':
        in_string = False
      i += 1
      continue

    if char == '"':
      in_string = True
      result.append(char)
      i += 1
      continue

    if char == "/" and next_char == "/":
      i += 2
      while i < len(raw) and raw[i] not in "\r\n":
        i += 1
      continue

    if char == "/" and next_char == "*":
      i += 2
      while i + 1 < len(raw) and not (raw[i] == "*" and raw[i + 1] == "/"):
        i += 1
      i += 2
      continue

    result.append(char)
    i += 1

  return "".join(result)


def load_jsonc(path: Path) -> dict[str, Any]:
  with path.open(encoding="utf-8") as handle:
    return json.loads(strip_json_comments(handle.read()))


def resolve_path(config_path: Path, value: str) -> Path:
  path = Path(value)
  if path.is_absolute():
    return path
  return config_path.parent / path


def nested_get(data: dict[str, Any], dotted_key: str) -> Any:
  current: Any = data
  for part in dotted_key.split("."):
    if not isinstance(current, dict):
      return None
    current = current.get(part)
  return current


def parse_float(value: Any) -> float:
  if value is None:
    return 0.0
  try:
    return float(value)
  except (TypeError, ValueError):
    return 0.0


def ticker_quote_volume(ticker: dict[str, Any]) -> float:
  quote_volume = parse_float(ticker.get("quoteVolume"))
  if quote_volume > 0:
    return quote_volume

  quote_volume = parse_float(nested_get(ticker, "info.quoteVolume"))
  if quote_volume > 0:
    return quote_volume

  last = parse_float(ticker.get("last"))
  base_volume = parse_float(ticker.get("baseVolume"))
  return last * base_volume


def compile_blacklist(path: Path) -> list[re.Pattern[str]]:
  if not path.exists():
    raise FileNotFoundError(f"Blacklist config not found: {path}")

  config = load_jsonc(path)
  patterns = config.get("exchange", {}).get("pair_blacklist", [])
  return [re.compile(pattern) for pattern in patterns]


def is_blacklisted(symbol: str, blacklist: list[re.Pattern[str]]) -> bool:
  return any(pattern.search(symbol) for pattern in blacklist)


def read_open_trade_pairs(db_path: Path) -> list[str]:
  if not db_path.exists():
    LOGGER.debug("Open-trade DB does not exist, skipping: %s", db_path)
    return []

  try:
    with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True) as connection:
      rows = connection.execute("SELECT DISTINCT pair FROM trades WHERE is_open = 1 ORDER BY pair").fetchall()
  except sqlite3.Error as exc:
    LOGGER.warning("Could not read open trades from %s: %s", db_path, exc)
    return []

  return [row[0] for row in rows if row and row[0]]


def pinned_pairs_for_bucket(config_path: Path, bucket: dict[str, Any]) -> list[str]:
  pairs: list[str] = []
  seen: set[str] = set()

  for db_path_value in bucket.get("open_trade_db_paths", []):
    db_path = resolve_path(config_path, db_path_value)
    for pair in read_open_trade_pairs(db_path):
      if pair not in seen:
        seen.add(pair)
        pairs.append(pair)

  return pairs


def create_exchange(exchange_config: dict[str, Any]) -> Any:
  try:
    import ccxt
  except ImportError as exc:
    raise RuntimeError("ccxt is required. Run this script inside the Freqtrade image or install ccxt.") from exc

  exchange_name = exchange_config["name"]
  exchange_class = getattr(ccxt, exchange_name)
  ccxt_config = {
    "enableRateLimit": True,
    **exchange_config.get("ccxt_config", {}),
  }
  return exchange_class(ccxt_config)


def market_matches(market: dict[str, Any], exchange_config: dict[str, Any]) -> bool:
  if market.get("active") is False:
    return False

  if market.get("quote") != exchange_config["quote"]:
    return False

  settle = exchange_config.get("settle")
  if settle and market.get("settle") != settle:
    return False

  market_type = exchange_config.get("market_type")
  if market_type == "swap" and not market.get("swap"):
    return False
  if market_type and market_type != "swap" and market.get("type") != market_type:
    return False

  contract_type = exchange_config.get("contract_type")
  if contract_type and nested_get(market, "info.contractType") != contract_type:
    return False

  return True


def fetch_candidates(config: dict[str, Any], blacklist: list[re.Pattern[str]]) -> list[Candidate]:
  exchange_config = config["exchange"]
  exchange = create_exchange(exchange_config)
  markets = exchange.load_markets()
  tickers = exchange.fetch_tickers()
  min_quote_volume = parse_float(config.get("min_quote_volume"))

  candidates: list[Candidate] = []
  for symbol, market in markets.items():
    if not market_matches(market, exchange_config):
      continue

    if is_blacklisted(symbol, blacklist):
      continue

    ticker = tickers.get(symbol, {})
    quote_volume = ticker_quote_volume(ticker)
    if quote_volume < min_quote_volume:
      continue

    candidates.append(Candidate(symbol=symbol, base=market["base"], quote_volume=quote_volume))

  candidates.sort(key=lambda candidate: (-candidate.quote_volume, candidate.symbol))
  return candidates


def select_bucket(
  bucket: dict[str, Any],
  candidates: list[Candidate],
  assigned: set[str],
) -> list[Candidate]:
  include_bases = set(bucket.get("include_bases", []))
  allow_overlap = bool(bucket.get("allow_overlap", False))
  number_assets = int(bucket["number_assets"])
  offset = int(bucket.get("offset", 0))

  pool = candidates
  if include_bases:
    pool = [candidate for candidate in pool if candidate.base in include_bases]

  if not allow_overlap:
    pool = [candidate for candidate in pool if candidate.symbol not in assigned]

  selected = pool[offset : offset + number_assets]

  if not allow_overlap:
    assigned.update(candidate.symbol for candidate in selected)

  return selected


def atomic_write_json(path: Path, data: dict[str, Any]) -> None:
  path.parent.mkdir(parents=True, exist_ok=True)
  tmp_path = path.with_name(f".{path.name}.tmp")
  with tmp_path.open("w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
  os.replace(tmp_path, path)


def write_outputs(config_path: Path, config: dict[str, Any], candidates: list[Candidate]) -> None:
  output_dir = resolve_path(config_path, config["output_dir"])
  refresh_period = int(config["refresh_period"])
  generated_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
  assigned: set[str] = set()
  summary: dict[str, int] = {}

  for bucket in config["buckets"]:
    selected = select_bucket(bucket, candidates, assigned)
    pinned_pairs = pinned_pairs_for_bucket(config_path, bucket)
    output_path = output_dir / bucket["output"]
    pinned_output_path = output_dir / bucket.get("pinned_output", f"pinned-{bucket['output']}")
    atomic_write_json(
      output_path,
      {
        "pairs": [candidate.symbol for candidate in selected],
        "refresh_period": refresh_period,
      },
    )
    atomic_write_json(
      pinned_output_path,
      {
        "pairs": pinned_pairs,
        "refresh_period": refresh_period,
      },
    )
    summary[bucket["name"]] = {
      "selected": len(selected),
      "pinned": len(pinned_pairs),
    }
    LOGGER.info("Wrote %s selected pairs to %s", len(selected), output_path)
    LOGGER.info("Wrote %s pinned open-trade pairs to %s", len(pinned_pairs), pinned_output_path)

  ready_file = config.get("ready_file")
  if ready_file:
    ready_path = output_dir / ready_file
    ready_path.write_text(
      json.dumps(
        {
          "generated_at": generated_at,
          "candidate_count": len(candidates),
          "buckets": summary,
        },
        indent=2,
      )
      + "\n",
      encoding="utf-8",
    )


def generate(config_path: Path) -> None:
  config = load_jsonc(config_path)
  blacklist_path = resolve_path(config_path, config["blacklist_config"])
  blacklist = compile_blacklist(blacklist_path)
  candidates = fetch_candidates(config, blacklist)

  if not candidates:
    raise RuntimeError("No pair candidates remained after market and blacklist filtering.")

  LOGGER.info("Fetched %s valid candidates", len(candidates))
  write_outputs(config_path, config, candidates)


def parse_args() -> argparse.Namespace:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument(
    "--config",
    type=Path,
    default=Path("configs/pairlist-generator-binance-futures-usdt.json"),
    help="Path to the pairlist generator config.",
  )
  parser.add_argument("--loop", action="store_true", help="Refresh forever using the configured refresh period.")
  parser.add_argument("--interval", type=int, help="Override refresh period when running with --loop.")
  parser.add_argument("--log-level", default="INFO", help="Python logging level.")
  return parser.parse_args()


def main() -> int:
  args = parse_args()
  logging.basicConfig(level=args.log_level.upper(), format="%(asctime)s %(levelname)s %(message)s")
  config_path = args.config.resolve()

  if not args.loop:
    generate(config_path)
    return 0

  while True:
    try:
      generate(config_path)
    except Exception:
      LOGGER.exception("Pairlist generation failed")

    config = load_jsonc(config_path)
    interval = args.interval or int(config["refresh_period"])
    time.sleep(interval)


if __name__ == "__main__":
  sys.exit(main())
