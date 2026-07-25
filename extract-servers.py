#!/usr/bin/env python3
"""
extract-servers.py — Single source of truth for the monitored DNS server IPs.

Reads the DoT source config in tool/ (a WAN-Up / stubby script) and emits the
IPv4 addresses (A records) of the configured upstream resolvers — one per line,
in file order, de-duplicated.

Servers are taken from the active `address_data:` lines. Lines that are
commented out (first non-space character is '#') are ignored, so disabling a
server in the source disables it here too. IPv6/AAAA is intentionally skipped:
the monitor checks A records only.

Replace / edit the source file in tool/ to change the monitored server set;
the next run picks up added, removed or commented-out IPs automatically.

Usage:
    extract-servers.py [path-to-source]
If no path is given, every file under tool/ is scanned.
Exit codes: 0 ok (>=1 IP found); 3 no IPs found; 4 no source file.
"""

import glob
import os
import re
import sys

IPV4_RE = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}$")
ADDR_RE = re.compile(r"address_data:\s*([0-9a-fA-F:.]+)")


def source_files() -> list[str]:
    if len(sys.argv) > 1:
        return [sys.argv[1]] if os.path.isfile(sys.argv[1]) else []
    here = os.path.dirname(os.path.abspath(__file__))
    tool_dir = os.path.join(here, "tool")
    return sorted(f for f in glob.glob(os.path.join(tool_dir, "*")) if os.path.isfile(f))


def extract_ips(path: str) -> list[str]:
    out: list[str] = []
    with open(path, encoding="utf-8", errors="ignore") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):   # skip blanks and commented servers
                continue
            m = ADDR_RE.search(line)
            if m and IPV4_RE.match(m.group(1)):     # A records only
                out.append(m.group(1))
    return out


def main() -> int:
    files = source_files()
    if not files:
        print("no source file found under tool/", file=sys.stderr)
        return 4
    seen: set[str] = set()
    ips: list[str] = []
    for path in files:
        for ip in extract_ips(path):
            if ip not in seen:
                seen.add(ip)
                ips.append(ip)
    if not ips:
        print("no IPv4 resolver addresses found", file=sys.stderr)
        return 3
    print("\n".join(ips))
    return 0


if __name__ == "__main__":
    sys.exit(main())
