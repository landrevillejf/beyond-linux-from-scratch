#!/usr/bin/env python3
"""Scan the stage shell scripts and derive, per stage, the set of source
archive name-prefixes that stage actually builds.

Why this exists
---------------
``LFSBuilder.download_sources()`` historically downloaded the ENTIRE merged
LFS + BLFS wget-list (well over a thousand tarballs, including qt-everywhere-src
at ~1.5 GB and every KDE/GNOME release-service archive) for EVERY profile.  A
``minimal`` build has no business pulling the desktop universe, and on the
Ubuntu 26 GitHub runner image -- where ``/tmp`` became a 7.9 GB RAM-backed
tmpfs -- that unconditional download overflowed the disk and killed the nightly
(``[Errno 28] No space left on device``).

To scope downloads per profile we need to know which packages each stage builds.
The stage scripts are the single source of truth, but they reference packages
through several heterogeneous idioms:

  * ``run_build required|optional <name>``        (dispatch to build_<name>)
  * ``book_install <name> <build_commands_fn>``   (blfs/08a idiom)
  * ``build_pkg <name> ...`` / ``prep_src <name>`` / ``meson_build <name>``
  * literal ``find_archive <archive>`` / ``find_archive '<archive>-*.tar.*'``
  * ``for pkg in a b c; do run_build ... "$pkg"; done`` loops
  * an in-script ``archive_names()`` map (glib2 -> "glib2 glib", icu -> ...)

This scanner harvests every one of those idioms, then RESOLVES each candidate
token against the real archive filenames pinned in
``packages/stable/12.4/sources.list`` and ``packages/custom-sources.list``.
Resolution against the actual source lists is what makes the scan safe: prose
that happens to follow a verb (``build_pkg auto-detection.``, ``for dir in proc
sys dev``) matches no archive and is discarded, while a real package resolves to
its on-disk tarball prefix.  Anything that neither matches nor aliases is
reported so a human can add it to the alias map rather than silently losing a
source.

Outputs (committed, consumed by builder.py at build time):
  packages/stage-sources.json   { "<script path>": ["<archive prefix>", ...] }
  packages/source-aliases.json  { "<logical name>": ["<archive prefix>", ...] }

Usage:
  python3 tools/scan-stage-sources.py            # regenerate both manifests
  python3 tools/scan-stage-sources.py --check    # exit 1 if manifests are stale
"""

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

# Reuse builder.py's own on-disk naming so a /archive/refs/tags/ URL resolves
# to the same repo-prefixed filename the downloader actually writes (e.g.
# linux-audit/audit-userspace/.../v4.2.1.tar.gz -> audit-userspace-v4.2.1.tar.gz).
from builder import _archive_filename  # noqa: E402

STAGE_DIRS = ("host", "lfs", "blfs", "final")

SOURCE_LISTS = (
    REPO_ROOT / "packages" / "stable" / "12.4" / "sources.list",
    REPO_ROOT / "packages" / "custom-sources.list",
)

STAGE_SOURCES_OUT = REPO_ROOT / "packages" / "stage-sources.json"
SOURCE_ALIASES_OUT = REPO_ROOT / "packages" / "source-aliases.json"

# Verbs whose first bare argument is a package/archive name.  run_build takes
# the name as its SECOND argument (run_build <mode> <name>), handled separately.
PKG_VERBS = ("book_install", "prep_src", "build_pkg", "meson_build",
             "install_tarball", "cmake_build", "autotools_build")

# A token that could plausibly be a package name (letters, digits, . _ + -).
_TOKEN_RE = r"[A-Za-z][A-Za-z0-9_.+-]*"

# run_build required|optional <name>   (name may be a literal or "$var")
_RUN_BUILD_RE = re.compile(
    r"\brun_build\s+(?:required|optional)\s+[\"']?(" + _TOKEN_RE + r")")
# <verb> <name>
_PKG_VERB_RE = re.compile(
    r"\b(?:" + "|".join(PKG_VERBS) + r")\s+[\"']?(" + _TOKEN_RE + r")")
