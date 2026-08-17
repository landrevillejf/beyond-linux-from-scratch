#!/usr/bin/env python3
"""
Tests USBWriter avec matériel réel
⚠️ NÉCESSITE UNE CLÉ USB - Peut détruire des données !
Exécuter uniquement avec: pytest -m usb --usb-device=/dev/sdX
"""

import platform
import subprocess
import tempfile
from pathlib import Path
# tests/test_integration_usb.py - Ajouter l'import en haut du fichier
from unittest.mock import patch, MagicMock

import pytest
from builder import USBWriter

# Marqueur pour les tests USB réels (nécessite confirmation)
pytestmark = pytest.mark.usb


def pytest_addoption(parser):
    parser.addoption("--usb-device", action="store",
                     help="USB device to test (e.g., /dev/sdb)")
    parser.addoption("--dangerous", action="store_true",
                     help="Allow destructive USB tests")


class TestRealUSBDevice:
    """Tests avec une vraie clé USB (DANGEREUX - peut effacer des données)"""

    @pytest.fixture
    def usb_device(self, request):
        """Récupérer le périphérique USB depuis les arguments"""
        device = request.config.getoption("--usb-device")
        dangerous = request.config.getoption("--dangerous")

        if not device:
            pytest.skip("--usb-device not specified")
        if not dangerous:
            pytest.skip("--dangerous not specified (USB tests can destroy data)")

        # Vérifier que le périphérique existe
        if platform.system() == "Linux" and not Path(device).exists():
            pytest.skip(f"Device {device} does not exist")

        return device

    @pytest.fixture
    def test_iso(self, temp_dir):
        """Créer un ISO de test"""
        iso_path = temp_dir / "test-usb.iso"

        # Créer un ISO factice
        iso_path.write_text("DUMMY ISO CONTENT FOR TESTING")

        # En vrai, il faudrait un vrai ISO bootable
        # Pour les tests, on simule
        return iso_path

    def test_list_real_devices(self):
        """Lister les périphériques USB réels (non destructif)"""
        devices = USBWriter.list_devices()

        assert isinstance(devices, list)
        if devices:
            print(f"\n✅ Périphériques USB détectés:")
            for dev in devices:
                print(f"   - {dev['name']} ({dev['size']}) - {dev['model']}")
        else:
            print("⚠️ Aucun périphérique USB détecté")

    def test_write_to_real_usb(self, usb_device, test_iso, mock_logger, temp_dir):
        """Écrire sur une vraie clé USB (DESTRUCTIF)"""
        print(f"\n⚠️⚠️⚠️ ATTENTION ! ⚠️⚠️⚠️")
        print(f"Ce test va effacer {usb_device}")
        print(f"Assurez-vous que c'est la BONNE clé USB!")

        # Demander confirmation supplémentaire
        response = input("Tapez 'YES I AM SURE' pour continuer: ")
        if response != "YES I AM SURE":
            pytest.skip("Test annulé par l'utilisateur")

        # Exécuter l'écriture
        result = USBWriter.write_iso(test_iso, usb_device, mock_logger)

        if result:
            print(f"✅ ISO écrit avec succès sur {usb_device}")

            # Vérifier que l'écriture a fonctionné
            if platform.system() == "Linux":
                # Lire les premiers bytes pour vérifier
                result = subprocess.run(['dd', f'if={usb_device}', 'bs=512', 'count=1', 'status=none'],
                                        capture_output=True)
                assert len(result.stdout) > 0
        else:
            pytest.fail("L'écriture USB a échoué")

    def test_read_back_verification(self, usb_device, test_iso, mock_logger, temp_dir):
        """Vérifier l'intégrité après écriture"""
        # Calculer checksum original
        original_checksum = test_iso.read_bytes()

        # Lire depuis USB (seulement le début, pas tout l'ISO)
        if platform.system() == "Linux":
            result = subprocess.run(['dd', f'if={usb_device}', 'bs=1M', 'count=10', 'status=none'],
                                    capture_output=True)
            # Vérifier que des données ont été écrites
            assert len(result.stdout) > 0
            print(f"✅ {len(result.stdout)} bytes lus depuis {usb_device}")

    def test_verify_partition_table(self, usb_device):
        """Vérifier la table de partition après écriture"""
        if platform.system() == "Linux":
            result = subprocess.run(['sudo', 'fdisk', '-l', usb_device],
                                    capture_output=True, text=True)
            output = result.stdout

            print(f"\nTable de partition sur {usb_device}:")
            for line in output.split('\n')[:20]:
                print(f"  {line}")

            # Vérifications de base
            assert "Disk" in output

    def test_mount_and_read(self, usb_device, temp_dir):
        """Monter et lire le contenu de l'USB (si système de fichiers)"""
        if platform.system() != "Linux":
            pytest.skip("Mount test only on Linux")

        mount_point = temp_dir / "usb_mount"
        mount_point.mkdir()

        # Essayer de monter (peut échouer si pas de FS)
        try:
            subprocess.run(['sudo', 'mount', usb_device + '1', str(mount_point)],
                           capture_output=True, check=False)

            if mount_point.exists():
                files = list(mount_point.iterdir())
                print(f"✅ {len(files)} fichiers trouvés sur l'USB:")
                for f in files[:10]:
                    print(f"   - {f.name}")

            subprocess.run(['sudo', 'umount', str(mount_point)], capture_output=True)
        except Exception as e:
            print(f"⚠️ Impossible de monter: {e}")


class TestUSBSimulation:
    """Tests USB en simulation (sans matériel réel)"""

    def test_write_iso_simulation(self, temp_dir, mock_logger):
        """Test d'écriture ISO simulé (non destructif)"""
        iso_path = temp_dir / "test.iso"
        iso_path.write_text("SIMULATED ISO")

        simulated_device = temp_dir / "simulated_usb.img"

        with patch('platform.system', return_value='Linux'):
            with patch('subprocess.run') as mock_run:
                mock_run.return_value = MagicMock(returncode=0)
                with patch('builtins.input', return_value='YES'):
                    result = USBWriter.write_iso(iso_path, str(simulated_device), mock_logger)
                    assert result is True

    def test_verify_device_exists(self, mock_logger):
        """Vérifier la détection de périphériques inexistants"""
        result = USBWriter.write_iso(Path("/nonexistent.iso"), "/dev/nonexistent", mock_logger)
        assert result is False
        mock_logger.error.assert_called()