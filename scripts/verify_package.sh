#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

required=(
  VERSION requirements.txt app.py wsgi.py deploy.sh bootstrap.sh README.md LICENSE
  formapp/__init__.py formapp/automation.py formapp/cv.py formapp/llm.py formapp/profile.py formapp/worker.py
  templates/index.html static/app.css static/app.js
  scripts/verify.sh scripts/form-watch.sh scripts/install_watcher.sh scripts/package_release.sh scripts/release.sh
  systemd/form.service systemd/form-watch.service nginx/form.conf.example
)

for path in "${required[@]}"; do
  [[ -e "$ROOT/$path" ]] || { echo "Missing required package file: $path" >&2; exit 1; }
done

for script in "$ROOT/deploy.sh" "$ROOT/bootstrap.sh" "$ROOT"/scripts/*.sh; do
  [[ -x "$script" ]] || { echo "Script is not executable: $script" >&2; exit 1; }
  bash -n "$script"
done

python3 -m compileall -q "$ROOT/formapp" "$ROOT/app.py" "$ROOT/wsgi.py"

if grep -RIE \
  --exclude='*.md' \
  --exclude='.env' --exclude='.env.*' \
  --exclude='verify_package.sh' \
  --exclude-dir='.git' --exclude-dir='.venv' --exclude-dir='data' \
  --exclude-dir='archive' --exclude-dir='release' --exclude-dir='.playwright-browsers' \
  '(sk-[A-Za-z0-9_-]{20,}|OPENAI_API_KEY=[^[:space:]]+)' "$ROOT" >/dev/null 2>&1; then
  echo "Source appears to contain a hard-coded API key." >&2
  exit 1
fi

echo "Package verification passed: v$(tr -d '[:space:]' < "$ROOT/VERSION")"
