from __future__ import annotations

import os
import re
import shutil
import sys
import time
from pathlib import Path
from typing import Callable

from playwright.sync_api import Locator, Page, Playwright, TimeoutError as PlaywrightTimeoutError

Log = Callable[[str], None]


def _executable_for(browser: str) -> str | None:
    browser = browser.lower()
    candidates: list[str] = []
    if browser == "brave":
        if sys.platform == "darwin":
            candidates += ["/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"]
        candidates += ["/usr/bin/brave-browser", "/usr/bin/brave", "/snap/bin/brave"]
    elif browser in {"chrome", "google-chrome"}:
        if sys.platform == "darwin":
            candidates += ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]
        candidates += ["/usr/bin/google-chrome", "/usr/bin/google-chrome-stable"]
    for candidate in candidates:
        if Path(candidate).exists():
            return candidate
    return shutil.which(browser)


def _visible(locator: Locator, index: int = 0) -> Locator | None:
    try:
        if locator.count() <= index:
            return None
        target = locator.nth(index)
        if not target.is_visible():
            return None
        return target
    except Exception:
        return None


def _label_locator(page: Page, patterns: list[str]) -> Locator | None:
    for pattern in patterns:
        target = _visible(page.get_by_label(re.compile(pattern, re.I)))
        if target:
            return target
    return None


def _all_label(page: Page, patterns: list[str]) -> Locator | None:
    for pattern in patterns:
        locator = page.get_by_label(re.compile(pattern, re.I))
        try:
            if locator.count():
                return locator
        except Exception:
            pass
    return None


def _fill_one(page: Page, patterns: list[str], value: str, log: Log, index: int = 0) -> bool:
    if not value:
        return False
    locator = _all_label(page, patterns)
    if not locator:
        return False
    try:
        if locator.count() <= index:
            return False
        field = locator.nth(index)
        if not field.is_visible():
            return False
        existing = field.input_value(timeout=1000)
        if existing.strip() == value.strip():
            return True
        field.fill(value)
        log(f"Filled {patterns[0]} [{index + 1}]")
        return True
    except Exception as exc:
        log(f"Skipped {patterns[0]} [{index + 1}]: {exc}")
        return False


def _check_one(page: Page, patterns: list[str], checked: bool, log: Log, index: int = 0) -> bool:
    locator = _all_label(page, patterns)
    if not locator:
        return False
    try:
        if locator.count() <= index:
            return False
        field = locator.nth(index)
        if not field.is_visible():
            return False
        if checked:
            field.check(force=True)
        else:
            field.uncheck(force=True)
        log(f"Set {patterns[0]} [{index + 1}] = {checked}")
        return True
    except Exception:
        return False


def _click_add_another(page: Page, section_text: str, log: Log) -> bool:
    # Workday commonly renders a section heading followed by an Add Another button.
    # Start with exact accessible button matches and use nearby section context only
    # as a fallback.
    candidates = page.get_by_role("button", name=re.compile(r"Add Another|Add", re.I))
    try:
        count = candidates.count()
    except Exception:
        return False

    if count == 1:
        try:
            candidates.first.click()
            page.wait_for_timeout(300)
            log(f"Added another {section_text} entry")
            return True
        except Exception:
            return False

    # Prefer a button whose ancestor text mentions the intended section.
    for i in range(count):
        button = candidates.nth(i)
        try:
            if not button.is_visible():
                continue
            text = button.evaluate("el => el.parentElement?.parentElement?.innerText || ''")
            if section_text.lower() in str(text).lower():
                button.click()
                page.wait_for_timeout(300)
                log(f"Added another {section_text} entry")
                return True
        except Exception:
            continue

    # Common Workday layout: Work Experience Add comes first, Education Add last.
    try:
        fallback = candidates.first if section_text.lower().startswith("work") else candidates.last
        if fallback.is_visible():
            fallback.click()
            page.wait_for_timeout(300)
            log(f"Added another {section_text} entry using fallback")
            return True
    except Exception:
        pass
    return False


def fill_personal(page: Page, profile: dict, log: Log) -> None:
    p = profile.get("personal", {})
    _fill_one(page, [r"^First Name", r"Given Name"], p.get("first_name", ""), log)
    _fill_one(page, [r"^Last Name", r"Family Name", r"Surname"], p.get("last_name", ""), log)
    _fill_one(page, [r"^Email", r"Email Address"], p.get("email", ""), log)
    _fill_one(page, [r"Phone", r"Mobile"], p.get("phone", ""), log)
    _fill_one(page, [r"Address Line 1", r"^Address$"], p.get("address", ""), log)
    _fill_one(page, [r"^City", r"Town"], p.get("city", ""), log)
    _fill_one(page, [r"Postal", r"Postcode", r"ZIP"], p.get("postcode", ""), log)


def fill_resume(page: Page, resume_path: str, log: Log) -> None:
    if not resume_path or not Path(resume_path).exists():
        return
    file_inputs = page.locator('input[type="file"]')
    try:
        count = file_inputs.count()
    except Exception:
        return
    for i in range(count):
        field = file_inputs.nth(i)
        try:
            # Some Workday file inputs are intentionally visually hidden; set_input_files
            # still works on the input without force-clicking UI controls.
            field.set_input_files(resume_path)
            log("Uploaded CV/resume")
            return
        except Exception:
            continue