# literal find_archive <name> / find_archive '<name>-*.tar.*'
_FIND_ARCHIVE_RE = re.compile(
    r"\bfind_archive\s+[\"']?(" + _TOKEN_RE + r")")
# for <var> in <items>; do   ...   done
_FOR_LOOP_RE = re.compile(r"\bfor\s+(\w+)\s+in\s+([^;\n]+);")
# require_file '<glob>'  (blfs/12 java-dev, blfs/30 lg3d idiom).  The glob's
# literal prefix before the first metacharacter is the package name; a glob
# with no metacharacter ('jenkins.war', 'kubectl') is a literal filename.
_REQUIRE_FILE_RE = re.compile(r"\brequire_file\s+[\"']([^\"']+)[\"']")
# ls <name>-*.tar.*  (conditional stages locate their tarball this way, e.g.
# blfs/32 `ls fail2ban-*.tar.gz`, blfs/16 `ls wireguard-tools-*.tar.xz`).
_LS_GLOB_RE = re.compile(r"\bls\s+[\"']?(" + _TOKEN_RE + r")-\*")
# First shell-glob metacharacter, used to cut a require_file pattern's prefix.
_GLOB_META_RE = re.compile(r"[*?[]")


def _glob_prefix(glob):
    """Return the literal package-name prefix of a require_file glob."""
    cut = _GLOB_META_RE.search(glob)
    return glob[:cut.start()] if cut else glob


def _norm(name):
    """Fold an archive name or token to a comparable form."""
    return name.lower().replace("_", "-")


def _load_archive_filenames():
    """Return the normalized on-disk filenames pinned in the committed lists."""
    names = set()
    for path in SOURCE_LISTS:
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            names.add(_norm(_archive_filename(line)))
    return names


def _matches_archive(token, archive_names):
    """True when *token* is the name (or a name-prefix) of a pinned archive.

    Matching requires a package boundary right after the token -- a ``-``, a
    ``.``, a digit (upstreams that glue the version onto the name, e.g.
    ``lynx2.9.2``, ``tcl8.6.16-src``) or end of name -- so ``exo`` never
    resolves to ``exotic`` while ``glib`` still resolves to ``glib-2.84.4.tar.xz``
    (and harmlessly over-matches ``glib-networking``: over-keeping is safe,
    under-keeping aborts a build).
    """
    tok = _norm(token)
    for name in archive_names:
        if name == tok or name.startswith(tok):
            rest = name[len(tok):]
            if not rest or rest[0] in "-." or rest[0].isdigit():
                return True
    return False


def _harvest_archive_names_map(text):
    """Parse an in-script archive_names() case block into {logical: [forms]}.

    blfs/08a maps a package name to the tarball base names to try, e.g.
    ``glib2) echo "glib2 glib" ;;``.  Every form is a candidate archive prefix.
    """
    aliases = {}
    m = re.search(r"\barchive_names\s*\(\)\s*\{(.*?)\n\}", text, re.DOTALL)
    if not m:
        return aliases
    body = m.group(1)
    for case in re.finditer(
            r"([A-Za-z0-9_.+-]+)\)\s*echo\s+\"([^\"]+)\"", body):
        logical = case.group(1)
        forms = case.group(2).split()
        aliases[logical] = forms
    return aliases


def _for_loop_items(text):
    """Yield (var, [items]) for loops whose body feeds a build verb.

    Only loops that pass "$var" to a build verb (or call "build_$var") are
    package loops; this skips ``for dir in proc sys dev`` and friends.
    """
    for m in _FOR_LOOP_RE.finditer(text):
        var = m.group(1)
        items = m.group(2).split()
        # Inspect the loop body up to the next 'done'.
        body = text[m.end():]
        done = re.search(r"\bdone\b", body)
        if done:
            body = body[:done.start()]
        uses_var = re.search(
            r"(?:run_build|book_install|build_pkg|prep_src|meson_build|"
            r"install_tarball)\b[^\n]*\$" + re.escape(var) + r"\b", body)
        calls_build_fn = re.search(r"\"?build_\$" + re.escape(var) + r"\b", body)
        if uses_var or calls_build_fn:
            yield var, [i for i in items if re.fullmatch(_TOKEN_RE, i)]


