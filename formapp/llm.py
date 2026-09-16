from __future__ import annotations

import json
import os
import re
from typing import Any

import requests

from .profile import heuristic_profile, normalize_profile

SYSTEM_PROMPT = """You convert a CV into structured JSON for job application forms.
Use only information explicitly supported by the CV. Do not invent dates, employers,
qualifications, locations, skills, or job titles. Keep descriptions concise but factual.
Dates should preferably be MM/YYYY when the month is known, otherwise YYYY.
Return JSON only with exactly this shape:
{
  "personal": {
    "full_name": "", "first_name": "", "last_name": "", "email": "",
    "phone": "", "location": "", "address": "", "city": "",
    "postcode": "", "country": ""
  },
  "links": {"portfolio": "", "linkedin": "", "github": ""},
  "work_experience": [
    {"job_title": "", "company": "", "location": "", "from": "",
     "to": "", "current": false, "description": ""}
  ],
  "education": [
    {"institution": "", "degree": "", "field": "", "location": "",
     "from": "", "to": "", "description": ""}
  ],
  "skills": []
}
"""


def _parse_json(text: str) -> dict[str, Any]:
    text = text.strip()
    text = re.sub(r"^```(?:json)?\s*", "", text, flags=re.I)
    text = re.sub(r"\s*```$", "", text)
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        start, end = text.find("{"), text.rfind("}")
        if start < 0 or end <= start:
            raise ValueError("AI provider did not return JSON.")
        value = json.loads(text[start : end + 1])
    if not isinstance(value, dict):
        raise ValueError("AI provider returned a non-object JSON value.")
    return value


def _ollama(text: str, model: str) -> dict[str, Any]:
    url = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/") + "/api/chat"
    response = requests.post(
        url,
        json={
            "model": model or os.getenv("OLLAMA_MODEL", "qwen2.5:7b"),
            "stream": False,
            "format": "json",
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": text[:120000]},
            ],
        },
        timeout=180,
    )
    response.raise_for_status()
    payload = response.json()
    content = (payload.get("message") or {}).get("content") or ""
    return _parse_json(content)


def _openai(text: str, model: str) -> dict[str, Any]:
    from openai import OpenAI

    if not os.getenv("OPENAI_API_KEY"):
        raise ValueError("OPENAI_API_KEY is not configured.")
    client = OpenAI()
    response = client.responses.create(
        model=model or os.getenv("OPENAI_MODEL", "gpt-5.6-luna"),
        input=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": text[:120000]},
        ],
    )
    return _parse_json(response.output_text)


def profile_from_text(text: str, provider: str = "ollama", model: str = "") -> dict[str, Any]:
    provider = (provider or "none").lower()
    if provider == "ollama":
        profile = _ollama(text, model)
    elif provider == "openai":
        profile = _openai(text, model)
    elif provider == "none":
        profile = heuristic_profile(text)
    else:
        raise ValueError(f"Unknown AI provider: {provider}")
    return normalize_profile(profile)
