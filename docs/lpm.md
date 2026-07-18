# LPM – Linux Package Manager for LFS

LPM is a lightweight, full‑featured package manager designed specifically for Linux From Scratch (LFS) and other custom distributions.  
It handles package installation, removal, upgrades, dependency resolution, and database management without relying on any external package management infrastructure.

## Features

- **Dependency resolution** – automatically installs required dependencies in the correct order.
- **File tracking** – records every installed file; removes only files that are not shared with other packages.
- **Checksum verification** – optional SHA256 integrity check before installation.
- **Pre/post install/remove hooks** – run custom scripts during package lifecycle.
- **Concurrent execution lock** – prevents multiple LPM instances from interfering.
- **Verbose and dry‑run modes** – simulate operations or get detailed debug output.
- **Repository support** – local packages ready, with structure for adding remote repositories.
- **Command set** – install, remove, update, upgrade, list, search, info, clean, and more.

## Installation

LPM is installed as part of the Beyond Linux from Scratch build process.  
If you need to install it manually, copy the `lpm` script to `/usr/local/bin/lpm` and make it executable:

```bash
install -m 755 lpm /usr/local/bin/lpm
mkdir -p /var/lib/lpm /var/log/lpm /etc/lpm /usr/local/share/lpm/packages
touch /var/lib/lpm/packages.list /var/lib/lpm/installed.list /var/lib/lpm/file_index
```

Ensure the configuration file `/etc/lpm/lpm.conf` exists (optional – all values have sensible defaults).

## Configuration

The configuration file `/etc/lpm/lpm.conf` can override the following variables (defaults shown):

```bash
LPM_DB="/var/lib/lpm"                     # Database directory
LPM_LOGS="/var/log/lpm"                   # Log files directory
LPM_PACKAGES_DIR="/usr/local/share/lpm/packages"  # Default local repository
LPM_REPOS=( "local" )                     # Enabled repositories
REPO_LOCAL_PATH="$LPM_PACKAGES_DIR"       # Path for the 'local' repository
VERIFY_CHECKSUMS=true                     # Enable SHA256 verification
LOG_TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"  # Timestamp format in logs
```

You can also set `USE_COLOR=false` to disable colorised output.

## Package Format

A package is a **tar.xz** archive with the following structure:

```
package-version.tar.xz
├── files/               # Files to install, with full path relative to root
│   ├── usr/
│   │   └── bin/
│   │       └── myapp
│   └── etc/
│       └── myapp.conf
├── pre-install.sh       # (optional) run before file installation
├── post-install.sh      # (optional) run after file installation
├── pre-remove.sh        # (optional) run before file removal
└── post-remove.sh       # (optional) run after file removal
```

All scripts must be executable and return `0` on success (non‑zero aborts the operation).

## Database

LPM maintains three files under `$LPM_DB`:

- **`packages.list`** – available packages database.  
  Format: `name:version:description:dependencies:sha256`  
  Example:  
  `bash:5.3:Bourne Again Shell:readline:sha256-dummy`

- **`installed.list`** – installed packages.  
  Format: `name version`

- **`file_index`** – maps installed files to packages.  
  Format: `file package-version`  
  Example:  
  `/usr/bin/bash bash-5.3`

## Commands

### `install <package>`
Install a package and its dependencies.  
`package` can be a bare name (`bash`) or name‑version (`bash-5.3`).  
Use `--force` to reinstall an already installed package.

### `remove <package>`
Remove an installed package.  
Files that are still required by other packages are preserved.

### `update <package>`
Remove then reinstall a package (upgrade it to the latest known version).

### `upgrade`
Check all installed packages and upgrade those that have a newer version in the database.

### `list`
Show all installed packages with version and description.

### `search <pattern>`
Search the package database for a pattern.

### `info <package>`
Display detailed information about a package: version, description, dependencies, and installed status.

### `update-db`
Refresh the package database (downloads repository indices – currently a placeholder).

### `clean`
Remove all cached `.tar.xz` files from the local repository directory.

### `help`
Display a short help summary.

### `version`
Show LPM version information.

## Global Options

These options can be placed before the command:

| Option       | Description |
|--------------|-------------|
| `--mode`     | Interface mode: `cli` (direct command) or `text` (interactive text interface). |
| `--dry-run`  | Simulate the operation (do not install or remove anything). |
| `--force`    | Force reinstallation even if a package is already installed. |
| `--quiet`    | Suppress all non‑error output. |
| `--verbose`  | Show detailed debug messages. |

Example:

```bash
# Start the interactive text interface
lpm --mode text
```

## Hooks

All hook scripts receive the package name as `$1` and the installed version as `$2`.  
They run from the extracted package directory and can access the package files via the `files/` subdirectory.  
Example `pre-install.sh`:

```bash
#!/bin/bash
echo "Preparing to install $1 ($2)"
# Perform pre-installation tasks
```

## Locking

LPM uses `flock` on `/var/lock/lpm.lock` to ensure only one instance modifies the database at a time.  
If another LPM process is already running, the command exits with an error.

## Logging

All operations are logged in:

- `/var/log/lpm/install.log` – all installations
- `/var/log/lpm/remove.log` – all removals

Each line contains a timestamp, action, and package name.

## Example Workflow

```bash
# Install a package with its dependencies
lpm install git

# List installed packages
lpm list

# Check for upgradable packages and upgrade all
lpm upgrade --dry-run
lpm upgrade

# Search for a package
lpm search python

# Show package info
lpm info bash

# Remove a package (shared files are kept)
lpm remove gcc
```

## Repository Structure

Currently, LPM ships with a local repository. To add a remote repository, implement a custom handler in the `install_package` function that downloads the `.tar.xz` from a URL. The `update-db` command would then fetch the remote index and merge it into the local database.

## Integration with LFS/BLFS Builder

LPM is automatically installed as part of the `20-lpm-advanced.sh` stage in the LFS/BLFS builder.  
The builder creates the necessary directories and populates the package database with pre‑built packages.

---

For any questions or contributions, refer to the project repository.  
LPM is maintained by Jean‑François Landreville (Dr. Land Evil).