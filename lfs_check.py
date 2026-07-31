#!/usr/bin/env python3
"""
LFS Script Compatibility Checker
Analyzes shell scripts for LFS compatibility issues.
"""

import os
import re
import sys
import argparse
import subprocess
from pathlib import Path
from typing import List, Dict, Tuple, Optional

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
DEFAULT_DIRS = ["host", "lfs", "blfs", "final"]
EXCLUDED_FILES = ["*.py", "*.md", "*.txt", "*.json", "*.conf"]
# Directories where certain rules are relaxed
HOST_DIRS = {"host", "common", "lfs", "blfs", "final"}
FINAL_DIRS = {"final", "lfs", "blfs"}           # chroot allowed here

# ------------------------------------------------------------------------------
# Check Rules
# ------------------------------------------------------------------------------
class CheckRule:
    def __init__(self, name, check_func, severity="warning", description=""):
        self.name = name
        self.check_func = check_func
        self.severity = severity  # "error" or "warning"
        self.description = description

class ScriptChecker:
    def __init__(self, verbose=False, use_shellcheck=False):
        self.verbose = verbose
        self.use_shellcheck = use_shellcheck
        self.results = []  # list of (file, severity, message, line)

    def check_file(self, filepath: Path, rel_path: str):
        """Analyze a .sh file."""
        self.results.clear()
        content = filepath.read_text(encoding="utf-8", errors="ignore")
        lines = content.splitlines()
        dirname = rel_path.split(os.sep)[0] if os.sep in rel_path else ""

        # 1. Shebang
        self._check_shebang(lines, rel_path)

        # 2. set -e / set -eu
        self._check_set_e(lines, rel_path)

        # 3. LFS variables
        self._check_lfs_vars(content, rel_path)

        # 4. Forbidden commands
        self._check_forbidden_commands(lines, rel_path, dirname)

        # 5. Suspicious paths
        self._check_paths(lines, rel_path)

        # 6. Bashisms if shebang is /bin/sh
        self._check_bashisms(lines, rel_path)

        # 7. Optional: shellcheck
        if self.use_shellcheck:
            self._run_shellcheck(filepath, rel_path)

        return self.results

    def _add_result(self, file, severity, message, line=None):
        self.results.append({
            "file": file,
            "severity": severity,
            "message": message,
            "line": line
        })

    def _check_shebang(self, lines, rel_path):
        if not lines:
            return
        shebang = lines[0]
        if shebang.startswith("#!"):
            if not ("bash" in shebang or "sh" in shebang):
                self._add_result(rel_path, "warning",
                                 f"Shebang should point to bash or sh: '{shebang}'", 1)
            if "/bin/sh" in shebang:
                self._add_result(rel_path, "warning",
                                 "Shebang uses /bin/sh (not bash). LFS typically uses bash.", 1)
            if "env bash" not in shebang and "/bin/bash" not in shebang:
                # not critical
                pass
        else:
            self._add_result(rel_path, "warning",
                             "Missing shebang (recommended: #!/bin/bash)", 1)

    def _check_set_e(self, lines, rel_path):
        found = False
        for i, line in enumerate(lines, 1):
            if line.strip().startswith("set -e") or line.strip().startswith("set -eu"):
                found = True
                break
        if not found:
            self._add_result(rel_path, "warning",
                             "Consider adding 'set -e' (or 'set -eu') to stop on error", None)

    def _check_lfs_vars(self, content, rel_path):
        if "LFS=" not in content and "$LFS" not in content:
            self._add_result(rel_path, "warning",
                             "Script does not appear to reference $LFS (might be OK for host scripts)", None)

    def _check_forbidden_commands(self, lines, rel_path, dirname):
        # sudo forbidden except in host/
        if dirname not in HOST_DIRS:
            for i, line in enumerate(lines, 1):
                if re.search(r'\bsudo\b', line):
                    self._add_result(rel_path, "error",
                                     f"'sudo' used in a script not in host/ (line {i})", i)
        # chroot forbidden except in final/
        if dirname not in FINAL_DIRS:
            for i, line in enumerate(lines, 1):
                if re.search(r'\bchroot\b', line) and not line.strip().startswith('#'):
                    self._add_result(rel_path, "warning",
                                     f"'chroot' used outside final/ (line {i})", i)
        # ldconfig must be /sbin/ldconfig
        for i, line in enumerate(lines, 1):
            if re.search(r'\bldconfig\b', line) and not re.search(r'/sbin/ldconfig', line):
                self._add_result(rel_path, "warning",
                                 f"'ldconfig' should be '/sbin/ldconfig' (line {i})", i)

    def _check_paths(self, lines, rel_path):
        for i, line in enumerate(lines, 1):
            if re.search(r'/usr/local/', line) and not line.strip().startswith('#'):
                self._add_result(rel_path, "warning",
                                 f"Use of '/usr/local' (not LFS compliant) at line {i}", i)
            if re.search(r'/opt/', line) and not line.strip().startswith('#'):
                self._add_result(rel_path, "warning",
                                 f"Use of '/opt' (not LFS standard) at line {i}", i)

    def _check_bashisms(self, lines, rel_path):
        # If shebang is /bin/sh, check for bashisms
        if lines and lines[0].strip().endswith("/bin/sh"):
            for i, line in enumerate(lines, 1):
                if re.search(r'\[\[', line):
                    self._add_result(rel_path, "error",
                                     f"Bashism: use of [[ ]] with /bin/sh (line {i})", i)
                if re.search(r'\(\(', line):
                    self._add_result(rel_path, "error",
                                     f"Bashism: use of (( )) with /bin/sh (line {i})", i)
                if re.search(r'\b(?:source|\.)\s+[^ ]+', line) and "source" in line:
                    if re.search(r'\bsource\b', line):
                        self._add_result(rel_path, "warning",
                                         f"Bashism: 'source' used (use '.' instead) at line {i}", i)

    def _run_shellcheck(self, filepath, rel_path):
        """Run shellcheck and add results."""
        try:
            result = subprocess.run(
                ["shellcheck", "-f", "json", str(filepath)],
                capture_output=True, text=True
            )
            if result.returncode in (0, 1):
                import json
                data = json.loads(result.stdout)
                issues = []
                if isinstance(data, dict):
                    issues = data.get("comments", []) or data.get("issues", [])
                elif isinstance(data, list):
                    issues = data

                # Recursive extraction for nested structures
                def extract_all(obj):
                    if isinstance(obj, dict):
                        if "level" in obj and "message" in obj:
                            yield obj
                        for v in obj.values():
                            yield from extract_all(v)
                    elif isinstance(obj, list):
                        for item in obj:
                            yield from extract_all(item)

                if not issues:
                    issues = list(extract_all(data))

                for issue in issues:
                    if not isinstance(issue, dict):
                        continue
                    severity = issue.get("level", "warning")
                    if severity in ("error", "warning"):
                        self._add_result(
                            rel_path,
                            severity,
                            f"[shellcheck] {issue.get('message', '')} (SC{issue.get('code', '')})",
                            issue.get("line")
                        )
        except FileNotFoundError:
            self._add_result(rel_path, "warning",
                             "shellcheck not installed; skipping", None)
        except Exception as e:
            self._add_result(rel_path, "warning",
                             f"shellcheck error: {e}", None)

