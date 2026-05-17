#!/usr/bin/env python3
# Copyright (c) 2025-2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from __future__ import annotations

import argparse
import concurrent.futures
import difflib
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


WARNING_PREFIX = "Warning! Running debug build."
UUID_RE = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
)
HEADER_RE = re.compile(r"^[A-Z][A-Z ]+:$")
ENTRY_RE = re.compile(r"^\s{2}(\S.*?)\s{2,}(.*)$")
ENTRY_KEY_ONLY_RE = re.compile(r"^\s{2}(\S.*?)\s*$")
DOC_COMMAND_HEADING_RE = re.compile(r"^###\s+`([^`]+)`\s*$")
DOC_SECTION_HEADING_RE = re.compile(r"^\*\*([^*]+)\*\*$")
DOC_BULLET_ENTRY_RE = re.compile(r"^\*\s+`([^`]+)`\s*:\s*(.*)$")
DOC_OPTION_SECTION_NAMES = {
    "options",
    "process options",
    "resource options",
    "management options",
    "registry options",
    "progress options",
}


@dataclass
class HelpData:
    command: str
    overview: str
    usage: str
    arguments: list[tuple[str, str]]
    options: list[tuple[str, str]]
    subcommands: list[tuple[str, str]]


@dataclass
class HelpFailure:
    command: str
    error: str


