#!/usr/bin/env bash
# Read-only check for the existing Matter Core patch.
# Run in Advanced SSH & Web Terminal with Docker access.
set -Eeuo pipefail

REPO="danielwatter/core"
BRANCH="fix-matter-invalid-color-mode"
CONTAINER="homeassistant"
FILE="homeassistant/components/matter/light.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status() {
  printf '{"status":"%s","detail":"%s"}\n' "$1" "$2"
}
fail() { status error "$1"; exit 3; }

for cmd in docker git curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || fail "missing_$cmd"
done
docker inspect "$CONTAINER" >/dev/null 2>&1 || fail "core_container_unavailable"
docker exec "$CONTAINER" true >/dev/null 2>&1 || fail "core_not_running"

URL="https://github.com/$REPO/compare/dev...$BRANCH.diff"
curl --fail --location --silent --show-error --max-time 45 "$URL" -o "$WORK/full.diff" 2>/dev/null || fail "diff_download_failed"
[ "$(wc -c < "$WORK/full.diff")" -lt 300000 ] || fail "diff_too_large"

python3 - "$WORK/full.diff" "$FILE" <<'PY' || fail "unexpected_diff"
import pathlib, re, sys
raw = pathlib.Path(sys.argv[1]).read_text()
allowed = sys.argv[2]
headers = re.findall(r'^diff --git a/(\S+) b/(\S+)$', raw, re.M)
if not headers or any(a != b for a, b in headers):
    sys.exit(1)
production = {a for a, _ in headers if not a.startswith("tests/")}
if production != {allowed}:
    sys.exit(1)
if not all(marker in raw for marker in (
    "falling back to %s based on available attributes",
    "fallback_color_modes",
)):
    sys.exit(1)
PY

mkdir -p "$WORK/$(dirname "$FILE")"
docker cp "$CONTAINER:/usr/src/homeassistant/$FILE" "$WORK/$FILE" >/dev/null 2>&1 || fail "core_file_unreadable"

if (cd "$WORK" && git apply --reverse --check "--include=$FILE" full.diff >/dev/null 2>&1); then
  status installed "patch_present"
  exit 0
fi
if (cd "$WORK" && git apply --check "--include=$FILE" full.diff >/dev/null 2>&1); then
  (cd "$WORK" && git apply "--include=$FILE" full.diff >/dev/null 2>&1) || fail "preflight_apply_failed"
  python3 - "$WORK/$FILE" <<'PY' || fail "patched_python_invalid"
import pathlib, sys
p = pathlib.Path(sys.argv[1])
compile(p.read_bytes(), str(p), "exec")
PY
  status available "patch_applicable"
  exit 0
fi
status incompatible "patch_does_not_match_core"
exit 2
