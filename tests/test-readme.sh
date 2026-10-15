#!/bin/bash
# Tier: static (it runs the command's read-only subcommands: status, current, stats, help). Checks that the README,
# DEVELOPING.md (the developer page) and the man page tell the truth about the code: documented subcommands exist,
# documented paths are real or shipped, the numbers in the profile tables match the curve files, every test script is
# listed on DEVELOPING.md, links resolve, and the README links to DEVELOPING.md.
# Works on any branch of this repo (it uses whichever command name the checkout has).
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[ -n "$CLI" ] || suite_skip "no command found in bin/"
command -v python3 >/dev/null || suite_skip "python3 is not installed"

while IFS= read -r line; do
  case "$line" in
    "PASS "*) ok "${line#PASS }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    "SKIP "*) skip "${line#SKIP }" ;;
    "INFO "*) info "${line#INFO }" ;;
  esac
done < <(python3 - "$ROOT" "$CLI" <<'PY'
import glob, json, os, re, subprocess, sys

root, cli = sys.argv[1], sys.argv[2]
cmd = os.path.basename(cli)
read = lambda p: open(os.path.join(root, p)).read() if os.path.exists(os.path.join(root, p)) else None
out = lambda kind, msg: print(f"{kind} {msg}")
readme, cli_src = read("README.md"), open(cli).read()
developing = read("DEVELOPING.md") or ""   # the developer page: the test suite and contributing
docs = readme + "\n" + developing          # both sit in the repo root, so their links and paths resolve the same way
manpage = read(f"man/{cmd}.1")
pkgbuild, helper, installer = read("packaging/PKGBUILD") or "", read("helper/omarchy-fan-helper") or "", read("install-helper.sh") or ""
manifest = json.loads(read("manifest.json"))

# ---- 1. documented subcommands exist in the command
labels = set()
for m in re.finditer(r"^  ([a-z|\-]+)\)", cli_src, re.M):
    labels.update(w for w in m.group(1).split("|") if w)
documented = set()
for m in re.finditer(r"\b(?:omarchyfan|omarchy-fan)[ \t]+([a-z|]+)", docs):
    documented.update(w for w in m.group(1).split("|") if w)
for w in sorted(documented):
    out("PASS" if w in labels else "FAIL", f"README documents '{cmd} {w}' and the command {'has' if w in labels else 'has NO'} such a subcommand")
undocumented = sorted(w for w in labels if not w.startswith("-") and w not in documented)
if undocumented:
    out("INFO", f"subcommands the README does not mention (the man page may): {', '.join(undocumented)}")

# ---- 2. the read-only documented subcommands really run
for w in ("status", "current", "stats", "help"):
    if w in documented:
        try:
            r = subprocess.run([cli, w], capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
            good = r.returncode == 0 and (r.stdout.strip() or r.stderr.strip())
        except Exception as e:
            good = False
        out("PASS" if good else "FAIL", f"'{cmd} {w}' runs, exits 0 and prints something")

# ---- 3. man page documents every subcommand
if manpage:
    for w in sorted(l for l in labels if not l.startswith("-")):
        out("PASS" if re.search(rf"\.B {w}\b|\.BI? {w}\b", manpage) else "FAIL", f"the man page documents the '{w}' subcommand")
else:
    out("SKIP", f"no man page (man/{cmd}.1) in this checkout")

# ---- 4. system paths named in the README are real: shipped by the package/helper or made by the installer
sources = pkgbuild + helper + installer
seen = set()
for tok in re.findall(r"`(/(?:usr|etc)/[^`\s]+)`", docs):
    prefix = re.split(r"[*{]", tok)[0].rstrip(".,;:")
    if prefix in seen:
        continue
    seen.add(prefix)
    out("PASS" if prefix in sources else "FAIL", f"README path {tok} is shipped or written by the package/helper")

# ---- 5. paths inside the repo named in the README exist; markdown links resolve; tests are all documented
def brace(p):
    m = re.search(r"\{([^{}]*)\}", p)
    if not m:
        return [p]
    return [x for alt in m.group(1).split(",") for x in brace(p[:m.start()] + alt + p[m.end():])]
repo_tokens = set(re.findall(r"`((?:bin|man|profiles|tests|packaging|helper|docs)/[A-Za-z0-9_./*{},-]+)`", docs))
repo_tokens |= {f for f in ("install-helper.sh", "LICENSE", "preview.png", "Panel.qml", "manifest.json") if f"`{f}`" in docs}
for tok in sorted(repo_tokens):
    hits = [h for p in brace(tok) for h in glob.glob(os.path.join(root, p))]
    out("PASS" if hits else "FAIL", f"README names {tok}, which {'exists' if hits else 'does NOT exist'} in the repo")
links = set(re.findall(r"\]\(([^)#\s]+)(?:#[^)]*)?\)", docs)) | set(re.findall(r"<img[^>]*\ssrc=\"([^\"]+)\"", docs))
for link in sorted(links):
    if link.startswith(("http://", "https://", "mailto:")):
        continue
    out("PASS" if os.path.exists(os.path.join(root, link)) else "FAIL", f"README link ({link}) resolves")
tests_dir = sorted(os.path.basename(p) for p in glob.glob(os.path.join(root, "tests", "*.sh")) if not p.endswith("lib.sh"))
for name in tests_dir:
    out("PASS" if name in developing else "FAIL", f"DEVELOPING.md lists tests/{name}")
for name in sorted(set(re.findall(r"tests/([\w.-]+\.sh)", docs))):
    out("PASS" if os.path.exists(os.path.join(root, "tests", name)) else "FAIL", f"the docs name tests/{name}, which exists")
out("PASS" if developing else "FAIL", "DEVELOPING.md (the developer page) is in the repo root")
out("PASS" if "](DEVELOPING.md)" in readme.split("\n## ", 1)[0] else "FAIL", "the README links to DEVELOPING.md before its first section")

# ---- 6. the numbers in the profile tables match the curve files
def curve(name):
    rows = [(int(a), int(b), int(c)) for a, b, c in re.findall(r"\[(\d+),\s*(\d+),\s*(\d+)\]", read(f"profiles/{name}.yaml"))]
    off_until = next((up for lvl, lo, up in rows if lvl == 0), None)
    full_above = max(rows, key=lambda r: r[0])[2]
    return ([off_until] if off_until is not None else []) + [full_above]
for name in ("quiet", "balanced", "performance"):
    want = curve(name)
    row = re.search(rf"^\|\s*{name}\s*\|(.*)$", readme, re.I | re.M)
    if row:
        got = [int(x) for x in re.findall(r"about (\d+)", row.group(1))]
        out("PASS" if got == want else "FAIL", f"README profile table for {name} says {got}; profiles/{name}.yaml gives {want}")
    else:
        out("SKIP", f"README has no profile table row for {name}")
    if manpage:
        profiles_sec = re.search(r"\.SH PROFILES(.*?)(?=\n\.SH )", manpage, re.S)
        block = re.search(rf"\.B {name}\n([^\n]+)", profiles_sec.group(1)) if profiles_sec else None
        got = [int(x) for x in re.findall(r"about (\d+)", block.group(1))] if block else None
        out("PASS" if got == want else "FAIL", f"man page PROFILES for {name} says {got}; profiles/{name}.yaml gives {want}")

# ---- 7. consistency: one plugin id, one repository URL
ids = set(re.findall(r"io\.github\.[A-Za-z0-9._-]*[A-Za-z0-9]", readme + (manpage or "").replace("\\-", "-")))   # man source writes a hyphen as \\-
m = re.search(r"^## What's new in (\d+\.\d+\.\d+)", readme, re.M)
out("PASS" if m and m.group(1) == manifest["version"] else "FAIL", f"the README's \"What's new in {m.group(1) if m else 'none'}\" matches the manifest version ({manifest['version']})")
out("PASS" if ids <= {manifest["id"]} else "FAIL", f"every plugin id in the README and man page is the manifest id ({manifest['id']}); found {sorted(ids) or 'none'}")
url = re.search(r'^url="([^"]+)"', pkgbuild, re.M)
add = re.findall(r"omarchy plugin add (https://\S+?)(?:\.git)?(?:\s|$)", readme)
if url and add:
    out("PASS" if all(a == url.group(1) for a in add) else "FAIL", f"the README's plugin add URL matches the PKGBUILD url ({url.group(1)})")
PY
)
finish
