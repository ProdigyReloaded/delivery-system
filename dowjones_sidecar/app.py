"""
Tiny sidecar that fronts the upstream quote API for the Elixir
delivery-system server.

The underlying Python library handles the upstream cookie + crumb
handshake over curl_cffi. The cookie cache lives in a docker-managed
volume and is seeded once from a working install; the library
refreshes it from there.

Endpoint contract: GET /quote/<symbol> returns a fixed JSON shape
the Elixir caller's existing decoder consumes. We use the
quoteSummary endpoint since it returns price + volume + shortName
in one call - that endpoint requires the cookie/crumb dance which
the library now handles end-to-end with the seeded cache.
"""
import logging
import math
from fastapi import FastAPI, HTTPException
import yfinance as yf

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("dowjones-sidecar")

app = FastAPI(title="dowjones-sidecar")


@app.get("/health")
def health():
    return {"ok": True}


def _safe_float(v):
    """Upstream / pandas can return NaN; encode that as null."""
    if v is None:
        return None
    try:
        f = float(v)
        if math.isnan(f) or math.isinf(f):
            return None
        return f
    except (TypeError, ValueError):
        return None


@app.get("/quote/{symbol}")
def get_quote(symbol: str):
    sym = symbol.strip().upper()
    logger.info("quote request: %s", sym)

    try:
        ticker = yf.Ticker(sym)
        info = ticker.info or {}
    except Exception as e:
        logger.warning("upstream error for %s: %s", sym, e)
        raise HTTPException(status_code=502, detail=f"upstream error: {e}")

    price = _safe_float(info.get("regularMarketPrice") or info.get("currentPrice"))
    if price is None:
        logger.warning("no price in upstream info for %s", sym)
        raise HTTPException(status_code=404, detail=f"no quote for {sym}")

    return {
        "quoteResponse": {
            "result": [
                {
                    "shortName": info.get("shortName") or sym,
                    "longName": info.get("longName") or info.get("shortName") or sym,
                    "regularMarketChange": _safe_float(info.get("regularMarketChange")),
                    "regularMarketDayHigh": _safe_float(
                        info.get("regularMarketDayHigh") or info.get("dayHigh")
                    ),
                    "regularMarketDayLow": _safe_float(
                        info.get("regularMarketDayLow") or info.get("dayLow")
                    ),
                    "regularMarketOpen": _safe_float(
                        info.get("regularMarketOpen") or info.get("open")
                    ),
                    "regularMarketPrice": price,
                    "regularMarketVolume": _safe_float(
                        info.get("regularMarketVolume") or info.get("volume")
                    ),
                }
            ]
        }
    }
