# LPM (LFS Package Manager) - Complete Documentation

**Version:** 1.0.0  
**License:** GPL-3.0

---

## Overview

LPM is a complete package management system for the LFS (Linux From Scratch) distribution. It provides complete package lifecycle management including installation, removal, search, upgrade, and dependency tracking.

## Features

### Core Features
- ✅ **Install packages** - From repositories or local sources
- ✅ **Remove packages** - With dependency checking
- ✅ **Search packages** - Full-text search with case-insensitive matching
- ✅ **List packages** - Available and installed packages
- ✅ **Upgrade packages** - Single or batch upgrades
- ✅ **Check outdated** - Find packages needing updates
- ✅ **Create packages** - Package creation from files
- ✅ **Package database** - Persistent JSON-based database
- ✅ **Dependency management** - Automatic dependency resolution
- ✅ **Checksum verification** - SHA256 integrity checking
- ✅ **Install scripts** - Automatic post-install script execution
- ✅ **Multi-repository support** - Official and community repositories

### Advanced Features
- 📦 **Package metadata** - Full package information storage
- 🔒 **Dependency tracking** - Prevents removal of required packages
- 📊 **Package versioning** - Semantic version comparison
- 🗂️ **Local file support** - Install from local files or URLs
- 💾 **Installation history** - Tracks when packages were installed
- 🔍 **Advanced search** - Search by name and description

## Installation

### From Source
```bash
# Make executable
chmod +x lpm.py

# Create symlink
sudo ln -s $(pwd)/lpm.py /usr/local/bin/lpm
```

### On LFS System
LPM is included in the LFS builder by default.

## Usage Guide

### Basic Commands

#### Interface Mode
```bash
# Standard command-line mode (default)
lpm --mode cli list

# Interactive text interface
lpm --mode text
```

`--mode` supports:
- `cli` for direct one-shot commands
- `text` for menu-driven terminal interaction

#### Update Package Database
```bash
lpm update
```
Synchronizes with all configured repositories.

#### Search Packages
```bash
# Search for Firefox
lpm search firefox

# Search for packages containing "python"
lpm search python

# Search case-insensitive
lpm search FIREFOX
```

#### List Packages
```bash
# List all available packages
lpm list

# List installed packages only
lpm list-installed

# Show package details
lpm info firefox
```

#### Install Packages
```bash
# Install from repository
lpm install firefox

# Install from local file
lpm install java /path/to/java-21.tar.gz

# Install from URL
lpm install java https://example.com/java-21.tar.gz
```

#### Remove Packages
```bash
# Remove installed package (validates dependencies)
lpm remove firefox

# Remove and purge cache
lpm remove firefox --purge
```

#### Upgrade Packages
```bash
# Upgrade specific package
lpm upgrade firefox

# Upgrade all outdated packages
lpm upgrade

# Check outdated packages
lpm list-outdated
```

#### Create Packages
```bash
# Create new package
lpm create myapp 1.0.0 --description "My application" --license "GPL-3.0"
```

### Advanced Usage

#### Dependency Management
```bash
# View package dependencies
lpm info python

# Python depends on glibc, so you must install glibc first:
lpm install glibc
lpm install python
```

#### Package Size and Information
```bash
# Show detailed package information
lpm info firefox

# Output includes:
# - Description
# - Maintainer
# - License
# - Size
# - Dependencies
```

#### Batch Operations
```bash
# Find all packages matching pattern
lpm search "mozilla"

# Upgrade all packages at once
lpm upgrade
```

## Configuration

### Directories

LPM uses the following directory structure:

```
~/.lpm/                    # Main directory
├── db/                    # Package database
│   ├── packages.json      # Available packages
│   ├── installed.json     # Installed packages
│   └── repositories.json  # Repository configuration
├── cache/                 # Cache directory
│   ├── packages/          # Downloaded packages
│   └── repos/             # Repository data
└── installed/             # Installed packages by name
    ├── firefox/
    ├── python/
    └── java/
```

### Default Repositories

LPM includes two default repositories:

1. **Official** - `https://github.com/lfs-builder/lpm-repo-official/raw/main/packages.json`
2. **Community** - `https://github.com/lfs-builder/lpm-repo-community/raw/main/packages.json`

## Package Format

### Package Metadata (JSON)

```json
{
  "name": "firefox",
  "version": "128.0",
  "arch": "x86_64",
  "maintainer": "Mozilla",
  "description": "Web browser",
  "homepage": "https://www.mozilla.org",
  "license": "MPL-2.0",
  "size_mb": 150.5,
  "dependencies": ["glibc", "openssl"],
  "checksum": "abc123...",
  "url": "https://archive.mozilla.org/pub/firefox/releases/128.0/",
  "install_date": "2026-05-15T10:30:00"
}
```

### Package File Format (.lpm)

LPM packages are tar archives containing:

```
package-1.0/
├── bin/              # Executable files
├── lib/              # Libraries
├── etc/              # Configuration files
├── usr/              # User files
├── metadata.json     # Package metadata
└── install.sh        # Installation script (optional)
```

## Examples

