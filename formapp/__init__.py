from __future__ import annotations

import json
import os
import subprocess
import sys
import uuid
from pathlib import Path
from urllib.parse import urlparse

from dotenv import load_dotenv
from flask import Flask, jsonify, render_template, request, send_file
from werkzeug.utils import secure_filename

from .cv import extract_cv_text
from .llm import profile_from_text
from .profile import normalize_profile

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

ALLOWED_EXTENSIONS = {".pdf", ".docx", ".txt", ".md"}


def _env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _tail(path: Path, max_chars: int = 16000) -> str:
    if not path.exists():
        return ""
    text = path.read_text(encoding="utf-8", errors="replace")
    return text[-max_chars:]


def create_app(test_config: dict | None = None) -> Flask:
    app = Flask(__name__, template_folder=str(ROOT / "templates"), static_folder=str(ROOT / "static"))

    data_dir = Path(os.getenv("FORM_DATA_DIR", ROOT / "data")).expanduser().resolve()
    app.config.update(
        FORM_HOST=os.getenv("FORM_HOST", "127.0.0.1"),
        FORM_PORT=int(os.getenv("FORM_PORT", "5099")),
        DATA_DIR=data_dir,
        UPLOAD_DIR=data_dir / "uploads",
        PROFILE_DIR=data_dir / "profiles",
        JOB_DIR=data_dir / "jobs",
        BROWSER_PROFILE_DIR=Path(
            os.getenv("FORM_BROWSER_PROFILE_DIR", data_dir / "browser-profile")
        ).expanduser().resolve(),
        MAX_CONTENT_LENGTH=int(os.getenv("FORM_MAX_UPLOAD_MB", "12")) * 1024 * 1024,
        AI_PROVIDER=os.getenv("FORM_AI_PROVIDER", "ollama"),
        OLLAMA_MODEL=os.getenv("OLLAMA_MODEL", "qwen2.5:7b"),
        OPENAI_MODEL=os.getenv("OPENAI_MODEL", "gpt-5.6-luna"),
        FORM_BROWSER=os.getenv("FORM_BROWSER", "chromium"),
        FORM_HEADLESS=_env_bool("FORM_HEADLESS", True),
        FORM_AUTO_ADVANCE=_env_bool("FORM_AUTO_ADVANCE", False),
    )
    if test_config:
        app.config.update(test_config)

    for key in ("DATA_DIR", "UPLOAD_DIR", "PROFILE_DIR", "JOB_DIR", "BROWSER_PROFILE_DIR"):
        Path(app.config[key]).mkdir(parents=True, exist_ok=True)

    @app.get("/")
    def index():
        version = (ROOT / "VERSION").read_text().strip() if (ROOT / "VERSION").exists() else "dev"
        return render_template(
            "index.html",
            version=version,
            defaults={
                "provider": app.config["AI_PROVIDER"],
                "ollama_model": app.config["OLLAMA_MODEL"],
                "openai_model": app.config["OPENAI_MODEL"],
                "browser": app.config["FORM_BROWSER"],
                "headless": app.config["FORM_HEADLESS"],
                "auto_advance": app.config["FORM_AUTO_ADVANCE"],
            },
        )

    @app.get("/health")
    def health():
        version = (ROOT / "VERSION").read_text().strip() if (ROOT / "VERSION").exists() else "dev"
        return jsonify({"ok": True, "version": version})

    @app.post("/api/cv/parse")
    def parse_cv():
        upload = request.files.get("cv")
        if upload is None or not upload.filename:
            return jsonify({"ok": False, "error": "Choose a CV file."}), 400

        filename = secure_filename(upload.filename)
        suffix = Path(filename).suffix.lower()
        if suffix not in ALLOWED_EXTENSIONS:
            return jsonify({"ok": False, "error": f"Unsupported CV type: {suffix}"}), 400

        file_id = uuid.uuid4().hex
        stored = Path(app.config["UPLOAD_DIR"]) / f"{file_id}{suffix}"
        upload.save(stored)

        try:
            text = extract_cv_text(stored)
            provider = (request.form.get("provider") or app.config["AI_PROVIDER"]).strip().lower()
            model = (request.form.get("model") or "").strip()
            profile = profile_from_text(text, provider=provider, model=model)
            profile = normalize_profile(profile)
        except Exception as exc:  # UI boundary
            return jsonify({"ok": False, "error": str(exc)}), 500

        profile_id = uuid.uuid4().hex
        profile_path = Path(app.config["PROFILE_DIR"]) / f"{profile_id}.json"
        profile_path.write_text(json.dumps(profile, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

        return jsonify(
            {
                "ok": True,
                "profile": profile,
                "profile_id": profile_id,
                "resume_id": file_id,
                "resume_name": filename,
                "resume_path": str(stored),
                "provider": provider,
            }
        )

    @app.post("/api/profile/save")
    def save_profile():
        payload = request.get_json(silent=True) or {}
        profile = normalize_profile(payload.get("profile") or {})
        profile_id = secure_filename(str(payload.get("profile_id") or "current")) or "current"
        path = Path(app.config["PROFILE_DIR"]) / f"{profile_id}.json"
        path.write_text(json.dumps(profile, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return jsonify({"ok": True, "profile_id": profile_id})

    @app.post("/api/autofill")
    def autofill():
        payload = request.get_json(silent=True) or {}
        job_url = str(payload.get("job_url") or "").strip()
        parsed = urlparse(job_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            return jsonify({"ok": False, "error": "Enter a valid http(s) job URL."}), 400

        profile = normalize_profile(payload.get("profile") or {})
        if not profile.get("personal", {}).get("full_name") and not profile.get("work_experience"):
            return jsonify({"ok": False, "error": "Profile is empty. Parse or paste CV data first."}), 400

        resume_path = str(payload.get("resume_path") or "").strip()
        if resume_path:
            candidate = Path(resume_path).expanduser().resolve()
            upload_root = Path(app.config["UPLOAD_DIR"]).resolve()
            if upload_root not in candidate.parents or not candidate.exists():
                return jsonify({"ok": False, "error": "Resume path is not a stored upload."}), 400
        else:
            candidate = None

        job_id = uuid.uuid4().hex[:12]
        job_dir = Path(app.config["JOB_DIR"]) / job_id
        job_dir.mkdir(parents=True, exist_ok=True)
        job_path = job_dir / "job.json"
        status_path = job_dir / "status.json"

        config = {
            "job_id": job_id,
            "job_url": job_url,
            "profile": profile,
            "resume_path": str(candidate) if candidate else "",
            "browser": str(payload.get("browser") or app.config["FORM_BROWSER"]),
            "headless": bool(payload.get("headless", app.config["FORM_HEADLESS"])),
            "auto_advance": bool(payload.get("auto_advance", app.config["FORM_AUTO_ADVANCE"])),
            "browser_profile_dir": str(app.config["BROWSER_PROFILE_DIR"]),
            "job_dir": str(job_dir),
        }
        job_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
        status_path.write_text(json.dumps({"state": "queued", "message": "Queued"}) + "\n", encoding="utf-8")

        log_file = open(job_dir / "worker.log", "ab", buffering=0)
        env = os.environ.copy()
        subprocess.Popen(
            [sys.executable, "-m", "formapp.worker", str(job_path)],
            cwd=str(ROOT),
            env=env,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        log_file.close()
        return jsonify({"ok": True, "job_id": job_id})

    @app.get("/api/jobs/<job_id>")
    def job_status(job_id: str):
        safe_id = secure_filename(job_id)
        if safe_id != job_id:
            return jsonify({"ok": False, "error": "Invalid job id."}), 400
        job_dir = Path(app.config["JOB_DIR"]) / job_id
        status_path = job_dir / "status.json"
        if not status_path.exists():
            return jsonify({"ok": False, "error": "Job not found."}), 404
        status = json.loads(status_path.read_text(encoding="utf-8"))
        status["ok"] = True
        status["log"] = _tail(job_dir / "worker.log")
        status["has_screenshot"] = (job_dir / "review.png").exists()
        return jsonify(status)

    @app.get("/api/jobs/<job_id>/screenshot")
    def job_screenshot(job_id: str):
        safe_id = secure_filename(job_id)
        if safe_id != job_id:
            return jsonify({"ok": False, "error": "Invalid job id."}), 400
        path = Path(app.config["JOB_DIR"]) / job_id / "review.png"
        if not path.exists():
            return jsonify({"ok": False, "error": "Screenshot not available."}), 404
        return send_file(path, mimetype="image/png", max_age=0)

    return app
