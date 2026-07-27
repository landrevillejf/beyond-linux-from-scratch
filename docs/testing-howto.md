## How to run tests

```bash
# Install test dependencies
pip install -r requirements.txt

# Run all tests
./run_tests.sh

# Run specific tests
./run_tests.sh -k "test_config"

# Run with verbose
./run_tests.sh -v

# Run without coverage
./run_tests.sh --no-cov

# Generate only coverage report
./run_tests.sh --cov-report=html --cov-report=term
```

## On macOS

```bash
# Create a virtual environment
python3 -m venv venv

# Activate the virtual environment
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Run tests
python -m pytest tests/ -v

# Exit the virtual environment
deactivate

# Run a specific test
python -m pytest tests/test_config.py -v  

# Run tests with coverage
python -m pytest tests/ -v --cov=builder --cov-report=term --cov-report=html --cov-report=annotate

# For USB tests (with a real USB stick - DANGEROUS)
python -m pytest tests/test_integration_usb.py -v --usb-device=/dev/sdb --dangerous
```

```bash
# Make the script executable
chmod +x mac-lfs-builder.sh

# Default build (XFCE)
./mac-lfs-builder.sh

# Build for Pinebook
./mac-lfs-builder.sh --pinebook

# Build for Brax3
./mac-lfs-builder.sh --brax3

# Build audio studio
./mac-lfs-builder.sh --audio-studio

# Build ARM64 (Raspberry Pi)
./mac-lfs-builder.sh --arm64

# Build minimal with sysvinit
./mac-lfs-builder.sh --profile minimal --init sysvinit

# Build full without live USB
./mac-lfs-builder.sh --profile full --no-live

# Clean
./mac-lfs-builder.sh --clean

# Help
./mac-lfs-builder.sh --help
```

## New Features

Option	Description
```bash
--pinebook	Build for Pinebook/Pinebook Pro
--brax3	Build for Brax3 smartphone
--audio-studio	Build full audio studio
--audio-cli	Build audio CLI (headless)
--arm64, -a	Cross-compile for ARM64
--init, -i	Choose init system
--no-live	Disable live system
--clean	Clean artifacts
```

```bash
# Build minimal GNU Free system
python3 builder.py --profile gnu-free

# Build full GNU Free system (with Emacs, IceCat, Octave)
python3 builder.py --profile gnu-free-full

# With alternative init system
python3 builder.py --profile gnu-free --init sysvinit

# On ARM64 (libre)
python3 builder.py --profile gnu-free --config config/build-cross.conf
```