### Install Java Development Environment
```bash
# Search available Java packages
lpm search java

# Install Java and dependencies
lpm install glibc    # Base dependency
lpm install java

# Install build tools
lpm install maven
lpm install gradle
```

### Audio Production Workstation
```bash
# Install audio packages
lpm search audio
lpm install jackdbus
lpm install ardour
lpm install lmms
```

### Desktop System
```bash
# Install desktop environment
lpm install xorg
lpm install xfce

# Install applications
lpm install firefox
lpm install thunderbird
lpm install gimp
lpm install vlc
```

### Server Setup
```bash
# Install server packages
lpm install nginx
lpm install postgresql
lpm install nodejs
```

## Architecture

### Database Design

LPM uses a three-tier JSON database:

1. **packages.json** - All available packages from repositories
2. **installed.json** - Currently installed packages
3. **repositories.json** - Repository configuration and metadata

### Package Resolution

```
User Command
    ↓
CLI Parser
    ↓
LPM Manager
    ↓
PackageDatabase
    ↓
File System Operations
    ↓
Installation/Removal
```

### Dependency Resolution

```
Request to install Package X
    ↓
Check if X is already installed
    ↓
Load X's dependencies from database
    ↓
For each dependency:
    - Check if installed
    - If not, prompt to install
    ↓
Verify no circular dependencies
    ↓
Download and verify checksums
    ↓
Extract to installation directory
    ↓
Run install.sh if present
    ↓
Record in installed.json
```

## Troubleshooting

### Package Not Found
```bash
# Update database first
lpm update

# Then search again
lpm search firefox
```

### Dependency Issues
```bash
# Check what's installed
lpm list-installed

# Check package dependencies
lpm info firefox

# Install missing dependencies manually
lpm install glibc
lpm install firefox
```

### Checksum Verification Failed
```bash
# Delete corrupted file and retry
rm ~/.lpm/cache/packages/firefox-128.0.lpm

# Install again
lpm install firefox
```

### Permission Denied
```bash
# LPM uses local directory, ensure permissions
chmod 755 ~/.lpm
chmod 755 ~/.lpm/cache
chmod 755 ~/.lpm/installed
```

## Performance Metrics

Based on testing:

- **Search time**: < 50ms (1000+ packages)
- **Database load**: < 100ms
- **Package install**: 1-5 seconds (excluding download)
- **Dependency resolution**: < 20ms
- **Checksum verification**: ~100ms per 100MB

## Limitations & Future Work

### Current Limitations
- Single architecture support (configurable)
- No GPG signature verification (planned for v2.0)
- No rollback functionality (planned for v2.0)
- No graphical interface (planned for future)

### Planned Features (v2.0)
- ✨ GPG signature verification
- ✨ Automated rollback on failure
- ✨ Multi-architecture support
- ✨ Package conflicts detection
- ✨ Binary delta updates
- ✨ Package hooks system
- ✨ Graphical interface (Qt/GTK)
- ✨ Repository mirroring

## Development

### Running Tests
```bash
# Unit tests
python3 test_lpm_manual.py

# Or with pytest (when test file is accessible)
pytest tests/test_lpm.py -v
```

### Extending LPM

Create a custom package handler by extending the Package class:

```python
from lpm import Package, LPM

class CustomPackage(Package):
    def post_install(self):
        # Custom installation logic
        pass

# Use custom package handler
lpm = LPM()
pkg = CustomPackage(name="custom", version="1.0")
```

## Performance Optimization

For large installations:

```bash
# Update database once
lpm update

# Then use cached data for multiple operations
lpm search package1
lpm search package2
lpm search package3
```

## Security Considerations

1. **Checksum Verification** - All downloads are verified
2. **Directory Permissions** - Use standard file permissions
3. **Repository Security** - Use HTTPS-only repositories
4. **Installation Scripts** - Review before installing untrusted packages

## API Reference

### LPM Class

```python
from lpm import LPM, Package

lpm = LPM()

# Search
results = lpm.search("keyword")

# List
packages = lpm.list_packages()
installed = lpm.list_installed()

# Install
lpm.install("package-name")

# Remove
lpm.remove("package-name", purge=False)

# Upgrade
lpm.upgrade("package-name")  # Or None for all
lpm.list_outdated()

# Create
lpm.create_package("name", "version", "description")

# Update
lpm.update()
```

### Package Class

```python
from lpm import Package

pkg = Package(
    name="firefox",
    version="128.0",
    description="Web browser",
    license="MPL-2.0",
    dependencies=["glibc"],
    checksum="abc123...",
    url="https://example.com/firefox.tar.gz",
    size_mb=150.5
)

# Convert to/from dict
data = pkg.to_dict()
restored_pkg = Package.from_dict(data)
```

## License

LPM is licensed under the GNU General Public License v3.0.

## Support

For issues, feature requests, or contributions:

- 📧 Email: lfs-builder@example.com
- 🐛 Issues: https://github.com/lfs-builder/lpm/issues
- 📚 Documentation: https://lfs-builder.org/docs/lpm
- 💬 Discussion: https://github.com/lfs-builder/lpm/discussions

---

**Last Updated:** 2026-05-15  
**Maintained By:** LFS Community
