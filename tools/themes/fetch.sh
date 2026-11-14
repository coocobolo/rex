#!/bin/sh
# Fetches and verifies curated Ghostty-format color schemes and license metadata
# from pinned mbadolato/iTerm2-Color-Schemes into tools/themes/schemes.conf and
# THIRD_PARTY_NOTICES/iterm2-color-schemes.txt.
#
#   tools/themes/fetch.sh             # refresh at tools/themes/REVISION
#   tools/themes/fetch.sh <commit>    # pin <commit> (40-hex SHA) and refresh
#   tools/themes/fetch.sh --check     # verify local files match upstream
#
# After updating tools/themes/schemes.conf, run:
#   zig build gen-themes && zig build check-themes
set -eu

dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
rev_file="$dir/REVISION"
manifest_file="$dir/manifest.conf"
schemes_file="$dir/schemes.conf"
notice_file="$root/THIRD_PARTY_NOTICES/iterm2-color-schemes.txt"
apache_file="$root/THIRD_PARTY_NOTICES/Apache-2.0.txt"

mode="update"
target_rev=""
case "${1:-}" in
    "")
        target_rev=$(tr -d ' \t\r\n' < "$rev_file")
        ;;
    --check)
        mode="check"
        target_rev=$(tr -d ' \t\r\n' < "$rev_file")
        ;;
    -h|--help)
        sed -n '2,12p' "$0"
        exit 0
        ;;
    *)
        target_rev=$1
        ;;
esac

exec python3 - "$mode" "$target_rev" "$rev_file" "$manifest_file" "$schemes_file" "$notice_file" "$apache_file" <<'PY'
from concurrent.futures import ThreadPoolExecutor
import difflib
import os
import re
import subprocess
import sys
import urllib.parse

mode, commit, rev_file, manifest_file, schemes_file, notice_file, apache_file = sys.argv[1:8]

UPSTREAM_REPO = "https://github.com/mbadolato/iTerm2-Color-Schemes"
RAW_BASE = f"https://raw.githubusercontent.com/mbadolato/iTerm2-Color-Schemes/{commit}"
APACHE_URL = "https://raw.githubusercontent.com/spdx/license-list-data/v3.25.0/text/Apache-2.0.txt"
ALLOWED_LICENSES = ("MIT", "Apache-2.0")

if not re.fullmatch(r"[0-9a-f]{40}", commit):
    sys.exit(f"fetch.sh: commit must be a 40-char lowercase hex SHA, got {commit!r}")


def curl_get(url: str) -> str:
    res = subprocess.run(
        ["curl", "-fsSL", "--connect-timeout", "15", "--max-time", "60", url],
        capture_output=True,
        text=True,
        check=False,
    )
    if res.returncode != 0:
        sys.exit(f"fetch.sh: failed to fetch {url}: {res.stderr.strip()}")
    return res.stdout


def parse_manifest(path: str):
    entries = []
    seen_slugs = set()
    seen_upstream = set()
    with open(path, "r", encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) != 4 or any(not p for p in parts):
                sys.exit(f"{path}:{lineno}: expected '<slug> | <dark|light> | <Upstream Name> | <Copyright>'")
            slug, variant, upstream, copyright_holder = parts
            if not re.fullmatch(r"[a-z][a-z0-9_]*", slug):
                sys.exit(f"{path}:{lineno}: invalid slug {slug!r}")
            if variant not in ("dark", "light"):
                sys.exit(f"{path}:{lineno}: invalid variant {variant!r}")
            if slug in seen_slugs:
                sys.exit(f"{path}:{lineno}: duplicate slug {slug!r}")
            if upstream in seen_upstream:
                sys.exit(f"{path}:{lineno}: duplicate upstream {upstream!r}")
            seen_slugs.add(slug)
            seen_upstream.add(upstream)
            entries.append((slug, variant, upstream, copyright_holder))
    if not entries:
        sys.exit(f"{path}: empty manifest")
    return entries


