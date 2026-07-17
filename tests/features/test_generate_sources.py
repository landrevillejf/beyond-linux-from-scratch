import pytest
from pytest_bdd import given, when, then, scenarios
from pathlib import Path
import sys
import urllib.request
import builder

# Charge le scénario du fichier .feature
scenarios('generate_sources.feature')

# ------------------------------------------------------------
# Steps
# ------------------------------------------------------------

@given('a temporary directory')
def temp_dir(tmp_path, monkeypatch):
    """Se place dans un répertoire temporaire et crée la structure minimale."""
    monkeypatch.chdir(tmp_path)   # restauration automatique après le test
    (tmp_path / 'packages').mkdir(exist_ok=True)
    (tmp_path / 'config').mkdir(exist_ok=True)
    config_file = tmp_path / 'config' / 'build.conf'
    config_file.write_text('{"repositories": ["https://fake.url/wget-list"]}')
    return tmp_path

@given('a mock sources list from the internet', target_fixture='mock_urls')
def mock_sources_list(monkeypatch):
    """Simule le téléchargement du wget-list avec des URLs factices."""
    urls = [
        'https://example.com/package1.tar.gz',
        'https://example.com/package2.tar.xz'
    ]
    def fake_urlopen(url, *args, **kwargs):
        fake_response = '\n'.join(urls)
        class FakeResponse:
            def read(self):
                return fake_response.encode('utf-8')
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
        return FakeResponse()

    monkeypatch.setattr(urllib.request, 'urlopen', fake_urlopen)
    return urls

@when('I run the builder with --generate-sources-list')
def run_builder_generate_sources(monkeypatch):
    """Exécute builder.main() avec l'option --generate-sources-list."""
    test_args = ['builder.py', '--generate-sources-list']
    monkeypatch.setattr(sys, 'argv', test_args)
    builder.main()   # retourne après avoir généré le fichier

@then('the file packages/sources.list should exist')
def check_sources_list_exists():
    sources_file = Path('packages/sources.list')
    assert sources_file.exists(), "packages/sources.list n'a pas été créé"

@then('it should contain URLs from the mock sources')
def check_sources_list_contains_urls(mock_urls):
    sources_file = Path('packages/sources.list')
    content = sources_file.read_text()
    for url in mock_urls:
        assert url in content, f"URL {url} non trouvée dans sources.list"