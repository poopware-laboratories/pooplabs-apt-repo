#!/usr/bin/env python3
"""Render the landing page from a Packages index and an HTML template."""
import argparse
import html
import re
from pathlib import Path
from urllib.parse import quote


def parse_packages(text):
    stanzas = []
    for block in re.split(r"\n\s*\n", text.strip()):
        fields, last = {}, None
        for line in block.splitlines():
            if line[:1] in (" ", "\t") and last:
                fields[last] += "\n" + line.strip()
            elif ":" in line:
                last, value = line.split(":", 1)
                fields[last] = value.strip()
        if "Package" in fields:
            stanzas.append(fields)
    return sorted(stanzas, key=lambda s: (s.get("Name", s["Package"]).lower(), s["Version"]))


def package_rows(stanzas):
    rows = []
    for s in stanzas:
        e = lambda key: html.escape(s.get(key, ""))
        description = html.escape(s.get("Description", "").split("\n")[0])
        rows.append(
            "<tr>"
            f"<td><strong>{html.escape(s.get('Name', s['Package']))}</strong><br><code>{e('Package')}</code></td>"
            f"<td>{description}</td>"
            f"<td>{e('Version')}</td>"
            f"<td>{e('Architecture')}</td>"
            f"<td><a href=\"{html.escape(s.get('Filename', ''))}\">.deb</a></td>"
            "</tr>"
        )
    return "\n".join(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--packages", required=True)
    ap.add_argument("--template", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--signed", default="0")
    args = ap.parse_args()

    url = args.url.rstrip("/") + "/"
    signed = args.signed == "1"
    stanzas = parse_packages(Path(args.packages).read_text(encoding="utf-8"))
    base = url.rstrip("/")

    if signed:
        apt_setup = (
            "sudo install -d -m 0755 /etc/apt/keyrings\n"
            f"sudo curl -fsSL {url}pooplabs.gpg -o /etc/apt/keyrings/pooplabs.gpg\n"
            f"echo 'deb [signed-by=/etc/apt/keyrings/pooplabs.gpg] {url} ./' | sudo tee /etc/apt/sources.list.d/pooplabs.list\n"
            "sudo apt update"
        )
        trust_note = "The repository is signed. APT verifies every update against the key above."
    else:
        apt_setup = (
            f"echo 'deb [trusted=yes] {url} ./' | sudo tee /etc/apt/sources.list.d/pooplabs.list\n"
            "sudo apt update"
        )
        trust_note = (
            "This repository is currently <strong>unsigned</strong>. "
            "<code>trusted=yes</code> makes APT skip signature checks, so only use it if you trust Poop Labs."
        )

    mapping = {
        "URL": html.escape(url),
        "CYDIA_LINK": html.escape(f"cydia://url/https://cydia.saurik.com/api/share#?source={quote(url, safe='')}"),
        "SILEO_LINK": html.escape(f"sileo://source/{url}"),
        "ZEBRA_LINK": html.escape(f"zebra://sources/add/{url}"),
        "APT_SETUP": html.escape(apt_setup),
        "TRUST_NOTE": trust_note,
        "PACKAGE_ROWS": package_rows(stanzas),
    }
    page = Path(args.template).read_text(encoding="utf-8")
    page = re.sub(r"\{\{(\w+)\}\}", lambda m: mapping[m.group(1)], page)
    print(page, end="")


if __name__ == "__main__":
    main()