# ------------------------------------------------------------------------------
# Main functions
# ------------------------------------------------------------------------------
def find_scripts(base_dir, dirs, exclude=None):
    """Find .sh files in the given directories."""
    scripts = []
    exclude = exclude or []
    for d in dirs:
        target = Path(base_dir) / d
        if target.exists():
            for f in target.rglob("*.sh"):
                rel = str(f.relative_to(base_dir))
                if not any(ex in str(f) for ex in exclude):
                    scripts.append((f, rel))
    return scripts

def main():
    parser = argparse.ArgumentParser(
        description="Check shell scripts for LFS compatibility."
    )
    parser.add_argument("--dirs", nargs="+", default=DEFAULT_DIRS,
                        help="Directories to analyze (default: host lfs blfs final)")
    parser.add_argument("--exclude", nargs="+", default=[],
                        help="Exclude subdirectories (e.g., blfs/apps)")
    parser.add_argument("--shellcheck", action="store_true",
                        help="Also run shellcheck (if installed)")
    parser.add_argument("--verbose", action="store_true",
                        help="Show more details")
    parser.add_argument("--base", default=".",
                        help="Project root directory (default: .)")
    args = parser.parse_args()

    base = Path(args.base).resolve()
    scripts = find_scripts(base, args.dirs, args.exclude)

    if not scripts:
        print("No .sh scripts found in the specified directories.")
        return

    print(f"Analyzing {len(scripts)} scripts...")
    checker = ScriptChecker(verbose=args.verbose, use_shellcheck=args.shellcheck)

    total_errors = 0
    total_warnings = 0
    for filepath, rel_path in scripts:
        results = checker.check_file(filepath, rel_path)
        if results:
            print(f"\n{rel_path}")
            for r in results:
                sev = r["severity"]
                line_info = f" (line {r['line']})" if r["line"] else ""
                print(f"  {sev.upper()}: {r['message']}{line_info}")
                if sev == "error":
                    total_errors += 1
                else:
                    total_warnings += 1

    print(f"\nReport complete: {total_errors} error(s), {total_warnings} warning(s).")

if __name__ == "__main__":
    main()