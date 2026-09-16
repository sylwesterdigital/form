from __future__ import annotations

import re
from typing import Any

PROFILE_TEMPLATE = {
    "personal": {
        "full_name": "",
        "first_name": "",
        "last_name": "",
        "email": "",
        "phone": "",
        "location": "",
        "address": "",
        "city": "",
        "postcode": "",
        "country": "",
    },
    "links": {"portfolio": "", "linkedin": "", "github": ""},
    "work_experience": [],
    "education": [],
    "skills": [],
}


def _clean(value: Any) -> str:
    return str(value or "").strip()


def normalize_profile(profile: dict[str, Any] | None) -> dict[str, Any]:
    profile = profile if isinstance(profile, dict) else {}
    personal_in = profile.get("personal") if isinstance(profile.get("personal"), dict) else {}
    links_in = profile.get("links") if isinstance(profile.get("links"), dict) else {}

    result = {
        "personal": {k: _clean(personal_in.get(k)) for k in PROFILE_TEMPLATE["personal"]},
        "links": {k: _clean(links_in.get(k)) for k in PROFILE_TEMPLATE["links"]},
        "work_experience": [],
        "education": [],
        "skills": [],
    }

    if result["personal"]["full_name"] and not result["personal"]["first_name"]:
        parts = result["personal"]["full_name"].split()
        result["personal"]["first_name"] = parts[0] if parts else ""
        result["personal"]["last_name"] = " ".join(parts[1:]) if len(parts) > 1 else ""
    elif not result["personal"]["full_name"]:
        result["personal"]["full_name"] = " ".join(
            x for x in [result["personal"]["first_name"], result["personal"]["last_name"]] if x
        )

    for item in profile.get("work_experience") or []:
        if not isinstance(item, dict):
            continue
        result["work_experience"].append(
            {
                "job_title": _clean(item.get("job_title")),
                "company": _clean(item.get("company")),
                "location": _clean(item.get("location")),
                "from": _clean(item.get("from")),
                "to": _clean(item.get("to")),
                "current": bool(item.get("current", False)),
                "description": _clean(item.get("description")),
            }
        )

    for item in profile.get("education") or []:
        if not isinstance(item, dict):
            continue
        result["education"].append(
            {
                "institution": _clean(item.get("institution")),
                "degree": _clean(item.get("degree")),
                "field": _clean(item.get("field")),
                "location": _clean(item.get("location")),
                "from": _clean(item.get("from")),
                "to": _clean(item.get("to")),
                "description": _clean(item.get("description")),
            }
        )

    result["skills"] = [_clean(x) for x in (profile.get("skills") or []) if _clean(x)]
    return result


def heuristic_profile(text: str) -> dict[str, Any]:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    first = lines[0] if lines else ""
    email_match = re.search(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", text, re.I)
    phone_match = re.search(r"(?:\+?\d[\d\s().-]{7,}\d)", text)
    urls = re.findall(r"https?://[^\s|<>]+", text)

    links = {"portfolio": "", "linkedin": "", "github": ""}
    for url in urls:
        clean = url.rstrip(".,);]")
        if "linkedin.com" in clean and not links["linkedin"]:
            links["linkedin"] = clean
        elif "github.com" in clean and not links["github"]:
            links["github"] = clean
        elif not links["portfolio"]:
            links["portfolio"] = clean

    profile = {
        "personal": {
            "full_name": first,
            "email": email_match.group(0) if email_match else "",
            "phone": phone_match.group(0).strip() if phone_match else "",
        },
        "links": links,
        "work_experience": [],
        "education": [],
        "skills": [],
    }
    return normalize_profile(profile)
