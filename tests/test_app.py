from pathlib import Path

from formapp import create_app


def test_health(tmp_path: Path):
    app = create_app({"TESTING": True, "DATA_DIR": tmp_path, "UPLOAD_DIR": tmp_path / "uploads", "PROFILE_DIR": tmp_path / "profiles", "JOB_DIR": tmp_path / "jobs", "BROWSER_PROFILE_DIR": tmp_path / "browser"})
    client = app.test_client()
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json()["ok"] is True
