#!/usr/bin/env python3
"""
LPM (LFS Package Manager) - Complete package management system
Version: 1.0.0
Provides install, remove, list, search, upgrade, and create commands
"""

import os
import sys
import json
import argparse
import subprocess
import hashlib
import tarfile
import shutil
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Optional, Tuple
import logging
import urllib.request
from dataclasses import dataclass, asdict

# ============================================================================
# CONSTANTS
# ============================================================================

LPM_VERSION = "1.0.0"

# Default directories (use ~/.lpm for local testing, /var/lib/lpm for production)
_home_lpm = Path.home() / ".lpm"
LPM_DB_DIR = _home_lpm / "db"  # Package database
LPM_CACHE_DIR = _home_lpm / "cache"  # Package cache
LPM_PACKAGES_DIR = LPM_CACHE_DIR / "packages"  # Downloaded packages
LPM_INSTALLED_DIR = _home_lpm / "installed"  # Installed packages
LPM_REPOS_DIR = LPM_CACHE_DIR / "repos"  # Repository data

# ============================================================================
# DATA CLASSES
# ============================================================================

@dataclass
class Package:
    """Package metadata"""
    name: str
    version: str
    arch: str = "x86_64"
    maintainer: str = "LFS"
    description: str = ""
    homepage: str = ""
    license: str = "GPL-3.0"
    size_mb: float = 0.0
    dependencies: List[str] = None
    checksum: str = ""
    url: str = ""
    install_date: str = ""

    def __post_init__(self):
        if self.dependencies is None:
            self.dependencies = []

    def to_dict(self):
        """Convert to dictionary"""
        data = asdict(self)
        data['dependencies'] = self.dependencies
        return data

    @classmethod
    def from_dict(cls, data: Dict):
        """Create from dictionary"""
        return cls(**data)


# ============================================================================
# PACKAGE DATABASE
# ============================================================================

class PackageDatabase:
    """Manage package database"""

    def __init__(self, db_dir: Path = LPM_DB_DIR):
        self.db_dir = db_dir
        self.db_file = db_dir / "packages.json"
        self.installed_file = db_dir / "installed.json"
        self.repositories_file = db_dir / "repositories.json"
        self.ensure_directories()

    def ensure_directories(self):
        """Create necessary directories"""
        self.db_dir.mkdir(parents=True, exist_ok=True)
        LPM_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        LPM_PACKAGES_DIR.mkdir(parents=True, exist_ok=True)
        LPM_INSTALLED_DIR.mkdir(parents=True, exist_ok=True)
        LPM_REPOS_DIR.mkdir(parents=True, exist_ok=True)

    def load_packages(self) -> Dict[str, Package]:
        """Load all available packages from database"""
        if not self.db_file.exists():
            return {}

        with open(self.db_file, 'r') as file_obj:
            data = json.load(file_obj)

        return {name: Package.from_dict(pkg) for name, pkg in data.items()}

    def save_packages(self, packages: Dict[str, Package]):
        """Save packages to database"""
        data = {name: pkg.to_dict() for name, pkg in packages.items()}
        with open(self.db_file, 'w') as f:
            json.dump(data, f, indent=2)

    def load_installed(self) -> Dict[str, Package]:
        """Load installed packages"""
        if not self.installed_file.exists():
            return {}

        with open(self.installed_file, 'r') as f:
            data = json.load(f)

        return {name: Package.from_dict(pkg) for name, pkg in data.items()}

    def save_installed(self, packages: Dict[str, Package]):
        """Save installed packages"""
        data = {name: pkg.to_dict() for name, pkg in packages.items()}
        with open(self.installed_file, 'w') as file_obj:
            json.dump(data, file_obj, indent=2)

    def add_package(self, package: Package):
        """Add package to database"""
        packages = self.load_packages()
        packages[package.name] = package
        self.save_packages(packages)

    def remove_package(self, name: str):
        """Remove package from database"""
        packages = self.load_packages()
        if name in packages:
            del packages[name]
            self.save_packages(packages)

    def get_package(self, name: str) -> Optional[Package]:
        """Get package by name"""
        packages = self.load_packages()
        return packages.get(name)

    def add_installed(self, package: Package):
        """Add installed package"""
        installed = self.load_installed()
        installed[package.name] = package
        self.save_installed(installed)

    def remove_installed(self, name: str):
        """Remove installed package"""
        installed = self.load_installed()
        if name in installed:
            del installed[name]
            self.save_installed(installed)

    def get_installed(self, name: str) -> Optional[Package]:
        """Get installed package by name"""
        installed = self.load_installed()
        return installed.get(name)