def parse_licenses_yml(text: str):
    out = {}
    cur = None
    cur_key = None

    def unquote(s: str) -> str:
        s = s.strip()
        if len(s) >= 2 and ((s[0] == "'" and s[-1] == "'") or (s[0] == '"' and s[-1] == '"')):
            return s[1:-1]
        return s

    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw.startswith(" "):
            cur = unquote(raw.rstrip(":"))
            out[cur] = {}
            cur_key = None
        elif raw.startswith("    ") and cur is not None and cur_key is not None:
            # Multiline scalar continuation (e.g. two source URLs).
            prev = out[cur][cur_key]
            joined = f"{prev}, {raw.strip()}"
            out[cur][cur_key] = unquote(joined)
        elif cur is not None and ":" in raw:
            k, v = raw.strip().split(":", 1)
            cur_key = k.strip()
            out[cur][cur_key] = unquote(v)
    for meta in out.values():
        for k, v in list(meta.items()):
            meta[k] = unquote(v)
    return out


def validate_ghostty_lines(upstream: str, text: str):
    lines = []
    slots = set()
    have_bg = False
    have_fg = False
    hex_re = re.compile(r"^#[0-9a-fA-F]{6}$")
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            sys.exit(f"ghostty/{upstream}:{lineno}: missing '=' in {line!r}")
        k, v = [p.strip() for p in line.split("=", 1)]
        if k == "palette":
            if "=" not in v:
                sys.exit(f"ghostty/{upstream}:{lineno}: invalid palette line {line!r}")
            idx_s, col = [p.strip() for p in v.split("=", 1)]
            idx = int(idx_s)
            if not (0 <= idx <= 15) or not hex_re.match(col):
                sys.exit(f"ghostty/{upstream}:{lineno}: invalid palette slot {line!r}")
            slots.add(idx)
            lines.append(f"palette = {idx}={col.lower()}")
        elif k in ("background", "foreground", "cursor-color", "cursor-text", "selection-background", "selection-foreground"):
            if not hex_re.match(v):
                sys.exit(f"ghostty/{upstream}:{lineno}: invalid hex color {line!r}")
            if k == "background":
                have_bg = True
            elif k == "foreground":
                have_fg = True
            lines.append(f"{k} = {v.lower()}")
        else:
            sys.exit(f"ghostty/{upstream}:{lineno}: unknown key {k!r}")
    if len(slots) != 16 or not have_bg or not have_fg:
        sys.exit(f"ghostty/{upstream}: incomplete palette/background/foreground")
    return lines


manifest = parse_manifest(manifest_file)
print(f"fetch.sh: fetching license metadata for {commit[:12]}...", file=sys.stderr)
repo_license_text = curl_get(f"{RAW_BASE}/LICENSE").replace("\r\n", "\n").rstrip("\n")
licenses_yml = parse_licenses_yml(curl_get(f"{RAW_BASE}/licenses.yml"))

# Trim upstream trailing repository boilerplate after the MIT body if separated
# cleanly, or preserve the exact MIT block + note from upstream LICENSE.
schemes_out = [
    "# Curated iTerm2-Color-Schemes (ghostty export format)",
    f"# Upstream: {UPSTREAM_REPO}",
    f"# Commit: {commit}",
    "",
]

pending = []
for slug, variant, upstream, copyright_holder in manifest:
    meta = licenses_yml.get(upstream)
    if meta is None:
        sys.exit(f"fetch.sh: {upstream!r} missing from upstream licenses.yml at {commit}")
    lic = meta.get("license", "")
    if lic not in ALLOWED_LICENSES:
        sys.exit(f"fetch.sh: {upstream!r} has unapproved license {lic!r} (allowed: {', '.join(ALLOWED_LICENSES)})")
    source = meta.get("source", "").strip()
    if not source.startswith("https://"):
        sys.exit(f"fetch.sh: {upstream!r} missing valid https:// source URL in licenses.yml ({source!r})")
    encoded_name = urllib.parse.quote(upstream, safe="")
    pending.append((slug, variant, upstream, lic, copyright_holder, source, f"{RAW_BASE}/ghostty/{encoded_name}"))

