#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$ROOT/.venv"
PY="$VENV/bin/python"

"$ROOT/scripts/verify_package.sh"
[[ -x "$PY" ]] || { echo "Virtualenv missing: $VENV" >&2; exit 1; }

"$PY" -m compileall -q "$ROOT/formapp" "$ROOT/app.py" "$ROOT/wsgi.py"
"$PY" -m pytest -q "$ROOT/tests"

FORM_DATA_DIR="$(mktemp -d /tmp/form-health.XXXXXX)" "$PY" - <<'PY'
from formapp import create_app
app = create_app({"TESTING": True})
client = app.test_client()
r = client.get('/health')
assert r.status_code == 200 and r.get_json().get('ok') is True
print('Flask health route passed')
PY

echo "All verification checks passed."
