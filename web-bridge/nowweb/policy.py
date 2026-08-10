"""Listener-peer and outbound-address policy for the unauthenticated proxy."""

from __future__ import annotations

from dataclasses import dataclass
import ipaddress
import socket
from urllib.parse import urlsplit


class PolicyError(ValueError):
    pass


def _unsafe(address: str) -> bool:
    ip = ipaddress.ip_address(address.split("%", 1)[0])
    return (ip.is_private or ip.is_loopback or ip.is_link_local or
            ip.is_multicast or ip.is_unspecified or ip.is_reserved)


@dataclass(frozen=True)
class OutboundPolicy:
    allow_private: bool = False

    def validate(self, url: str) -> str:
        parsed = urlsplit(url)
        if parsed.scheme not in {"http", "https"}:
            raise PolicyError("only http and https destinations are supported")
        if not parsed.hostname or parsed.username or parsed.password:
            raise PolicyError("destination must have an ordinary host name")
        if parsed.port is not None and not 1 <= parsed.port <= 65535:
            raise PolicyError("destination port is out of range")
        try:
            infos = socket.getaddrinfo(parsed.hostname, parsed.port or 443,
                                       type=socket.SOCK_STREAM)
        except socket.gaierror as exc:
            raise PolicyError("destination name did not resolve") from exc
        addresses = {item[4][0] for item in infos}
        if not self.allow_private and any(_unsafe(item) for item in addresses):
            raise PolicyError("private, local and special destinations are blocked")
        return url


@dataclass(frozen=True)
class PeerPolicy:
    allowed_clients: frozenset[str] = frozenset()

    def allows(self, address: str) -> bool:
        return not self.allowed_clients or address in self.allowed_clients