def _strip_comments(text):
    """Drop full-line shell comments so prose in them is not harvested.

    Only whole-line comments are removed; inline ``#`` is left alone because
    stripping it would corrupt ``case`` arms and quoted strings.
    """
    kept = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        kept.append(line)
    return "\n".join(kept)


# Tokens that only ever appear as the trailing word of a log message or a
# comment fragment (``find_archive found nothing``, ``build_pkg fallback``).
# They match no archive, so they are harmless, but dropping them keeps the
# committed manifest readable.
_PROSE_TOKENS = frozenset({
    "found", "fallback", "documents", "captures", "resolves", "skips",
    "used", "would", "can", "no-op", "no-ops", "auto-detection",
})


def _extract_tokens(text):
    """Harvest every candidate package token referenced by one stage script."""
    text = _strip_comments(text)
    tokens = set()

    for m in _RUN_BUILD_RE.finditer(text):
        tokens.add(m.group(1))
    for m in _PKG_VERB_RE.finditer(text):
        tokens.add(m.group(1))
    for m in _FIND_ARCHIVE_RE.finditer(text):
        tokens.add(m.group(1))
    for m in _REQUIRE_FILE_RE.finditer(text):
        prefix = _glob_prefix(m.group(1))
        if prefix:
            tokens.add(prefix)
    for m in _LS_GLOB_RE.finditer(text):
        tokens.add(m.group(1))
    for _var, items in _for_loop_items(text):
        tokens.update(items)

    # Drop shell variables, sentence fragments and obvious non-packages.
    cleaned = set()
    for tok in tokens:
        if tok.startswith("$"):
            continue
        # find_archive/require_file glob captures keep a trailing separator
        # ('firefox-*.tar.*' -> 'firefox-', 'OpenJDK21U-jdk_*' ->
        # 'OpenJDK21U-jdk_'); strip it so it dedupes against the clean name.
        tok = tok.rstrip("-._")
        if not tok or tok in _PROSE_TOKENS:
            continue
        cleaned.add(tok)
    return cleaned


def _resolve(tokens, archive_names, alias_map):
    """Report which tokens match a committed archive (informational only).

    Returns (resolved, unresolved).  The manifest keeps the RAW tokens, not
    the resolved subset, because packages/stable/12.4/sources.list is only a
    curated subset of the live BLFS wget-list: a real package (karchive,
    plasma-desktop) can be absent from the subset yet fetched at build time,
    where builder.py matches the raw token against the live merged list.
    """
    resolved = set()
    unresolved = set()
    for tok in sorted(tokens):
        if _matches_archive(tok, archive_names):
            resolved.add(tok)
            continue
        forms = alias_map.get(tok)
        if forms and any(_matches_archive(f, archive_names) for f in forms):
            resolved.add(tok)
        else:
            unresolved.add(tok)
    return resolved, unresolved


