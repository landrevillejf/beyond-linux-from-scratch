from pathlib import Path
from unittest.mock import MagicMock, patch


def test_update_sources_list_falls_back_to_output_dir_when_repo_file_is_not_writable(tmp_path, monkeypatch):
    from builder import LFSBuilder, LFSConfig

    monkeypatch.chdir(tmp_path)

    output_dir = tmp_path / 'lfs-build'
    output_dir.mkdir()
    config_file = tmp_path / 'config.json'
    config = LFSConfig(config_file)
    config.set('repositories', ['https://example.com/wget-list'])

    packages_dir = tmp_path / 'packages'
    packages_dir.mkdir()
    repo_sources_file = packages_dir / 'sources.list'
    repo_sources_file.write_text("https://example.com/stale-package.tar.gz\n")
    repo_sources_file.chmod(0o444)

    builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
    builder.config = config

    fake_content = b"https://example.com/fresh-package.tar.gz\n"
    mock_response = MagicMock()
    mock_response.read.return_value = fake_content
    mock_response.__enter__.return_value = mock_response
    mock_response.__exit__.return_value = None

    with patch('urllib.request.urlopen', return_value=mock_response), \
            patch(
                'os.access',
                side_effect=lambda path, mode: False if Path(path).resolve() == repo_sources_file.resolve() else True
            ):
        result = builder._update_sources_list()

    assert result is True
    assert builder._generated_sources_list == output_dir / 'packages' / 'sources.list'
    assert repo_sources_file.read_text() == "https://example.com/stale-package.tar.gz\n"
    assert (output_dir / 'packages' / 'sources.list').exists()
    assert "https://example.com/fresh-package.tar.gz" in (output_dir / 'packages' / 'sources.list').read_text()


def test_download_sources_prefers_generated_writable_sources_list(tmp_path, monkeypatch):
    from builder import LFSBuilder, LFSConfig

    monkeypatch.chdir(tmp_path)

    output_dir = tmp_path / 'lfs-build'
    output_dir.mkdir()
    config_file = tmp_path / 'config.json'
    config = LFSConfig(config_file)
    config.set('repositories', ['https://example.com/wget-list'])

    packages_dir = tmp_path / 'packages'
    packages_dir.mkdir()
    repo_sources_file = packages_dir / 'sources.list'
    repo_sources_file.write_text("https://example.com/stale-package.tar.gz\n")

    generated_sources_file = output_dir / 'packages' / 'sources.list'
    generated_sources_file.parent.mkdir(parents=True, exist_ok=True)
    generated_sources_file.write_text("https://example.com/fresh-package.tar.gz\n")

    builder = LFSBuilder(profile='minimal', output_dir=output_dir, config_file=config_file)
    builder.config = config
    builder._generated_sources_list = generated_sources_file

    with patch.object(builder, '_update_sources_list', return_value=True), \
            patch.object(builder.downloader, 'download_from_list', return_value=True) as mock_download, \
            patch.object(builder.downloader, 'verify_checksums', return_value=True):
        result = builder.download_sources()

    assert result is True
    mock_download.assert_called_once_with(generated_sources_file, parallel=4)
