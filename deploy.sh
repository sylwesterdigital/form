#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VENV="$ROOT/.venv"
NO_RELEASE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-release) NO_RELEASE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) echo "Usage: ./deploy.sh [--dry-run] [--no-release]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

log(){ printf '\n==> %s\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ -f "$ROOT/VERSION" ]] || die "VERSION missing"
version="$(tr -d '[:space:]' < "$ROOT/VERSION")"
log "Deploying Form v$version"

if [[ "$DRY_RUN" == 1 ]]; then
  "$ROOT/scripts/verify_package.sh"
  echo "Dry run passed."
  exit 0
fi

# Basic disk-space guard: Playwright Chromium and a venv need room.
avail_kb="$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')"
[[ "${avail_kb:-0}" -ge 1048576 ]] || die "Less than 1 GB free disk space."

need_cmds=(python3 curl rsync unzip zip git flock)
missing=()
for cmd in "${need_cmds[@]}"; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done

if ((${#missing[@]})); then
  if [[ "$(id -u)" != 0 || ! -x "$(command -v apt-get || true)" ]]; then
    die "Missing tools: ${missing[*]}"
  fi
  log "Installing missing system tools"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip curl rsync unzip zip git util-linux ca-certificates
  apt-get install -y gh >/dev/null 2>&1 || true
fi

if ! python3 -m venv --help >/dev/null 2>&1; then
  [[ "$(id -u)" == 0 ]] || die "python3-venv is missing"
  apt-get update && apt-get install -y python3-venv
fi

log "Preparing Python virtualenv"
[[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip wheel
"$VENV/bin/pip" install -r "$ROOT/requirements.txt"

export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$ROOT/.playwright-browsers}"
if [[ "${FORM_INSTALL_PLAYWRIGHT:-1}" == 1 ]]; then
  log "Ensuring Playwright Chromium is installed"
  if [[ "${FORM_INSTALL_PLAYWRIGHT_DEPS:-1}" == 1 && "$(id -u)" == 0 ]]; then
    "$VENV/bin/python" -m playwright install --with-deps chromium
  else
    "$VENV/bin/python" -m playwright install chromium
  fi
fi

mkdir -p "$ROOT/data/uploads" "$ROOT/data/profiles" "$ROOT/data/jobs" "$ROOT/data/browser-profile" "$ROOT/archive" "$ROOT/logs" "$ROOT/release" "$ROOT/.watch-state" "$ROOT/.deploy-backups"
if id www-data >/dev/null 2>&1; then
  chown -R www-data:www-data "$ROOT/data" "$ROOT/logs"
  chmod 0750 "$ROOT/data" "$ROOT/logs"
fi

log "Running verification"
"$ROOT/scripts/verify.sh"

if [[ "$(id -u)" == 0 && -d /run/systemd/system ]]; then
  log "Installing/restarting systemd service"
  if [[ ! -f /etc/default/form ]]; then
    cat > /etc/default/form <<ENV
FORM_DATA_DIR=$ROOT/data
FORM_AI_PROVIDER=ollama
OLLAMA_URL=http://127.0.0.1:11434
OLLAMA_MODEL=qwen2.5:7b
OPENAI_MODEL=gpt-5.6-luna
FORM_BROWSER=chromium
FORM_HEADLESS=1
FORM_BROWSER_PROFILE_DIR=$ROOT/data/browser-profile
PLAYWRIGHT_BROWSERS_PATH=$ROOT/.playwright-browsers
FORM_AUTO_ADVANCE=0
AUTO_GIT_RELEASE=1
STRICT_RELEASE=0
GH_REPO=sylwesterdigital/form
RELEASE_BRANCH=main
FORM_WATCH_DIR=$ROOT/archive
FORM_DEST_DIR=$ROOT
FORM_ZIP_PATTERN=form-v*.zip
ENV
    chmod 0640 /etc/default/form
  fi
  install -m 0644 "$ROOT/systemd/form.service" /etc/systemd/system/form.service
  systemctl daemon-reload
  systemctl enable form.service >/dev/null
  systemctl restart form.service

  log "Waiting for health endpoint"
  ok=0
  for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:5099/health >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done
  [[ "$ok" == 1 ]] || { systemctl --no-pager --full status form.service || true; journalctl -u form.service -n 80 --no-pager || true; die "Health check failed"; }
else
  log "systemd not available/root; deployment verification completed without service restart"
fi

if [[ "$NO_RELEASE" == 0 && "${AUTO_GIT_RELEASE:-1}" == 1 ]]; then
  log "Publishing Git/GitHub release when credentials are available"
  "$ROOT/scripts/release.sh"
fi

echo
echo "Form v$version deployment completed successfully."
