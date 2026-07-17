#!/bin/bash
set -euo pipefail

python3 -m pytest tests/ --cov=builder --cov-report=term --cov-report=html --cov-report=annotate

if command -v open >/dev/null 2>&1; then
    open htmlcov/index.html 2>/dev/null || echo "📊 Coverage report in htmlcov/"
else
    echo "Coverage report in htmlcov/"
fi