#!/usr/bin/env python3
"""Keep the ColorOS 16 inspiration-AOD feature enabled on ported devices.

ColorOS 16.1 added a Settings.Secure capability check named
``oplus_keyguard_workshop_aod_support``.  The port's target base does not
seed that per-user setting, so the AOD/Wallpapers feature predicates return
false even though all of the inspiration resources are present.

This patch deliberately changes only the result read from that capability
check.  The separate ``inspiration_aod.disable`` feature check remains in
the original method, so an explicit product disable still wins.  Matching is
based on the setting string and the Settings.Secure getInt call rather than
obfuscated class names, which keeps the patch usable across A16 APK builds.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


SETTING_KEY = "oplus_keyguard_workshop_aod_support"
SECURE_GET_INT_MARKERS = (
    # Wallpapers calls Settings.Secure directly.
    "Landroid/provider/Settings$Secure;->getInt",
    # A16 AOD wraps the same call in its small K2/a$a settings helper.  Keep
    # this signature-specific fallback instead of depending on the obfuscated
    # helper class name.
    "->b(Landroid/content/ContentResolver;Ljava/lang/String;I)I",
)
MOVE_RESULT_RE = re.compile(r"^(?P<indent>\s*)move-result(?:-wide)?\s+(?P<reg>[vp]\d+)\s*$")
METHOD_RE = re.compile(r"^\.method\s+.*?\s(?P<name>[^\s(]+)\(")


def _method_name(header: str) -> str:
    match = METHOD_RE.match(header)
    return match.group("name") if match else "<unknown>"


def _patch_method(lines: list[str], start: int, end: int) -> tuple[list[str], bool]:
    """Patch one smali method and return its lines plus changed state."""

    method_lines = lines[start:end]
    method_text = "".join(method_lines)
    if SETTING_KEY not in method_text or not any(
        marker in method_text for marker in SECURE_GET_INT_MARKERS
    ):
        return method_lines, False

    # Find the move-result produced by Settings.Secure.getInt.  The next
    # instruction is still inside the original gate, so forcing this result
    # to one keeps all surrounding logic (including the explicit disable
    # feature check) intact.
    key_index = next(
        (index for index, line in enumerate(method_lines) if SETTING_KEY in line),
        None,
    )
    if key_index is None:
        return method_lines, False

    get_int_index = next(
        (
            index
            for index in range(key_index, len(method_lines))
            if any(marker in method_lines[index] for marker in SECURE_GET_INT_MARKERS)
        ),
        None,
    )
    if get_int_index is None:
        return method_lines, False

    result_index = None
    result_register = None
    for index in range(get_int_index + 1, len(method_lines)):
        match = MOVE_RESULT_RE.match(method_lines[index])
        if match:
            result_index = index
            result_register = match.group("reg")
            break
        # A second invoke before the result means this is not the expected
        # Settings.Secure.getInt sequence.
        if "invoke-" in method_lines[index] and "move-result" not in method_lines[index]:
            break

    if result_index is None or result_register is None:
        return method_lines, False

    following = method_lines[result_index + 1 : result_index + 3]
    if any(re.search(rf"const/4\s+{re.escape(result_register)},\s+0x1\s*$", line.strip()) for line in following):
        return method_lines, False

    indent = MOVE_RESULT_RE.match(method_lines[result_index]).group("indent")
    patch_line = (
        f"{indent}# romport: make the A16 workshop AOD capability available\n"
        f"{indent}const/4 {result_register}, 0x1\n"
    )
    patched = method_lines[: result_index + 1] + [patch_line] + method_lines[result_index + 1 :]
    return patched, True


def patch_file(path: Path) -> list[str]:
    """Patch matching methods in one smali file and return method names."""

    text = path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    patched_lines: list[str] = []
    patched_methods: list[str] = []
    method_start = None
    method_name = "<unknown>"
    cursor = 0

    for index, line in enumerate(lines):
        if line.startswith(".method "):
            if method_start is not None:
                # Nested/malformed method block; do not risk rewriting it.
                return []
            patched_lines.extend(lines[cursor:index])
            method_start = index
            method_name = _method_name(line.rstrip("\r\n"))
        if method_start is not None and line.startswith(".end method"):
            method_lines, changed = _patch_method(lines, method_start, index + 1)
            if changed:
                patched_methods.append(method_name)
            patched_lines.extend(method_lines)
            cursor = index + 1
            method_start = None

    # Smali files should always have balanced method blocks.  Leave malformed
    # or unexpected files untouched instead of truncating them.
    if method_start is not None:
        return []

    patched_lines.extend(lines[cursor:])

    if not patched_methods:
        return []

    path.write_text("".join(patched_lines), encoding="utf-8", newline="")
    return patched_methods


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {Path(sys.argv[0]).name} <smali-file-or-directory>", file=sys.stderr)
        return 2

    target = Path(sys.argv[1])
    if target.is_file():
        files = [target]
    elif target.is_dir():
        files = sorted(target.rglob("*.smali"))
    else:
        print(f"Target not found: {target}", file=sys.stderr)
        return 2

    changed = 0
    for path in files:
        methods = patch_file(path)
        for method in methods:
            changed += 1
            print(f"----> patched inspiration AOD gate in {path}: {method}")

    if changed == 0:
        print("----> no ColorOS 16 inspiration AOD gate found; refusing a silent no-op", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
