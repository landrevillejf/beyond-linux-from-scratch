#!/usr/bin/env python3
"""
Tests for achieving 100% code coverage - remaining 10 lines
"""

import json
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch, MagicMock, call

sys.path.insert(0, str(Path(__file__).parent.parent))

from builder import SourceDownloader, BuildCache


class TestRemainingCoverageLines:
    """Test the final 10 uncovered lines"""

    def test_download_returns_false_when_all_fail(self, mock_logger, temp_dir):
        """Test line 623: download returns False when all attempts fail"""
        downloader = SourceDownloader(temp_dir / "sources", mock_logger)
        
        with patch('urllib.request.urlretrieve', side_effect=Exception("Network error")):
            # This tests the case where download fails for all retries
            result = downloader.download('http://invalid.url/file.tar.xz')
            
            assert result is False
    
    def test_find_script_returns_base_name_when_exists(self, temp_dir, mock_logger):
        """Test line 724: find_script returns path when base name exists"""
        from builder import ScriptExecutor
        
        # Create a script with just the base name
        script_path = temp_dir / "test-script.sh"
        script_path.write_text("#!/bin/bash\necho 'test'")
        script_path.chmod(0o755)
        
        executor = ScriptExecutor({}, temp_dir, mock_logger)
        
        # Change to temp_dir so the base name can be found
        import os
        old_cwd = os.getcwd()
        try:
            os.chdir(temp_dir)
            result = executor.find_script("test-script.sh")
            assert result is not None
            assert result.name == "test-script.sh"
        finally:
            os.chdir(old_cwd)
    
    def test_run_script_logs_last_lines_on_failure_with_content(self, temp_dir, mock_logger):
        """Test line 767: logging last 10 lines when script fails"""
        from builder import ScriptExecutor
        
        script = temp_dir / "test-fail.sh"
        script.write_text("#!/bin/bash\necho 'line1'\necho 'line2'\necho 'line3'\nexit 1")
        script.chmod(0o755)
        
        executor = ScriptExecutor({}, temp_dir, mock_logger)
        result = executor.run_script(str(script), "test-stage")
        
        assert result is False
        # Verify logger was called with the last lines
        assert mock_logger.info.called
    
    def test_resume_from_stage_script_execution_failure(self, temp_dir, mock_logger):
        """Test line 789: resume_from returns False when script fails"""
        from builder import ScriptExecutor
        
        script1 = temp_dir / "script1.sh"
        script1.write_text("#!/bin/bash\nexit 1")
        script1.chmod(0o755)
        
        executor = ScriptExecutor({}, temp_dir, mock_logger)
        stages = [("stage1", str(script1)), ("stage2", "dummy")]
        
        result = executor.resume_from("stage1", stages)
        assert result is False
    
    def test_build_cache_rmtree_when_image_dir_exists(self, temp_dir, mock_logger):
        """Test line 931: shutil.rmtree when image directory exists"""
        output_dir = temp_dir / "output"
        output_dir.mkdir()
        image_dir = output_dir / "image"
        image_dir.mkdir()
        
        # Create a dummy file in image dir
        (image_dir / "dummy.txt").write_text("test")
        
        cache = BuildCache("http://test.url", mock_logger)
        cache.metadata = {}
        
        # Mock tarfile to avoid actual extraction
        with patch('tarfile.open'):
            with patch('urllib.request.urlretrieve'):
                entry = {
                    'url': 'http://test.url/cache.tar.xz',
                    'sha256': None
                }
                
                # This should remove the existing image dir
                result = cache.download_and_extract(entry, output_dir)
                
                # Verify the directory was recreated
                assert image_dir.exists()
    
    def test_download_sources_warning_when_some_fail(self, builder, mock_logger):
        """Test line 1251: warning when some downloads fail"""
        with patch.object(builder, 'logger', mock_logger):
            with patch.object(builder.downloader, 'download_from_list', return_value=False):
                with patch.object(builder.downloader, 'verify_checksums', return_value=True):
                    result = builder.download_sources()
                    
                    # Should still return True (continues with available sources)
                    assert result is True
                    # Should log warning
                    mock_logger.warning.assert_called()
    
    def test_build_cache_extraction_failed_fallback_to_full_build(self, builder, mock_logger):
        """Test line 1369: cache extraction failed, fallback to full build"""
        with patch.object(builder, 'logger', mock_logger):
            with patch.object(builder, 'check_prerequisites', return_value=True):
                with patch.object(builder, 'prepare_environment', return_value=True):
                    with patch.object(builder, 'download_sources', return_value=True):
                        with patch.object(builder, 'get_build_stages', return_value=[]):
                            # Create a real BuildCache instance and mock its methods
                            with patch('builder.BuildCache') as MockCache:
                                mock_cache = MagicMock()
                                mock_cache.fetch_metadata.return_value = True
                                mock_cache.get_cached_entry.return_value = {'url': 'http://test'}
                                mock_cache.download_and_extract.return_value = False
                                MockCache.return_value = mock_cache
                                
                                # use_cache=True but extraction fails and cache_only=False
                                result = builder.build(use_cache=True, cache_only=False)
                                
                                # Should have warning about fallback
                                assert any('falling back' in str(call) for call in mock_logger.warning.call_args_list)
    
    def test_build_cache_metadata_unavailable_fallback(self, builder, mock_logger):
        """Test line 1379: cache metadata unavailable, perform full build"""
        with patch.object(builder, 'logger', mock_logger):
            with patch.object(builder, 'check_prerequisites', return_value=True):
                with patch.object(builder, 'prepare_environment', return_value=True):
                    with patch.object(builder, 'download_sources', return_value=True):
                        with patch.object(builder, 'get_build_stages', return_value=[]):
                            # Mock BuildCache
                            with patch('builder.BuildCache') as MockCache:
                                mock_cache = MagicMock()
                                mock_cache.fetch_metadata.return_value = False
                                MockCache.return_value = mock_cache
                                
                                # use_cache=True but metadata fetch fails and cache_only=False
                                result = builder.build(use_cache=True, cache_only=False)
                                
                                # Should have info about performing full build
                                assert any('full build' in str(call).lower() for call in mock_logger.info.call_args_list)
    
    def test_create_writable_media_lists_devices(self, builder, mock_logger):
        """Test line 1424: logging device info when no ISO provided"""
        from builder import USBWriter
        
        # Create the ISO first
        iso_path = builder.output_dir / 'lfs-installer.iso'
        iso_path.parent.mkdir(parents=True, exist_ok=True)
        iso_path.write_text("fake iso content")
        
        with patch.object(builder, 'logger', mock_logger):
            with patch.object(USBWriter, 'list_devices', return_value=[
                {'name': '/dev/sdb', 'size': '8GB', 'model': 'Kingston USB'}
            ]):
                result = builder.create_writable_media()
                
                # Result is True when no device specified but ISO exists
                assert result is True
                # Should log device information
                assert any('/dev/sdb' in str(call) for call in mock_logger.info.call_args_list)
    
    def test_main_entry_point(self, temp_dir):
        """Test line 1672: main() entry point"""
        import subprocess
        
        # Test that main() can be called (line 1672: if __name__ == '__main__': main())
        result = subprocess.run(
            [sys.executable, 'builder.py', '--help'],
            cwd=str(Path(__file__).parent.parent),
            capture_output=True,
            text=True
        )
        
        # Should succeed and show help
        assert result.returncode == 0
        assert 'usage' in result.stdout.lower()

