from formapp.profile import heuristic_profile, normalize_profile


def test_heuristic_extracts_contact_and_links():
    text = """Sylwester Example
sylwester@example.com
+44 7000 000000
https://example.com
https://linkedin.com/in/example
https://github.com/example
"""
    profile = heuristic_profile(text)
    assert profile["personal"]["full_name"] == "Sylwester Example"
    assert profile["personal"]["email"] == "sylwester@example.com"
    assert profile["links"]["linkedin"].startswith("https://linkedin.com")
    assert profile["links"]["github"].startswith("https://github.com")


def test_normalize_profile_splits_name():
    profile = normalize_profile({"personal": {"full_name": "Ada Lovelace"}})
    assert profile["personal"]["first_name"] == "Ada"
    assert profile["personal"]["last_name"] == "Lovelace"