def fill_work_experience(page: Page, profile: dict, log: Log) -> None:
    items = profile.get("work_experience") or []
    if not items:
        return

    title_loc = _all_label(page, [r"Job Title"])
    if not title_loc:
        return

    for idx, item in enumerate(items):
        try:
            available = (_all_label(page, [r"Job Title"]).count() if _all_label(page, [r"Job Title"]) else 0)
        except Exception:
            available = 0
        if idx >= available:
            if not _click_add_another(page, "Work Experience", log):
                log(f"Could not add work experience entry {idx + 1}; stopping work-history expansion")
                break

        _fill_one(page, [r"Job Title"], item.get("job_title", ""), log, idx)
        _fill_one(page, [r"^Company", r"Employer"], item.get("company", ""), log, idx)
        _fill_one(page, [r"^Location"], item.get("location", ""), log, idx)
        _check_one(page, [r"currently work here", r"Current Role"], bool(item.get("current")), log, idx)
        _fill_one(page, [r"^From", r"Start Date"], item.get("from", ""), log, idx)
        if not item.get("current"):
            _fill_one(page, [r"^To", r"End Date"], item.get("to", ""), log, idx)
        _fill_one(page, [r"Role Description", r"Description", r"Responsibilities"], item.get("description", ""), log, idx)


def fill_education(page: Page, profile: dict, log: Log) -> None:
    items = profile.get("education") or []
    if not items:
        return

    institution_patterns = [r"School", r"Institution", r"University"]
    institution_loc = _all_label(page, institution_patterns)
    if not institution_loc:
        # Education may require clicking Add before any fields exist.
        if not _click_add_another(page, "Education", log):
            return

    for idx, item in enumerate(items):
        loc = _all_label(page, institution_patterns)
        available = loc.count() if loc else 0
        if idx >= available:
            if not _click_add_another(page, "Education", log):
                break
        _fill_one(page, institution_patterns, item.get("institution", ""), log, idx)
        _fill_one(page, [r"Degree"], item.get("degree", ""), log, idx)
        _fill_one(page, [r"Field of Study", r"Field"], item.get("field", ""), log, idx)
        _fill_one(page, [r"Education.*Location", r"^Location"], item.get("location", ""), log, idx)
        _fill_one(page, [r"Start Date", r"^From"], item.get("from", ""), log, idx)
        _fill_one(page, [r"End Date", r"^To"], item.get("to", ""), log, idx)


def _page_text(page: Page) -> str:
    try:
        return page.locator("body").inner_text(timeout=3000)
    except Exception:
        return ""


def _blocked_stage(page: Page) -> str | None:
    text = _page_text(page).lower()
    if "voluntary disclosure" in text or "voluntary disclosures" in text:
        return "voluntary disclosures"
    # Stop at review rather than submit.
    headings = page.get_by_role("heading", name=re.compile(r"^Review$", re.I))
    try:
        if headings.count() and headings.first.is_visible():
            return "review"
    except Exception:
        pass
    return None


def fill_current_page(page: Page, profile: dict, resume_path: str, log: Log) -> None:
    fill_personal(page, profile, log)
    fill_resume(page, resume_path, log)
    fill_work_experience(page, profile, log)
    fill_education(page, profile, log)


def _save_and_continue(page: Page, log: Log) -> bool:
    button = page.get_by_role("button", name=re.compile(r"Save and Continue|Next|Continue", re.I))
    try:
        if not button.count():
            return False
        target = button.last
        if not target.is_visible() or not target.is_enabled():
            return False
        target.click()
        log("Clicked Save and Continue")
        page.wait_for_timeout(1000)
        return True
    except Exception as exc:
        log(f"Could not advance: {exc}")
        return False


def run_autofill(playwright: Playwright, config: dict, log: Log) -> tuple[Page, object]:
    browser_name = str(config.get("browser") or "chromium").lower()
    headless = bool(config.get("headless", True))
    user_data_dir = str(config["browser_profile_dir"])
    Path(user_data_dir).mkdir(parents=True, exist_ok=True)

    executable = None if browser_name == "chromium" else _executable_for(browser_name)
    if browser_name != "chromium" and not executable:
        log(f"Requested {browser_name} executable was not found; using Playwright Chromium")

    launch_args = {
        "user_data_dir": user_data_dir,
        "headless": headless,
        "viewport": {"width": 1440, "height": 1000},
        "args": ["--disable-blink-features=AutomationControlled"],
    }
    if executable:
        launch_args["executable_path"] = executable

    context = playwright.chromium.launch_persistent_context(**launch_args)
    page = context.pages[0] if context.pages else context.new_page()
    page.set_default_timeout(3500)

    log(f"Opening {config['job_url']}")
    page.goto(config["job_url"], wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(1200)

    profile = config.get("profile") or {}
    resume = config.get("resume_path") or ""
    auto_advance = bool(config.get("auto_advance", False))

    for step in range(8):
        blocked = _blocked_stage(page)
        if blocked:
            log(f"Stopped at {blocked}; human review required")
            break
        log(f"Scanning form step {step + 1}")
        fill_current_page(page, profile, resume, log)
        if not auto_advance:
            break
        if not _save_and_continue(page, log):
            break
        try:
            page.wait_for_load_state("domcontentloaded", timeout=8000)
        except PlaywrightTimeoutError:
            pass
        page.wait_for_timeout(800)

    return page, context