with ThreadPoolExecutor(max_workers=8) as pool:
    ghostty_texts = list(pool.map(curl_get, [item[6] for item in pending]))

resolved = []
for (slug, variant, upstream, lic, copyright_holder, source, _), ghostty_raw in zip(pending, ghostty_texts):
    color_lines = validate_ghostty_lines(upstream, ghostty_raw)
    schemes_out.extend([
        f"[{slug}]",
        f"variant = {variant}",
        f"upstream = {upstream}",
        f"license = {lic}",
        f"copyright = {copyright_holder}",
        f"source = {source}",
        *color_lines,
        "",
    ])
    resolved.append((slug, variant, upstream, lic, copyright_holder, source))

schemes_content = "\n".join(schemes_out)

apache_used = any(lic == "Apache-2.0" for _, _, _, lic, _, _ in resolved)

notice_lines = [
    "iTerm2-Color-Schemes (curated permissive subset)",
    "-------------------------------------------------",
    "",
    "This project includes generated theme preset data derived from a curated",
    "subset of schemes in iTerm2-Color-Schemes (Ghostty export files), limited to",
    "schemes whose per-scheme licenses are explicitly verified as MIT or",
    "Apache-2.0 in upstream licenses.yml.",
    "",
    "The generated data is used in: src/color/presets.zig",
    "The input snapshot is: tools/themes/schemes.conf",
    "The curated index is: tools/themes/manifest.conf",
    "",
    "Upstream project:",
    UPSTREAM_REPO,
    "",
    "Upstream revision:",
    commit,
    "",
    "Upstream repository license (collection scripts & exports)",
    "----------------------------------------------------------",
    repo_license_text,
    "",
]
if apache_used:
    notice_lines.extend([
        "Apache-2.0 License text",
        "-----------------------",
        "Schemes marked Apache-2.0 below are distributed under the Apache License,",
        "Version 2.0 (full text included in THIRD_PARTY_NOTICES/Apache-2.0.txt).",
        "",
    ])

notice_lines.extend([
    "Included schemes and individual licenses",
    "----------------------------------------",
])
for _, _, upstream, lic, copyright_holder, source in resolved:
    notice_lines.append(f"- {upstream} [{lic}] - {copyright_holder} ({source})")
notice_content = "\n".join(notice_lines) + "\n"

apache_content = None
if apache_used:
    apache_content = curl_get(APACHE_URL).replace("\r\n", "\n")
    if "Apache License" not in apache_content or "Version 2.0, January 2004" not in apache_content:
        sys.exit(f"fetch.sh: unexpected license body from {APACHE_URL}")


def check_or_write(path: str, expected: str):
    existing = None
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            existing = f.read()
    if mode == "check":
        if existing != expected:
            diff = "".join(difflib.unified_diff(
                (existing or "").splitlines(keepends=True),
                expected.splitlines(keepends=True),
                fromfile=f"{path} (local)",
                tofile=f"{path} (upstream {commit[:12]})",
            ))
            sys.stderr.write(diff)
            return False
        return True
    if existing != expected:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(expected)
        print(f"fetch.sh: wrote {path}")
    return True


if mode == "check":
    ok = True
    ok &= check_or_write(rev_file, commit + "\n")
    ok &= check_or_write(schemes_file, schemes_content)
    ok &= check_or_write(notice_file, notice_content)
    if apache_content is not None:
        ok &= check_or_write(apache_file, apache_content)
    if not ok:
        sys.exit("fetch.sh: upstream check failed (run tools/themes/fetch.sh to sync)")
    print(f"fetch.sh: verified {len(resolved)} curated schemes against {commit[:12]}")
else:
    check_or_write(rev_file, commit + "\n")
    check_or_write(schemes_file, schemes_content)
    check_or_write(notice_file, notice_content)
    if apache_content is not None:
        check_or_write(apache_file, apache_content)
    print(f"fetch.sh: synced {len(resolved)} curated schemes at {commit[:12]}")
PY
