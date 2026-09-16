from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

from .automation import run_autofill


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python -m formapp.worker JOB_JSON", flush=True)
        return 2

    job_path = Path(sys.argv[1]).resolve()
    config = json.loads(job_path.read_text(encoding="utf-8"))
    job_dir = Path(config["job_dir"]).resolve()
    status_path = job_dir / "status.json"

    def status(state: str, message: str, **extra):
        payload = {"state": state, "message": message, **extra, "updated_at": int(time.time())}
        tmp = status_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        tmp.replace(status_path)

    def log(message: str):
        print(message, flush=True)
        status("running", message)

    context = None
    try:
        status("running", "Starting Playwright")
        with sync_playwright() as playwright:
            page, context = run_autofill(playwright, config, log)
            screenshot = job_dir / "review.png"
            try:
                page.screenshot(path=str(screenshot), full_page=True)
            except Exception as exc:
                print(f"Screenshot failed: {exc}", flush=True)

            status(
                "review",
                "Autofill finished. Review the browser/form manually; final submission is never automatic.",
                screenshot=str(screenshot) if screenshot.exists() else "",
            )

            if not bool(config.get("headless", True)):
                hold = int(os.getenv("FORM_REVIEW_HOLD_SECONDS", "1800"))
                deadline = time.time() + max(0, hold)
                print(f"Keeping headed browser open for review for up to {hold} seconds.", flush=True)
                while time.time() < deadline:
                    try:
                        if page.is_closed():
                            break
                        time.sleep(1)
                    except Exception:
                        break
            context.close()
        return 0
    except Exception as exc:
        print(f"ERROR: {type(exc).__name__}: {exc}", flush=True)
        status("failed", f"{type(exc).__name__}: {exc}")
        try:
            if context:
                context.close()
        except Exception:
            pass
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