def run_help(cli: str, parts: list[str]) -> str:
    cmd = [cli, *parts, "--help"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        stderr = result.stderr.strip()
        raise RuntimeError(f"failed to run {' '.join(cmd)}: {stderr}")

    lines: list[str] = []
    for raw in result.stdout.splitlines():
        line = raw.rstrip()
        if not line:
            lines.append("")
            continue
        if line.startswith(WARNING_PREFIX):
            continue
        line = UUID_RE.sub("<generated-uuid>", line)
        lines.append(line)
    return "\n".join(lines).strip() + "\n"


def collect_help(cli: str, parts: list[str]) -> tuple[list[str], HelpData | None, HelpFailure | None]:
    try:
        help_text = run_help(cli, parts)
        parsed = parse_help(parts, help_text)
        return parts, parsed, None
    except RuntimeError as error:
        command = " ".join(["container", *parts]).strip()
        failure = HelpFailure(command=command, error=str(error))
        return parts, None, failure


def parse_entry_block(lines: list[str], start: int) -> tuple[list[tuple[str, str]], int]:
    entries: list[tuple[str, str]] = []
    key = ""
    value = ""
    idx = start

    while idx < len(lines):
        line = lines[idx]
        stripped = line.strip()

        if HEADER_RE.match(stripped):
            break

        if not stripped:
            idx += 1
            continue

        match = ENTRY_RE.match(line)
        key_only_match = ENTRY_KEY_ONLY_RE.match(line)
        if match:
            if key:
                entries.append((key, value.strip()))
            key = match.group(1).strip()
            value = match.group(2).strip()
        elif key_only_match:
            if key:
                entries.append((key, value.strip()))
            raw_key = key_only_match.group(1).strip()
            split_match = re.match(r"^(--\S+\s+<[^>]+>)\s+(.+)$", raw_key)
            if split_match is not None:
                key = split_match.group(1).strip()
                value = split_match.group(2).strip()
            else:
                key = raw_key
                value = ""
        elif key:
            value = f"{value} {stripped}".strip()

        idx += 1

    if key:
        entries.append((key, value.strip()))

    return entries, idx


def parse_help(parts: list[str], text: str) -> HelpData:
    lines = text.splitlines()
    overview = ""
    usage = ""
    arguments: list[tuple[str, str]] = []
    options: list[tuple[str, str]] = []
    subcommands: list[tuple[str, str]] = []

    idx = 0
    while idx < len(lines):
        stripped = lines[idx].strip()

        if stripped.startswith("OVERVIEW:"):
            overview = stripped.removeprefix("OVERVIEW:").strip()
            idx += 1
            continue

        if stripped.startswith("USAGE:"):
            usage = stripped.removeprefix("USAGE:").strip()
            idx += 1
            continue

        if stripped == "ARGUMENTS:":
            arguments, idx = parse_entry_block(lines, idx + 1)
            continue

        if stripped.endswith("OPTIONS:"):
            block_options, idx = parse_entry_block(lines, idx + 1)
            options.extend(block_options)
            continue

        if stripped.endswith("SUBCOMMANDS:"):
            raw_subcommands, idx = parse_entry_block(lines, idx + 1)
            parsed_subcommands: list[tuple[str, str]] = []
            for names, desc in raw_subcommands:
                if names.startswith("See 'container help"):
                    continue
                primary = names.split(",")[0].strip()
                if primary == "":
                    continue
                parsed_subcommands.append((primary, desc))
            subcommands.extend(parsed_subcommands)
            continue

        idx += 1

    command = " ".join(["container", *parts]).strip()
    return HelpData(
        command=command,
        overview=overview,
        usage=usage,
        arguments=arguments,
        options=options,
        subcommands=subcommands,
    )


def discover_commands(cli: str, jobs: int) -> tuple[list[HelpData], list[HelpFailure]]:
    queue: list[list[str]] = [[]]
    visited: set[tuple[str, ...]] = set()
    result: list[HelpData] = []
    failures: list[HelpFailure] = []

    while queue:
        current_level: list[list[str]] = []
        next_queue: list[list[str]] = []

        for parts in queue:
            key = tuple(parts)
            if key in visited:
                continue
            visited.add(key)
            current_level.append(parts)

        if not current_level:
            queue = next_queue
            continue

        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as executor:
            futures = [executor.submit(collect_help, cli, parts) for parts in current_level]

            for future in concurrent.futures.as_completed(futures):
                parts, parsed, failure = future.result()

                if failure is not None:
                    failures.append(failure)
                    continue

                if parsed is None:
                    continue

                result.append(parsed)
                for subcommand, _ in parsed.subcommands:
                    next_queue.append([*parts, subcommand])

        queue = next_queue

    result.sort(key=lambda item: item.command)
    failures.sort(key=lambda item: item.command)
    return result, failures


def canonicalize_doc_command(command: str) -> str:
    return re.sub(r"\s+\([^)]*\)$", "", command).strip()


def normalize_usage_line(usage: str) -> str:
    return re.sub(r"\s+", " ", usage.strip())


def normalize_entry_key(key: str) -> str:
    normalized = re.sub(r"\s+", " ", key.strip())
    # Some wrapped help outputs may leak part of the description into the key.
    # Keep canonical key forms like `--flag <value>` or plain `--flag`.
    arg_match = re.match(r"^(--\S+\s+<[^>]+>)\b.*$", normalized)
    if arg_match is not None:
        return arg_match.group(1)
    flag_match = re.match(r"^(--\S+)\b.*$", normalized)
    if flag_match is not None:
        return flag_match.group(1)
    short_match = re.match(r"^(-\S+,\s+--\S+(?:\s+<[^>]+>)?)\b.*$", normalized)
    if short_match is not None:
        return short_match.group(1)
    return normalized


def normalize_entry_desc(desc: str) -> str:
    return re.sub(r"\s+", " ", desc.strip())


def is_doc_option_section(section: str) -> bool:
    normalized = section.strip().lower()
    if normalized in DOC_OPTION_SECTION_NAMES:
        return True
    return normalized.endswith("options")


def parse_doc_usage_blocks(reference_file: str) -> dict[str, str]:
    lines = Path(reference_file).read_text(encoding="utf-8").splitlines()
    usages: dict[str, str] = {}
    idx = 0

    while idx < len(lines):
        heading_match = DOC_COMMAND_HEADING_RE.match(lines[idx])
        if heading_match is None:
            idx += 1
            continue

        command = canonicalize_doc_command(heading_match.group(1))
        idx += 1

        usage_found = False
        while idx < len(lines):
            line = lines[idx]

            if line.startswith("### "):
                break

            if line.strip() == "**Usage**":
                idx += 1
                while idx < len(lines) and lines[idx].strip() == "":
                    idx += 1

                if idx >= len(lines) or not lines[idx].startswith("```"):
                    break

                idx += 1
                block_lines: list[str] = []
                while idx < len(lines) and not lines[idx].startswith("```"):
                    block_lines.append(lines[idx].strip())
                    idx += 1

                if idx < len(lines) and lines[idx].startswith("```"):
                    idx += 1

                usage_value = " ".join(part for part in block_lines if part)
                if usage_value:
                    usages[command] = usage_value
                    usage_found = True
                break

            idx += 1

        if not usage_found:
            continue

    return usages


def parse_doc_command_blocks(reference_file: str) -> dict[str, dict[str, list[tuple[str, str]]]]:
    lines = Path(reference_file).read_text(encoding="utf-8").splitlines()
    blocks: dict[str, dict[str, list[tuple[str, str]]]] = {}

    idx = 0
    while idx < len(lines):
        heading_match = DOC_COMMAND_HEADING_RE.match(lines[idx])
        if heading_match is None:
            idx += 1
            continue

        command = canonicalize_doc_command(heading_match.group(1))
        idx += 1
        current_section = ""
        arguments: list[tuple[str, str]] = []
        options: list[tuple[str, str]] = []

        while idx < len(lines):
            line = lines[idx]

            if line.startswith("### "):
                break

            section_match = DOC_SECTION_HEADING_RE.match(line.strip())
            if section_match is not None:
                current_section = section_match.group(1).strip()
                idx += 1
                continue

            bullet_match = DOC_BULLET_ENTRY_RE.match(line.strip())
            if bullet_match is not None:
                key = normalize_entry_key(bullet_match.group(1))
                desc = normalize_entry_desc(bullet_match.group(2))

                if current_section.strip().lower() == "arguments" and key.startswith("<"):
                    arguments.append((key, desc))
                elif is_doc_option_section(current_section) and key.startswith("-"):
                    options.append((key, desc))

            idx += 1

        blocks[command] = {"arguments": arguments, "options": options}

    return blocks


def entries_to_map(entries: list[tuple[str, str]], expand_combined_keys: bool = False) -> dict[str, str]:
    mapped: dict[str, str] = {}
    for key, desc in entries:
        normalized_key = normalize_entry_key(key)
        normalized_desc = normalize_entry_desc(desc)

        if expand_combined_keys and "/" in normalized_key:
            for part in normalized_key.split("/"):
                part_key = normalize_entry_key(part)
                if part_key:
                    mapped[part_key] = normalized_desc
            continue

        mapped[normalized_key] = normalized_desc
    return mapped


def compare_entry_maps(command: str, kind: str, doc_map: dict[str, str], cli_map: dict[str, str]) -> list[str]:
    messages: list[str] = []

    missing = sorted(key for key in cli_map if key not in doc_map)
    extra = sorted(key for key in doc_map if key not in cli_map)
    shared = sorted(key for key in doc_map if key in cli_map)

    for key in missing:
        messages.append(f"missing {kind} in docs: {command} :: {key}")

    for key in extra:
        messages.append(f"extra {kind} in docs: {command} :: {key}")

    for key in shared:
        if cli_map[key] == "":
            continue
        if doc_map[key] != cli_map[key]:
            diff = difflib.unified_diff(
                [doc_map[key] + "\n"],
                [cli_map[key] + "\n"],
                fromfile="docs/command-reference.md",
                tofile="container --help",
                lineterm="",
            )
            rendered = "\n".join(diff)
            messages.append(f"{kind} description drift: {command} :: {key}\n{rendered}")

    return messages


def lint_usage_against_reference(cli: str, reference_file: str, jobs: int) -> int:
    command_help, help_failures = discover_commands(cli, jobs)
    command_usage = {item.command: normalize_usage_line(item.usage) for item in command_help}
    command_data = {item.command: item for item in command_help}
    leaf_commands = {item.command for item in command_help if not item.subcommands}
    doc_usage = parse_doc_usage_blocks(reference_file)
    doc_blocks = parse_doc_command_blocks(reference_file)

    mismatches: list[tuple[str, str, str]] = []
    missing_in_cli: list[str] = []
    missing_in_docs: list[str] = []
    detail_mismatches: list[str] = []

    for command, documented_usage in doc_usage.items():
        normalized_documented = normalize_usage_line(documented_usage)

        if "<options>" in normalized_documented or "[<options>]" in normalized_documented:
            continue

        live_usage = command_usage.get(command)
        if live_usage is None:
            missing_in_cli.append(command)
            continue

        if normalized_documented != live_usage:
            mismatches.append((command, normalized_documented, live_usage))

    for command in sorted(leaf_commands):
        if command == "container":
            continue
        if command not in doc_usage:
            missing_in_docs.append(command)

    for command, sections in doc_blocks.items():
        live = command_data.get(command)
        if live is None:
            continue

        doc_arg_map = entries_to_map(sections["arguments"])
        live_arg_map = entries_to_map(live.arguments)
        detail_mismatches.extend(compare_entry_maps(command, "argument", doc_arg_map, live_arg_map))

        doc_opt_map = entries_to_map(sections["options"], expand_combined_keys=False)
        live_opt_entries = [
            (key, value)
            for (key, value) in live.options
            if "--version" not in key and "--help" not in key and "--debug" not in key
        ]
        live_opt_map = entries_to_map(live_opt_entries)
        detail_mismatches.extend(compare_entry_maps(command, "option", doc_opt_map, live_opt_map))

    missing_in_cli.sort()
    missing_in_docs.sort()
    mismatches.sort(key=lambda item: item[0])
    detail_mismatches.sort()

    if (
        not mismatches
        and not missing_in_cli
        and not missing_in_docs
        and not detail_mismatches
        and not help_failures
    ):
        print("command reference usage lint passed")
        return 0

    print("command reference usage lint failed")

    if help_failures:
        print("\n- failed to collect help for some commands:")
        for failure in help_failures:
            print(f"  * {failure.command}")
            print(f"    {failure.error}")

    if missing_in_cli:
        print("\n- commands documented but not found in CLI:")
        for command in missing_in_cli:
            print(f"  * {command}")

    if missing_in_docs:
        print("\n- commands present in CLI but missing from docs/command-reference.md:")
        for command in missing_in_docs:
            print(f"  * {command}")

    if mismatches:
        print("\n- usage drifts:")
        for command, documented, live in mismatches:
            print(f"\n  * {command}")
            diff = difflib.unified_diff(
                [documented + "\n"],
                [live + "\n"],
                fromfile="docs/command-reference.md",
                tofile="container --help",
                lineterm="",
            )
            for line in diff:
                print(line)

    if detail_mismatches:
        print("\n- arguments/options drifts:")
        for message in detail_mismatches:
            print(f"\n  * {message}")

    return 1


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Lint command reference usage blocks against container --help output."
    )
    parser.add_argument(
        "--cli",
        default="./bin/container",
        help="Path to container CLI binary (default: ./bin/container)",
    )
    parser.add_argument(
        "--lint-usage-against",
        default="docs/command-reference.md",
        help="Path to command reference markdown file to lint usage blocks against live CLI help",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=8,
        help="Maximum number of concurrent help commands to run while linting",
    )
    args = parser.parse_args()

    exit_code = lint_usage_against_reference(args.cli, args.lint_usage_against, args.jobs)
    sys.exit(exit_code)

if __name__ == "__main__":
    main()
