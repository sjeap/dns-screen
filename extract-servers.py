#!/usr/bin/env python3
"""
extract-servers.py — Single source of truth for the monitored DNS server IPs.

Reads the dnscheck.tools snapshot in tool/*.mhtml, decodes the quoted-printable
HTML part, and emits the IPv4 addresses (A records) of the *detected DNS
resolvers* — one per line, in document order, de-duplicated.

Scope is strictly limited to the `resolver-results` section so the operator's
own client IP (the "Your IP addresses" section) is never emitted. IPv6/AAAA
addresses are intentionally ignored: the monitor checks A records only.

Replace the .mhtml in tool/ to change the monitored server set; the next run
picks up added/removed/changed IPs automatically.

Usage:
    extract-servers.py [path-to.mhtml]
If no path is given, the newest *.mhtml under tool/ is used.
Exit codes: 0 ok (>=1 IP found); 3 no IPs found; 4 no mhtml file.
"""

import glob
import os
import quopri
import re
import sys

IPV4_RE = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}$")


def find_mhtml() -> str | None:
    if len(sys.argv) > 1:
        return sys.argv[1] if os.path.isfile(sys.argv[1]) else None
    here = os.path.dirname(os.path.abspath(__file__))
    tool_dir = os.path.join(here, "tool")
    candidates = sorted(
        glob.glob(os.path.join(tool_dir, "*.mhtml")),
        key=os.path.getmtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


def decode_html(mhtml_path: str) -> str:
    raw = open(mhtml_path, "rb").read().decode("latin-1")
    marker = "Content-Transfer-Encoding: quoted-printable"
    idx = raw.find(marker)
    if idx == -1:
        # not encoded / different structure: treat whole file as html
        body = raw
    else:
        body = raw[idx:].split("\r\n\r\n", 1)[1]
        body = re.split(r"----+MultipartBoundary", body)[0]
    return quopri.decodestring(body.encode("latin-1")).decode("utf-8", "replace")


def extract_ips(html: str) -> list[str]:
    # Scope strictly to the resolver-results section.
    start = html.find('id="resolver-results"')
    if start == -1:
        raise SystemExit("resolver-results section not found — snapshot format changed?")
    # End at the next section (DNSSEC) or the security heading.
    rest = html[start:]
    for stop_anchor in ('id="dnssec', "Your DNS security", '<div class="section"'):
        pos = rest.find(stop_anchor, len('id="resolver-results"'))
        if pos != -1:
            rest = rest[:pos]
            break
    # IPs appear as info.addr.tools/<IP> links; also accept bare anchors.
    ips = re.findall(r"info\.addr\.tools/([0-9a-fA-F:.]+)", rest)
    seen: set[str] = set()
    out: list[str] = []
    for ip in ips:
        if IPV4_RE.match(ip) and ip not in seen:  # A records only
            seen.add(ip)
            out.append(ip)
    return out


def main() -> int:
    mhtml = find_mhtml()
    if not mhtml:
        print("no *.mhtml found under tool/", file=sys.stderr)
        return 4
    ips = extract_ips(decode_html(mhtml))
    if not ips:
        print("no IPv4 resolver addresses found", file=sys.stderr)
        return 3
    print("\n".join(ips))
    return 0


if __name__ == "__main__":
    sys.exit(main())