# ============================================================================
# PACKAGE MANAGER
# ============================================================================

class LPM:
    """LFS Package Manager"""

    def __init__(self, db_dir: Path = LPM_DB_DIR, verbose: bool = False):
        self.db = PackageDatabase(db_dir)
        self.logger = self._setup_logging(verbose)
        self.logger.info(f"LPM v{LPM_VERSION} initialized")

    def _setup_logging(self, verbose: bool) -> logging.Logger:
        """Setup logging"""
        level = logging.DEBUG if verbose else logging.INFO
        logging.basicConfig(
            level=level,
            format='%(levelname)s: %(message)s'
        )
        return logging.getLogger(__name__)

    def update(self) -> bool:
        """Update package database from repositories"""
        self.logger.info("Updating package database...")

        # Load default repositories
        repos = self._get_default_repositories()
        all_packages = {}

        for repo_name, repo_url in repos.items():
            self.logger.info(f"Fetching from {repo_name}...")
            try:
                packages = self._fetch_repository(repo_url)
                all_packages.update(packages)
                self.logger.info(f"  ✓ Added {len(packages)} packages from {repo_name}")
            except Exception as e:
                self.logger.warning(f"  ✗ Failed to fetch {repo_name}: {e}")

        self.db.save_packages(all_packages)
        self.logger.info(f"Database updated: {len(all_packages)} packages")
        return True

    def _get_default_repositories(self) -> Dict[str, str]:
        """Get default repositories"""
        return {
            "official": "https://github.com/lfs-builder/lpm-repo-official/raw/main/packages.json",
            "community": "https://github.com/lfs-builder/lpm-repo-community/raw/main/packages.json"
        }

    def _fetch_repository(self, url: str) -> Dict[str, Package]:
        """Fetch packages from repository"""
        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                data = json.loads(response.read().decode())

            packages = {}
            for name, pkg_data in data.items():
                packages[name] = Package.from_dict(pkg_data)
            return packages
        except Exception as e:
            self.logger.error(f"Failed to fetch repository: {e}")
            return {}

    def search(self, query: str) -> List[Package]:
        """Search for packages by name or description"""
        packages = self.db.load_packages()
        results = []

        query_lower = query.lower()
        for pkg in packages.values():
            if (query_lower in pkg.name.lower() or
                query_lower in pkg.description.lower()):
                results.append(pkg)

        return sorted(results, key=lambda p: p.name)

    def list_packages(self) -> List[Package]:
        """List all available packages"""
        packages = self.db.load_packages()
        return sorted(packages.values(), key=lambda p: p.name)

    def list_installed(self) -> List[Package]:
        """List installed packages"""
        installed = self.db.load_installed()
        return sorted(installed.values(), key=lambda p: p.name)

    def install(self, package_name: str, source: Optional[str] = None) -> bool:
        """Install a package"""
        # Check if already installed
        if self.db.get_installed(package_name):
            self.logger.warning(f"Package {package_name} already installed")
            return False

        # If source is provided (URL or local file), download/use it
        if source:
            return self._install_from_source(package_name, source)

        # Otherwise, search in database
        package = self.db.get_package(package_name)
        if not package:
            self.logger.error(f"Package not found: {package_name}")
            return False

        return self._install_package(package)

    def _install_from_source(self, name: str, source: str) -> bool:
        """Install package from source (URL or local file)"""
        self.logger.info(f"Installing {name} from source: {source}")

        if source.startswith(('http://', 'https://')):
            # Download from URL
            local_file = LPM_PACKAGES_DIR / source.split('/')[-1]
            self.logger.info(f"Downloading {source}...")
            try:
                urllib.request.urlretrieve(source, local_file)
                self.logger.info(f"  ✓ Downloaded to {local_file}")
            except Exception as e:
                self.logger.error(f"Download failed: {e}")
                return False
        else:
            # Local file
            local_file = Path(source)
            if not local_file.exists():
                self.logger.error(f"File not found: {source}")
                return False

        # Extract and install
        return self._extract_and_install(name, local_file)

    def _install_package(self, package: Package) -> bool:
        """Install package from database"""
        self.logger.info(f"Installing {package.name} v{package.version}...")

        # Check dependencies
        missing_deps = []
        for dep in package.dependencies:
            if not self.db.get_installed(dep):
                missing_deps.append(dep)

        if missing_deps:
            self.logger.error(f"Missing dependencies: {', '.join(missing_deps)}")
            return False

        # Download package
        local_file = LPM_PACKAGES_DIR / f"{package.name}-{package.version}.lpm"

        if not local_file.exists():
            self.logger.info(f"Downloading {package.name}...")
            try:
                urllib.request.urlretrieve(package.url, local_file)
                self.logger.info(f"  ✓ Downloaded")
            except Exception as e:
                self.logger.error(f"Download failed: {e}")
                return False

        # Verify checksum
        if not self._verify_checksum(local_file, package.checksum):
            self.logger.error("Checksum verification failed")
            return False

        # Extract and install
        return self._extract_and_install(package.name, local_file, package)

    def _verify_checksum(self, file_path: Path, expected_checksum: str) -> bool:
        """Verify file checksum"""
        if not expected_checksum:
            return True

        sha256 = hashlib.sha256(file_path.read_bytes()).hexdigest()
        return sha256 == expected_checksum

    def _extract_and_install(self, name: str, file_path: Path,
                            package: Optional[Package] = None) -> bool:
        """Extract and install package"""
        self.logger.info(f"Extracting {name}...")

        try:
            # Create installation directory
            install_dir = LPM_INSTALLED_DIR / name
            install_dir.mkdir(parents=True, exist_ok=True)

            # Extract tarball or LPM file (both are tarballs)
            with tarfile.open(file_path, 'r:*') as tar:
                tar.extractall(install_dir)

            self.logger.info(f"  ✓ Extracted to {install_dir}")

            # Run install script if present
            install_script = install_dir / "install.sh"
            if install_script.exists():
                self.logger.info("Running install script...")
                result = subprocess.run(['/bin/bash', str(install_script)],
                                      cwd=install_dir)
                if result.returncode != 0:
                    self.logger.error("Install script failed")
                    return False
                self.logger.info("  ✓ Install script completed")

            # Record installation
            if package is None:
                package = Package(name=name, version="1.0.0")
            package.install_date = datetime.now().isoformat()
            self.db.add_installed(package)

            self.logger.info(f"✓ {name} installed successfully")
            return True

        except Exception as exc:
            self.logger.error(f"Installation failed: {exc}")
            return False

    def remove(self, package_name: str, purge: bool = False) -> bool:
        """Remove installed package"""
        installed = self.db.get_installed(package_name)
        if not installed:
            self.logger.error(f"Package not installed: {package_name}")
            return False

        self.logger.info(f"Removing {package_name}...")

        # Check for dependents
        all_installed = self.db.load_installed()
        dependents = []
        for pkg in all_installed.values():
            if package_name in pkg.dependencies:
                dependents.append(pkg.name)

        if dependents:
            self.logger.warning(f"Packages depend on {package_name}: {', '.join(dependents)}")
            return False

        # Remove installation directory
        install_dir = LPM_INSTALLED_DIR / package_name
        if install_dir.exists():
            shutil.rmtree(install_dir)
            self.logger.info(f"  ✓ Removed installation directory")

        # Remove from database
        self.db.remove_installed(package_name)

        # Optionally remove cache
        if purge:
            cache_file = LPM_PACKAGES_DIR / f"{package_name}*.lpm"
            for f in LPM_PACKAGES_DIR.glob(f"{package_name}*.lpm"):
                f.unlink()
                self.logger.info(f"  ✓ Purged {f.name}")

        self.logger.info(f"✓ {package_name} removed successfully")
        return True

    def upgrade(self, package_name: Optional[str] = None) -> bool:
        """Upgrade package(s)"""
        installed = self.db.load_installed()
        packages = self.db.load_packages()

        if package_name:
            # Upgrade specific package
            if package_name not in installed:
                self.logger.error(f"Package not installed: {package_name}")
                return False

            if package_name not in packages:
                self.logger.error(f"Package not in database: {package_name}")
                return False

            installed_pkg = installed[package_name]
            available_pkg = packages[package_name]

            if installed_pkg.version >= available_pkg.version:
                self.logger.info(f"{package_name} is up to date")
                return True

            self.logger.info(f"Upgrading {package_name} from {installed_pkg.version} to {available_pkg.version}...")
            self.remove(package_name)
            return self._install_package(available_pkg)

        else:
            # Upgrade all packages
            upgradable = 0
            for name, installed_pkg in installed.items():
                if name in packages:
                    available_pkg = packages[name]
                    if installed_pkg.version < available_pkg.version:
                        upgradable += 1
                        self.logger.info(f"Upgrading {name}...")
                        self.remove(name)
                        self._install_package(available_pkg)

            self.logger.info(f"✓ Upgraded {upgradable} packages")
            return True

    def list_outdated(self) -> List[Tuple[str, str, str]]:
        """List outdated packages (name, current_version, available_version)"""
        installed = self.db.load_installed()
        packages = self.db.load_packages()

        outdated = []
        for name, installed_pkg in installed.items():
            if name in packages:
                available_pkg = packages[name]
                if installed_pkg.version < available_pkg.version:
                    outdated.append((name, installed_pkg.version, available_pkg.version))

        return sorted(outdated)

    def create_package(self, name: str, version: str,
                      description: str = "", license_str: str = "GPL-3.0") -> bool:
        """Create a new package from current system files"""
        self.logger.info(f"Creating package: {name} v{version}")

        # This would typically involve:
        # 1. Tracking installed files
        # 2. Creating package metadata
        # 3. Creating tarball

        package_dir = LPM_PACKAGES_DIR / f"{name}-{version}"
        package_dir.mkdir(parents=True, exist_ok=True)

        # Create metadata
        package = Package(
            name=name,
            version=version,
            description=description,
            license=license_str
        )

        metadata_file = package_dir / "metadata.json"
        with open(metadata_file, 'w') as f:
            json.dump(package.to_dict(), f, indent=2)

        self.logger.info(f"✓ Package created at {package_dir}")
        return True


