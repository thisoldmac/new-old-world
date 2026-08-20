#!/usr/bin/env python3
"""Independent API fixture: stdlib HTTP and JSON, with no MCP vocabulary."""

import http.client
import json
import sys

port = int(sys.argv[1])
api_key = sys.argv[2]
connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
connection.request("DELETE", "/api/v1/listener", headers={"X-API-Key": api_key})
stopped = connection.getresponse()
json.loads(stopped.read())
assert stopped.status == 200, stopped.status

# The guest listener and API listener have different ownership. A fresh TCP
# exchange must still reach the API after the guest-facing sockets stop.
connection.request("GET", "/api/v1", headers={"X-API-Key": api_key})
response = connection.getresponse()
body = json.loads(response.read())
assert response.status == 200, response.status
assert body["apiMajor"] == 1
assert len(body["contractDigest"]) == 64
assert "jsonrpc" not in body
assert "tools" not in body
