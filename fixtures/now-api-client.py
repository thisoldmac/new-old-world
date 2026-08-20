#!/usr/bin/env python3
"""Independent NOW API smoke client derived only from the public OpenAPI."""

from __future__ import annotations

import argparse
import http.client
import json
from pathlib import Path
from urllib.parse import urlsplit


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--api-key", required=True)
    args = parser.parse_args()

    contract = json.loads(args.contract.read_text())
    scheme = contract["components"]["securitySchemes"]["apiKey"]
    if any(scheme.get(key) != value for key, value in {
            "type": "apiKey", "in": "header", "name": "X-API-Key"}.items()):
        raise SystemExit("contract does not declare the expected API-key header")

    required = {"/", "/guests"}
    if not required.issubset(contract["paths"]):
        raise SystemExit("contract does not publish identity and guest discovery")
    reaches = contract["components"]["schemas"]["OperationError"]["properties"][
        "reach"]["enum"]
    if not {"operation", "transfer"}.issubset(reaches):
        raise SystemExit("contract omits a public runtime error reach")

    endpoint = urlsplit(args.base_url.rstrip("/"))
    contract_base = urlsplit(contract["servers"][0]["url"]).path.rstrip("/")
    connection = http.client.HTTPConnection(endpoint.hostname, endpoint.port)
    headers = {scheme["name"]: args.api_key, "Accept": "application/json"}
    results = {}
    try:
        for name, path in (("identity", "/"), ("guests", "/guests")):
            request_path = contract_base if path == "/" else contract_base + path
            connection.request("GET", request_path, headers=headers)
            response = connection.getresponse()
            body = response.read()
            if response.status != 200:
                raise SystemExit(f"{path} returned HTTP {response.status}")
            results[name] = json.loads(body)
    finally:
        connection.close()
    print(json.dumps(results, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
