# Form

Open-source CV-to-application autofill tool built with Flask + Playwright.

The project turns a CV into reusable structured JSON, opens an application form,
fills repetitive fields, and deliberately stops before sensitive voluntary
disclosures or final submission so a human can review the result.

## Stack

- Flask web UI
- Playwright browser automation
- Ollama for local CV parsing (default)
- Optional OpenAI Responses API provider
- PDF/DOCX/TXT extraction
- Gunicorn + systemd for Linux deployment
- ZIP watcher with package verification, backup/rollback, deploy, smoke test and optional GitHub release

## Quick local start

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m playwright install chromium
cp .env.example .env
# Edit FORM_DATA_DIR and FORM_BROWSER_PROFILE_DIR for your workstation.
python app.py
```

Open `http://127.0.0.1:5099`.

For interactive browser review on a workstation set:

```bash
FORM_HEADLESS=0
```

The browser profile is isolated under `FORM_BROWSER_PROFILE_DIR`. Sign into a
recruitment site once in that profile and it can be reused by later runs.
Do not point Playwright at a Chrome/Brave profile that is simultaneously open in
another browser process.

## Server deployment

Target used by the supplied scripts:

```text
/var/www/mojoworks/labs/form
```

The Flask service binds to `127.0.0.1:5099`. Put Nginx in front of it. A sample
location block is included in `nginx/form.conf.example`.

First deployment:

```bash
cd /tmp
unzip form-v0.1.0.zip
cd form
sudo ./bootstrap.sh
```

`bootstrap.sh` copies the package to `/var/www/mojoworks/labs/form`, installs
Python/system dependencies, Playwright Chromium, the Flask systemd service and
the ZIP watcher systemd service.

After that, future releases only need to be copied into:

```text
/var/www/mojoworks/labs/form/archive/
```

The watcher looks for `form-v*.zip`, waits for the file to stop changing,
verifies the package, backs up the current source, synchronises the new version,
runs the deployment/tests, restarts the service, checks `/health`, and restores
the previous version if deployment fails.

Watch logs:

```bash
journalctl -u form-watch -f
journalctl -u form -f
```

## GitHub release automation

The deploy script can commit the synchronized release to the existing Git
checkout, tag `v<VERSION>`, push the branch/tag, and create a GitHub release if
`gh` is installed and authenticated.

Configure `/etc/default/form`:

```bash
AUTO_GIT_RELEASE=1
STRICT_RELEASE=0
GH_REPO=sylwesterdigital/form
RELEASE_BRANCH=main
```

For push/release to work, the server needs authorized Git SSH credentials and,
for the GitHub release asset, authenticate `gh` (`gh auth login`) or set `GH_TOKEN` in `/etc/default/form`.

`STRICT_RELEASE=0` means a GitHub publishing problem does not take the running
application down. Set it to `1` if publishing is required for deployment success.

## Browser automation scope

v0.1.0 focuses on the tedious, repeatable parts of Workday-style forms:

- personal contact fields
- resume upload when a file input is visible
- repeated work-experience entries
- repeated education entries
- dates, descriptions and current-role checkbox

It intentionally does not infer or answer voluntary demographic/disclosure
questions and never clicks the final Submit button.

Workday changes its DOM frequently. The automation uses accessible labels first
and falls back to common field names, so site-specific adapters can be added
under `formapp/automation.py` over time.

## Security

This application processes CVs containing personal data. By default the service
binds to localhost. If you expose the UI through Nginx, protect it with
authentication and TLS. Never commit `.env`, uploaded CVs, browser profiles,
API keys or cookies.

## Tests

```bash
./scripts/verify.sh
```

## Packaging a new release

Update `VERSION`, then:

```bash
./scripts/package_release.sh
```

The ZIP is written to `release/form-v<VERSION>.zip`.
