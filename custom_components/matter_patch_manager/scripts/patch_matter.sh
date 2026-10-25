#!/usr/bin/env bash
set -Eeuo pipefail

# Run from Advanced SSH & Web Terminal (Docker access required).
REPO="danielwatter/core"
CONTAINER="homeassistant"
ROOT="/config/core_patches"
BRANCH="fix-matter-invalid-color-mode"
NAME="matter"
FILES=("homeassistant/components/matter/light.py")
MARKERS=()

command -v docker >/dev/null || { echo "ERROR: docker fehlt" >&2; exit 1; }
command -v git >/dev/null || { echo "ERROR: git fehlt" >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl fehlt" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 fehlt" >&2; exit 1; }
docker inspect "$CONTAINER" >/dev/null || { echo "ERROR: Core-Container nicht gefunden" >&2; exit 1; }
mkdir -p "$ROOT/backups" "$ROOT/logs"
LOG="$ROOT/logs/${NAME}-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
printf '\n=== %s | %s ===\n' "$NAME" "$(date -Is)"
VERSION="$(docker exec "$CONTAINER" python3 -c 'import homeassistant.const as c; print(c.__version__)' 2>/dev/null || true)"
echo "Core: ${VERSION:-unbekannt}; Git-Branch: $BRANCH"
[ -n "$VERSION" ] || { echo 'ABBRUCH: Core-Version nicht ermittelbar'; exit 1; }
WORK="$(mktemp -d)"
BACKUP="$ROOT/backups/${NAME}-${VERSION}-$(date +%Y%m%d-%H%M%S)"
COMMITTED=0
restore() {
  local rc=$?
  trap - EXIT
  if [ "$COMMITTED" -eq 0 ] && [ -d "$BACKUP" ]; then
    echo 'Rollback: Originaldateien wiederherstellen ...'
    for file in "${FILES[@]}"; do
      if [ -f "$BACKUP/$file" ]; then
        docker cp "$BACKUP/$file" "$CONTAINER:/usr/src/homeassistant/$file" || echo "WARNUNG: Rollback von $file fehlgeschlagen!"
      fi
    done
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap restore EXIT

# Download compare diff, pinned locally by SHA256 in the log. No whole-file replacement.
URL="https://github.com/$REPO/compare/dev...${BRANCH}.diff"
echo "Lade Diff: $URL"
curl --fail --location --silent --show-error --max-time 45 "$URL" -o "$WORK/full.diff" || { echo 'ABBRUCH: Diff konnte nicht geladen werden'; exit 1; }
[ "$(wc -c < "$WORK/full.diff")" -lt 300000 ] || { echo 'ABBRUCH: Diff unerwartet gross'; exit 1; }
sha256sum "$WORK/full.diff"

# Reject changes to other production files, unexpected diffs, missing marker lines.
python3 - "$WORK/full.diff" "$NAME" "${FILES[@]}" <<'PYVALIDATE'
import pathlib, re, sys
raw=pathlib.Path(sys.argv[1]).read_text()
name=sys.argv[2]
allowed=set(sys.argv[3:])
headers=re.findall(r'^diff --git a/(\S+) b/(\S+)$',raw,re.M)
if not headers or any(a!=b for a,b in headers):
    sys.exit('ABBRUCH: Kein gueltiger Git-Diff')
production={a for a,b in headers if not a.startswith('tests/')}
if production!=allowed:
    sys.exit(f'ABBRUCH: Unerwartete produktive Dateien: {production ^ allowed}')
required={
 'matter': ['falling back to %s based on available attributes','fallback_color_modes'],
 'powerfox': ['class PowerfoxAuthState:', 'timedelta(minutes=5)', 'reset_auth_state', 'ConfigEntryState.LOADED'],
}[name]
for marker in required:
    if marker not in raw:
        sys.exit(f'ABBRUCH: Erwarteter Patch-Inhalt fehlt: {marker}')
print('Diff-Struktur und Patch-Merkmale geprueft.')
PYVALIDATE

# Work on copies, never overwrite original files before complete validation.
for file in "${FILES[@]}"; do
  mkdir -p "$WORK/$(dirname "$file")"
  docker cp "$CONTAINER:/usr/src/homeassistant/$file" "$WORK/$file" || { echo "ABBRUCH: Datei nicht lesbar: $file"; exit 1; }
done

INCLUDES=()
for file in "${FILES[@]}"; do INCLUDES+=("--include=$file"); done
if (cd "$WORK" && git apply --reverse --check "${INCLUDES[@]}" full.diff 2>/dev/null); then
  echo 'Patch ist bereits installiert. Keine Aenderung.'
  COMMITTED=1
  exit 0
fi
if ! (cd "$WORK" && git apply --check "${INCLUDES[@]}" full.diff); then
  echo 'ABBRUCH: Patch passt nicht exakt auf diese Core-Version (oder wurde upstream veraendert).'
  exit 1
fi
(cd "$WORK" && git apply "${INCLUDES[@]}" full.diff)
for file in "${FILES[@]}"; do
  python3 - "$WORK/$file" <<'PYCHECK'
import pathlib,sys
path=pathlib.Path(sys.argv[1]); compile(path.read_bytes(),str(path),'exec')
PYCHECK
done
(cd "$WORK" && git apply --reverse --check "${INCLUDES[@]}" full.diff)
echo 'Preflight erfolgreich: Patch und Python-Syntax geprueft.'

# Backups are retained, including a manifest of the downloaded patch.
mkdir -p "$BACKUP"
cp "$WORK/full.diff" "$BACKUP/source.diff"
for file in "${FILES[@]}"; do
  mkdir -p "$BACKUP/$(dirname "$file")"
  docker cp "$CONTAINER:/usr/src/homeassistant/$file" "$BACKUP/$file"
done

for file in "${FILES[@]}"; do
  docker cp "$WORK/$file" "$CONTAINER:/usr/src/homeassistant/$file"
done

# Read back from container and compare byte-for-byte; compile source in Core Python.
for file in "${FILES[@]}"; do
  mkdir -p "$WORK/verify/$(dirname "$file")"
  docker cp "$CONTAINER:/usr/src/homeassistant/$file" "$WORK/verify/$file"
  cmp "$WORK/$file" "$WORK/verify/$file" || { echo "ABBRUCH: Postcheck mismatch $file"; exit 1; }
  docker exec "$CONTAINER" python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); compile(p.read_bytes(),str(p),"exec")' "/usr/src/homeassistant/$file"
done
(cd "$WORK/verify" && git apply --reverse --check "${INCLUDES[@]}" "$WORK/full.diff")
COMMITTED=1
printf '\nERFOLG: %s installiert und nachgeprueft.\n' "$NAME"
echo "Backup: $BACKUP"
echo 'WICHTIG: Home Assistant Core danach neu starten (nicht Container neu erstellen!).'