# ============================================================================
# COMMAND LINE INTERFACE
# ============================================================================

def create_parser() -> argparse.ArgumentParser:
    """Create argument parser"""
    parser = argparse.ArgumentParser(
        description='LPM - LFS Package Manager',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Examples:
  # Update package database
  lpm update

  # Search packages
  lpm search "java"

  # Install package
  lpm install firefox

  # Install from source
  lpm install java https://example.com/java-21.tar.gz

  # List packages
  lpm list
  lpm list-installed

  # Remove package
  lpm remove firefox

  # Upgrade packages
  lpm upgrade                    # Upgrade all
  lpm upgrade firefox            # Upgrade specific

  # List outdated packages
  lpm list-outdated

  # Create package
  lpm create myapp 1.0.0
        """
    )

    subparsers = parser.add_subparsers(dest='command', help='Command to execute')

    # Update command
    subparsers.add_parser('update', help='Update package database')

    # Search command
    search_parser = subparsers.add_parser('search', help='Search for packages')
    search_parser.add_argument('query', help='Search query')

    # List command
    list_parser = subparsers.add_parser('list', help='List available packages')
    list_parser.add_argument('--installed', action='store_true', help='List installed packages')

    # List installed (shortcut)
    subparsers.add_parser('list-installed', help='List installed packages')

    # Install command
    install_parser = subparsers.add_parser('install', help='Install package')
    install_parser.add_argument('package', help='Package name')
    install_parser.add_argument('--source', help='Source URL or local file')

    # Remove command
    remove_parser = subparsers.add_parser('remove', help='Remove package')
    remove_parser.add_argument('package', help='Package name')
    remove_parser.add_argument('--purge', action='store_true', help='Also remove cache')

    # Upgrade command
    upgrade_parser = subparsers.add_parser('upgrade', help='Upgrade packages')
    upgrade_parser.add_argument('package', nargs='?', help='Specific package (optional)')

    # List outdated command
    subparsers.add_parser('list-outdated', help='List outdated packages')

    # Create command
    create_parser = subparsers.add_parser('create', help='Create package')
    create_parser.add_argument('name', help='Package name')
    create_parser.add_argument('version', help='Package version')
    create_parser.add_argument('--description', default='', help='Package description')
    create_parser.add_argument('--license', default='GPL-3.0', help='Package license')

    # Info command
    info_parser = subparsers.add_parser('info', help='Show package info')
    info_parser.add_argument('package', help='Package name')

    # Global options
    parser.add_argument(
        '--mode',
        choices=['cli', 'text'],
        default='cli',
        help='Interface mode: cli (direct command) or text (interactive menu)'
    )
    parser.add_argument('--verbose', '-v', action='store_true', help='Verbose output')
    parser.add_argument('--db-dir', type=Path, default=LPM_DB_DIR, help='Database directory')
    parser.add_argument('--version', action='version', version=f'LPM v{LPM_VERSION}')

    return parser


def execute_command(lpm: LPM, args: argparse.Namespace):
    """Execute one parsed command"""
    if args.command == 'update':
        lpm.update()

    elif args.command == 'search':
        results = lpm.search(args.query)
        if not results:
            print(f"No packages found matching '{args.query}'")
        else:
            print(f"\nFound {len(results)} package(s):\n")
            for pkg in results:
                print(f"  {pkg.name} ({pkg.version})")
                print(f"    {pkg.description}")

    elif args.command == 'list':
        if getattr(args, 'installed', False):
            packages = lpm.list_installed()
            print(f"\n{len(packages)} installed package(s):\n")
            for pkg in packages:
                print(f"  {pkg.name:<20} {pkg.version:<15} (installed: {pkg.install_date})")
        else:
            packages = lpm.list_packages()
            print(f"\n{len(packages)} available package(s):\n")
            for pkg in packages:
                print(f"  {pkg.name:<20} {pkg.version:<15} {pkg.description}")

    elif args.command == 'list-installed':
        packages = lpm.list_installed()
        print(f"\n{len(packages)} installed package(s):\n")
        for pkg in packages:
            print(f"  {pkg.name:<20} {pkg.version:<15} (installed: {pkg.install_date})")

    elif args.command == 'install':
        lpm.install(args.package, getattr(args, 'source', None))

    elif args.command == 'remove':
        lpm.remove(args.package, getattr(args, 'purge', False))

    elif args.command == 'upgrade':
        lpm.upgrade(getattr(args, 'package', None))

    elif args.command == 'list-outdated':
        outdated = lpm.list_outdated()
        if not outdated:
            print("All packages are up to date!")
        else:
            print(f"\n{len(outdated)} outdated package(s):\n")
            for name, current, available in outdated:
                print(f"  {name:<20} {current:<15} → {available}")

    elif args.command == 'create':
        lpm.create_package(
            args.name, args.version,
            getattr(args, 'description', ''),
            getattr(args, 'license', 'GPL-3.0')
        )

    elif args.command == 'info':
        pkg = lpm.db.get_package(args.package)
        if not pkg:
            print(f"Package not found: {args.package}")
            return
        print(f"\n{pkg.name} v{pkg.version}")
        print(f"  Description: {pkg.description}")
        print(f"  Maintainer: {pkg.maintainer}")
        print(f"  License: {pkg.license}")
        print(f"  Size: {pkg.size_mb} MB")
        if pkg.dependencies:
            print(f"  Dependencies: {', '.join(pkg.dependencies)}")


def run_text_interface(lpm: LPM):
    """Run interactive text interface"""
    print("LPM text interface started. Type the number of an action.")

    while True:
        print(
            "\n1) Update database\n"
            "2) Search package\n"
            "3) List packages\n"
            "4) List installed\n"
            "5) Install package\n"
            "6) Remove package\n"
            "7) Upgrade package/all\n"
            "8) List outdated\n"
            "9) Package info\n"
            "10) Create package\n"
            "0) Quit"
        )
        try:
            choice = input("lpm[text]> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nExiting text interface.")
            return

        if choice in ('0', 'q', 'quit', 'exit'):
            print("Exiting text interface.")
            return
        if choice == '1':
            execute_command(lpm, argparse.Namespace(command='update'))
        elif choice == '2':
            query = input("Search query: ").strip()
            if query:
                execute_command(lpm, argparse.Namespace(command='search', query=query))
        elif choice == '3':
            execute_command(lpm, argparse.Namespace(command='list', installed=False))
        elif choice == '4':
            execute_command(lpm, argparse.Namespace(command='list-installed'))
        elif choice == '5':
            package = input("Package name: ").strip()
            source = input("Source URL/path (optional): ").strip()
            if package:
                execute_command(
                    lpm,
                    argparse.Namespace(
                        command='install',
                        package=package,
                        source=source or None
                    )
                )
        elif choice == '6':
            package = input("Package name: ").strip()
            purge_answer = input("Purge cache too? [y/N]: ").strip().lower()
            if package:
                execute_command(
                    lpm,
                    argparse.Namespace(
                        command='remove',
                        package=package,
                        purge=purge_answer in ('y', 'yes')
                    )
                )
        elif choice == '7':
            package = input("Package name (leave empty for all): ").strip()
            execute_command(
                lpm,
                argparse.Namespace(command='upgrade', package=package or None)
            )
        elif choice == '8':
            execute_command(lpm, argparse.Namespace(command='list-outdated'))
        elif choice == '9':
            package = input("Package name: ").strip()
            if package:
                execute_command(lpm, argparse.Namespace(command='info', package=package))
        elif choice == '10':
            name = input("Package name: ").strip()
            version = input("Package version: ").strip()
            description = input("Description (optional): ").strip()
            license_name = input("License [GPL-3.0]: ").strip() or "GPL-3.0"
            if name and version:
                execute_command(
                    lpm,
                    argparse.Namespace(
                        command='create',
                        name=name,
                        version=version,
                        description=description,
                        license=license_name
                    )
                )
        else:
            print("Invalid choice.")


def main():
    """Main entry point"""
    parser = create_parser()
    args = parser.parse_args()

    if args.mode == 'text':
        lpm = LPM(db_dir=args.db_dir, verbose=args.verbose)
        if args.command:
            execute_command(lpm, args)
        else:
            run_text_interface(lpm)
        return

    if not args.command:
        parser.print_help()
        return

    lpm = LPM(db_dir=args.db_dir, verbose=args.verbose)

    try:
        execute_command(lpm, args)

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