def scan(check=False):
    archive_names = _load_archive_filenames()
    if not archive_names:
        print("ERROR: no archive filenames found in the committed source lists",
              file=sys.stderr)
        return 2

    # Global alias map: seed with every script's archive_names() block plus a
    # few cross-script logical->archive exceptions the scanner cannot infer.
    alias_map = {
        # blfs/29 build_qt6() does `find_archive qt-everywhere-src`.
        "qt6": ["qt-everywhere-src"],
        "qtwebengine": ["qtwebengine-everywhere-src"],
        # blfs/08b builds the book's gtk3/gtk4 from the gtk-<series> tarballs.
        "gtk3": ["gtk"],
        "gtk4": ["gtk"],
        # libsoup3 -> libsoup-3.x; liburcu is published as userspace-rcu.
        "libsoup3": ["libsoup"],
        "liburcu": ["userspace-rcu"],
    }

    stage_sources = {}
    report_unresolved = {}

    for d in STAGE_DIRS:
        base = REPO_ROOT / d
        if not base.exists():
            continue
        for script in sorted(base.glob("*.sh")):
            text = script.read_text(encoding="utf-8", errors="replace")
            rel = f"{d}/{script.name}"
            script_aliases = _harvest_archive_names_map(text)
            for logical, forms in script_aliases.items():
                alias_map.setdefault(logical, forms)
            tokens = _extract_tokens(text)
            if not tokens:
                continue
            # The manifest keeps the RAW tokens; builder.py resolves them
            # against the live merged source list at build time (see
            # _resolve's docstring for why the subset cannot pre-resolve).
            stage_sources[rel] = sorted(tokens)
            _resolved, unresolved = _resolve(tokens, archive_names, alias_map)
            if unresolved:
                report_unresolved[rel] = sorted(unresolved)

    stage_doc = {
        "_comment": (
            "Per-stage package tokens harvested from the stage shell scripts by "
            "tools/scan-stage-sources.py.  When builder.py scopes downloads to a "
            "profile it keeps only the source archives whose name matches a token "
            "of one of that profile's active stages (expanded through "
            "source-aliases.json), plus the whole LFS core wget-list.  Tokens are "
            "resolved against the LIVE wget-lists at build time, not the curated "
            "packages/stable subset, so a token that names no committed archive is "
            "kept (it may still match a package the live BLFS list carries).  Do "
            "not edit by hand; re-run the scanner."),
        "stages": stage_sources,
    }
    alias_doc = {
        "_comment": (
            "Logical package name -> on-disk archive name-prefix(es), for the "
            "cases where the name a stage script builds under differs from the "
            "tarball basename.  Seeded with cross-script exceptions and merged "
            "with every script's in-file archive_names() map.  Generated by "
            "tools/scan-stage-sources.py."),
        "aliases": {k: sorted(set(alias_map[k])) for k in sorted(alias_map)},
    }

    if report_unresolved:
        print("Tokens that match no committed archive (kept as raw tokens; they "
              "may still resolve against the live BLFS wget-list):", file=sys.stderr)
        for rel in sorted(report_unresolved):
            print(f"  {rel}: {', '.join(report_unresolved[rel])}",
                  file=sys.stderr)

    new_stage = json.dumps(stage_doc, indent=2) + "\n"
    new_alias = json.dumps(alias_doc, indent=2) + "\n"

    if check:
        stale = []
        if not (STAGE_SOURCES_OUT.exists()
                and STAGE_SOURCES_OUT.read_text() == new_stage):
            stale.append(str(STAGE_SOURCES_OUT.relative_to(REPO_ROOT)))
        if not (SOURCE_ALIASES_OUT.exists()
                and SOURCE_ALIASES_OUT.read_text() == new_alias):
            stale.append(str(SOURCE_ALIASES_OUT.relative_to(REPO_ROOT)))
        if stale:
            print("stage-source manifests are stale: " + ", ".join(stale),
                  file=sys.stderr)
            return 1
        print("stage-source manifests are up to date")
        return 0

    STAGE_SOURCES_OUT.write_text(new_stage)
    SOURCE_ALIASES_OUT.write_text(new_alias)
    total = sum(len(v) for v in stage_sources.values())
    print(f"Wrote {STAGE_SOURCES_OUT.relative_to(REPO_ROOT)} "
          f"({len(stage_sources)} stages, {total} tokens) and "
          f"{SOURCE_ALIASES_OUT.relative_to(REPO_ROOT)} "
          f"({len(alias_map)} aliases)")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if the committed manifests are stale")
    args = ap.parse_args()
    return sys.exit(scan(check=args.check))


if __name__ == "__main__":
    main()
