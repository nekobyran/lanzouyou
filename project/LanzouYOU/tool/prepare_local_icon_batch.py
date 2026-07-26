#!/usr/bin/env python3
"""Prepare a privacy-safe local icon batch for LanzouYOU.

The tool never writes favorite names, package names, versions, links, or source
archive member names. Output PNG files are named with a domain-separated SHA-256
of the normalized package name. The manifest contains counts and hashes only.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tempfile
import unicodedata
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable
from urllib.parse import urlsplit

try:
    from PIL import Image, UnidentifiedImageError
except ImportError as exc:  # pragma: no cover - exercised only without Pillow
    raise SystemExit("error_code=pillow_missing") from exc


LIMIT_BYTES = 100 * 1024
MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_ZIP_BYTES = 128 * 1024 * 1024
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_MEMBER_BYTES = 32 * 1024 * 1024
MAX_IMAGE_PIXELS = 24_000_000
KEY_HASH_DOMAIN = b"LanzouYOU/local-icon-key/v1\0"
MAPPING_HASH_DOMAIN = b"LanzouYOU/local-icon-mapping/v1\0"
TREE_HASH_DOMAIN = b"LanzouYOU/local-icon-tree/v1\0"
REQUIRED_STRING_FIELDS = (
    "customName",
    "lastKnownAppName",
    "lastKnownVersion",
    "packageName",
    "link",
)


class PreparationError(Exception):
    """An error whose text is safe to show without leaking source values."""

    def __init__(self, code: str, safe_message: str | None = None) -> None:
        super().__init__(safe_message or code)
        self.code = code
        self.safe_message = safe_message or code


@dataclass(frozen=True)
class FavoriteRecord:
    key_hash: str
    expected_icon_stem: str
    link_state: str


@dataclass(frozen=True)
class ArchiveIcon:
    info: zipfile.ZipInfo
    normalized_stem: str


@dataclass(frozen=True)
class Analysis:
    records: tuple[FavoriteRecord, ...]
    icons: tuple[ArchiveIcon, ...]
    resolved: tuple[tuple[FavoriteRecord, ArchiveIcon], ...]
    counts: dict[str, int]
    ambiguities: dict[str, int]


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalize_text(value: str) -> str:
    return unicodedata.normalize("NFKC", value).strip().casefold()


def normalize_unique_key(value: str) -> str:
    normalized = normalize_text(value)
    if not normalized or any(unicodedata.category(ch).startswith("C") for ch in normalized):
        raise PreparationError("invalid_unique_key")
    return normalized


def hash_unique_key(normalized_key: str) -> str:
    return hashlib.sha256(KEY_HASH_DOMAIN + normalized_key.encode("utf-8")).hexdigest()


def classify_link(value: str) -> str:
    candidate = value.strip()
    if not candidate:
        return "missing"
    if any(ch.isspace() or unicodedata.category(ch).startswith("C") for ch in candidate):
        return "invalid"
    try:
        parsed = urlsplit(candidate)
        if parsed.scheme.casefold() not in {"http", "https"}:
            return "invalid"
        if not parsed.netloc or not parsed.hostname:
            return "invalid"
        if parsed.username is not None or parsed.password is not None:
            return "invalid"
        parsed.hostname.encode("idna")
        _ = parsed.port
    except (UnicodeError, ValueError):
        return "invalid"
    return "valid"


def _read_json(path: Path) -> tuple[bytes, list[dict[str, Any]]]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise PreparationError("json_read_failed") from exc
    if len(raw) > MAX_JSON_BYTES:
        raise PreparationError("json_too_large")
    try:
        payload = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PreparationError("json_parse_failed") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("favorites"), list):
        raise PreparationError("json_schema_invalid")
    favorites = payload["favorites"]
    if not all(isinstance(item, dict) for item in favorites):
        raise PreparationError("json_entry_invalid")
    return raw, favorites


def load_records(path: Path) -> tuple[bytes, tuple[FavoriteRecord, ...]]:
    raw, favorites = _read_json(path)
    records: list[FavoriteRecord] = []
    invalid_schema_count = 0
    for item in favorites:
        if any(not isinstance(item.get(field), str) for field in REQUIRED_STRING_FIELDS):
            invalid_schema_count += 1
            continue
        try:
            normalized_key = normalize_unique_key(item["packageName"])
        except PreparationError:
            invalid_schema_count += 1
            continue
        stem = "_".join(
            normalize_text(item[field])
            for field in ("customName", "lastKnownAppName", "lastKnownVersion")
        )
        if not stem:
            invalid_schema_count += 1
            continue
        records.append(
            FavoriteRecord(
                key_hash=hash_unique_key(normalized_key),
                expected_icon_stem=stem,
                link_state=classify_link(item["link"]),
            )
        )
    if invalid_schema_count:
        raise PreparationError(
            "json_entry_invalid", f"json_entry_invalid_count={invalid_schema_count}"
        )
    return raw, tuple(records)


def _member_path_is_safe(filename: str) -> bool:
    portable = filename.replace("\\", "/")
    pure = PurePosixPath(portable)
    return (
        not pure.is_absolute()
        and ".." not in pure.parts
        and not re.match(r"^[a-zA-Z]:", portable)
    )


def scan_archive(path: Path) -> tuple[bytes, tuple[ArchiveIcon, ...], dict[str, int]]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise PreparationError("zip_read_failed") from exc
    if len(raw) > MAX_ZIP_BYTES:
        raise PreparationError("zip_too_large")
    icons: list[ArchiveIcon] = []
    unsafe_paths = 0
    encrypted_files = 0
    non_png_files = 0
    total_uncompressed = 0
    try:
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            for info in archive.infolist():
                if info.is_dir():
                    continue
                total_uncompressed += info.file_size
                if not _member_path_is_safe(info.filename):
                    unsafe_paths += 1
                    continue
                if info.flag_bits & 0x1:
                    encrypted_files += 1
                    continue
                if info.file_size > MAX_MEMBER_BYTES:
                    raise PreparationError("zip_member_too_large")
                portable_name = PurePosixPath(info.filename.replace("\\", "/")).name
                if Path(portable_name).suffix.casefold() != ".png":
                    non_png_files += 1
                    continue
                icons.append(
                    ArchiveIcon(
                        info=info,
                        normalized_stem=normalize_text(Path(portable_name).stem),
                    )
                )
    except (OSError, zipfile.BadZipFile) as exc:
        raise PreparationError("zip_parse_failed") from exc
    if total_uncompressed > MAX_ARCHIVE_BYTES:
        raise PreparationError("zip_uncompressed_limit_exceeded")
    if unsafe_paths:
        raise PreparationError("zip_unsafe_path", f"zip_unsafe_path_count={unsafe_paths}")
    if encrypted_files:
        raise PreparationError(
            "zip_encrypted_member", f"zip_encrypted_member_count={encrypted_files}"
        )
    return raw, tuple(icons), {
        "zip_file_count": len(icons) + non_png_files,
        "png_count": len(icons),
        "non_png_count": non_png_files,
    }


def analyze(records: tuple[FavoriteRecord, ...], icons: tuple[ArchiveIcon, ...]) -> Analysis:
    entries_by_stem: dict[str, list[FavoriteRecord]] = defaultdict(list)
    icons_by_stem: dict[str, list[ArchiveIcon]] = defaultdict(list)
    keys: Counter[str] = Counter()
    for record in records:
        entries_by_stem[record.expected_icon_stem].append(record)
        keys[record.key_hash] += 1
    for icon in icons:
        icons_by_stem[icon.normalized_stem].append(icon)

    resolved: list[tuple[FavoriteRecord, ArchiveIcon]] = []
    ambiguous_entries = 0
    ambiguous_icons = 0
    unmatched_entries = 0
    unmatched_icons = 0
    all_stems = set(entries_by_stem) | set(icons_by_stem)
    for stem in all_stems:
        entry_group = entries_by_stem.get(stem, [])
        icon_group = icons_by_stem.get(stem, [])
        if len(entry_group) == 1 and len(icon_group) == 1:
            resolved.append((entry_group[0], icon_group[0]))
            continue
        if not icon_group:
            unmatched_entries += len(entry_group)
        elif not entry_group:
            unmatched_icons += len(icon_group)
        else:
            ambiguous_entries += len(entry_group)
            ambiguous_icons += len(icon_group)

    duplicate_key_entries = sum(count for count in keys.values() if count > 1)
    duplicate_key_groups = sum(1 for count in keys.values() if count > 1)
    link_counts = Counter(record.link_state for record in records)
    counts = {
        "json_entry_count": len(records),
        "unique_key_count": len(keys),
        "valid_http_link_count": link_counts["valid"],
        "invalid_http_link_count": link_counts["invalid"],
        "missing_link_count": link_counts["missing"],
        "png_count": len(icons),
        "mapped_count": len(resolved),
        "unmatched_entry_count": unmatched_entries,
        "unmatched_png_count": unmatched_icons,
    }
    ambiguities = {
        "duplicate_unique_key_group_count": duplicate_key_groups,
        "duplicate_unique_key_entry_count": duplicate_key_entries,
        "ambiguous_entry_count": ambiguous_entries,
        "ambiguous_png_count": ambiguous_icons,
    }
    resolved.sort(key=lambda pair: pair[0].key_hash)
    return Analysis(records, icons, tuple(resolved), counts, ambiguities)


def _validate_png(raw: bytes) -> tuple[int, int]:
    try:
        with Image.open(io.BytesIO(raw)) as image:
            if image.format != "PNG":
                raise PreparationError("image_not_png")
            width, height = image.size
            if width <= 0 or height <= 0 or width * height > MAX_IMAGE_PIXELS:
                raise PreparationError("image_dimensions_invalid")
            image.verify()
        with Image.open(io.BytesIO(raw)) as image:
            # Text chunks can contain private source metadata. Refuse rather than
            # silently copying it from an otherwise untouched small PNG.
            if getattr(image, "text", {}):
                raise PreparationError("png_text_metadata_present")
    except PreparationError:
        raise
    except (OSError, UnidentifiedImageError, Image.DecompressionBombError) as exc:
        raise PreparationError("png_decode_failed") from exc
    return width, height


def _encode_png(image: Image.Image, max_side: int | None, colors: int | None) -> bytes:
    working = image.convert("RGBA")
    if max_side is not None and max(working.size) > max_side:
        width, height = working.size
        scale = max_side / max(width, height)
        size = (max(1, round(width * scale)), max(1, round(height * scale)))
        working = working.resize(size, Image.Resampling.LANCZOS)
    if colors is not None:
        working = working.quantize(
            colors=colors,
            method=Image.Quantize.FASTOCTREE,
            dither=Image.Dither.NONE,
        )
    output = io.BytesIO()
    working.save(output, format="PNG", optimize=False, compress_level=9)
    return output.getvalue()


def compress_png_deterministically(raw: bytes) -> bytes:
    _validate_png(raw)
    try:
        with Image.open(io.BytesIO(raw)) as source:
            source.load()
            width, height = source.size
            lossless = _encode_png(source, None, None)
            if len(lossless) < LIMIT_BYTES:
                _validate_png(lossless)
                return lossless

            max_side = max(width, height)
            sides = [max_side]
            sides.extend(
                side
                for side in (1024, 768, 640, 512, 448, 384, 320, 288, 256, 224, 192, 160, 144, 128, 112, 96, 80, 64, 48, 32)
                if side < max_side
            )
            for side in sides:
                for colors in (256, 192, 128, 96, 64, 48, 32, 24, 16, 8):
                    candidate = _encode_png(source, side, colors)
                    if len(candidate) < LIMIT_BYTES:
                        _validate_png(candidate)
                        return candidate
    except PreparationError:
        raise
    except (OSError, UnidentifiedImageError, Image.DecompressionBombError) as exc:
        raise PreparationError("png_compression_failed") from exc
    raise PreparationError("png_cannot_meet_limit")


def _read_archive_member(archive: zipfile.ZipFile, info: zipfile.ZipInfo) -> bytes:
    try:
        return archive.read(info)
    except (OSError, RuntimeError, zipfile.BadZipFile, zipfile.LargeZipFile) as exc:
        raise PreparationError("zip_member_read_failed") from exc


def _mapping_hash(resolved: Iterable[tuple[FavoriteRecord, ArchiveIcon]], archive: zipfile.ZipFile) -> str:
    digest = hashlib.sha256(MAPPING_HASH_DOMAIN)
    rows: list[tuple[str, str]] = []
    for record, icon in resolved:
        raw = _read_archive_member(archive, icon.info)
        rows.append((record.key_hash, sha256_bytes(raw)))
    for key_hash, source_hash in sorted(rows):
        digest.update(key_hash.encode("ascii"))
        digest.update(b"\0")
        digest.update(source_hash.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def _tree_hash(rows: Iterable[tuple[str, str]]) -> str:
    digest = hashlib.sha256(TREE_HASH_DOMAIN)
    for key_hash, file_hash in sorted(rows):
        digest.update(key_hash.encode("ascii"))
        digest.update(b"\0")
        digest.update(file_hash.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    encoded = (json.dumps(payload, ensure_ascii=True, sort_keys=True, indent=2) + "\n").encode("ascii")
    path.write_bytes(encoded)


def prepare(
    json_path: Path,
    zip_path: Path,
    output_dir: Path,
    *,
    strict_links: bool = False,
) -> dict[str, Any]:
    json_raw, records = load_records(json_path)
    zip_raw, icons, archive_counts = scan_archive(zip_path)
    analysis = analyze(records, icons)

    failure_count = sum(analysis.ambiguities.values())
    failure_count += analysis.counts["unmatched_entry_count"]
    failure_count += analysis.counts["unmatched_png_count"]
    if strict_links:
        failure_count += analysis.counts["invalid_http_link_count"]
    if failure_count:
        raise PreparationError("preflight_failed", f"preflight_failure_count={failure_count}")
    if len(analysis.resolved) != len(records) or len(analysis.resolved) != len(icons):
        raise PreparationError("mapping_incomplete")

    output_dir = Path(os.path.abspath(output_dir))
    if output_dir.is_symlink():
        raise PreparationError("output_symlink_rejected")
    if output_dir.exists():
        if not output_dir.is_dir():
            raise PreparationError("output_not_directory")
        if any(output_dir.iterdir()):
            raise PreparationError("output_not_empty")
    output_dir.parent.mkdir(parents=True, exist_ok=True)

    stage_parent = output_dir.parent
    stage = Path(tempfile.mkdtemp(prefix=".lanzouyou-icon-prep-", dir=stage_parent))
    stage_output = stage / "prepared"
    icons_output = stage_output / "icons"
    icons_output.mkdir(parents=True)
    copied_count = 0
    transformed_count = 0
    source_oversize_count = 0
    output_rows: list[tuple[str, str]] = []
    try:
        with zipfile.ZipFile(io.BytesIO(zip_raw)) as archive:
            mapping_hash = _mapping_hash(analysis.resolved, archive)
            for record, icon in analysis.resolved:
                source = _read_archive_member(archive, icon.info)
                _validate_png(source)
                # The strict '< 100 KB' postcondition makes an exact-boundary
                # PNG unsafe too, so it follows the same deterministic path.
                if len(source) >= LIMIT_BYTES:
                    source_oversize_count += 1
                    prepared = compress_png_deterministically(source)
                    transformed_count += 1
                else:
                    prepared = source
                    copied_count += 1
                if len(prepared) >= LIMIT_BYTES:
                    raise PreparationError("output_png_limit_failed")
                _validate_png(prepared)
                destination = icons_output / f"{record.key_hash}.png"
                destination.write_bytes(prepared)
                output_rows.append((record.key_hash, sha256_bytes(prepared)))

        counts = dict(archive_counts)
        counts.update(analysis.counts)
        counts.update(
            {
                "source_oversize_png_count": source_oversize_count,
                "copied_png_count": copied_count,
                "transformed_png_count": transformed_count,
                "output_png_count": len(output_rows),
                "output_limit_failure_count": 0,
            }
        )
        manifest: dict[str, Any] = {
            "counts": dict(sorted(counts.items())),
            "hashes": {
                "input_json_sha256": sha256_bytes(json_raw),
                "input_zip_sha256": sha256_bytes(zip_raw),
                "mapping_sha256": mapping_hash,
                "output_tree_sha256": _tree_hash(output_rows),
            },
            "ambiguities": dict(sorted(analysis.ambiguities.items())),
        }
        _write_json(stage_output / "safe_manifest.json", manifest)

        if output_dir.exists():
            output_dir.rmdir()  # It was verified empty above.
        os.replace(stage_output, output_dir)
        return manifest
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    finally:
        if stage.exists():
            shutil.rmtree(stage, ignore_errors=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Prepare privacy-safe, deterministically bounded LanzouYOU icons."
    )
    parser.add_argument("--json", required=True, type=Path, help="UTF-8/UTF-8-sig favorites JSON")
    parser.add_argument("--icons-zip", required=True, type=Path, help="ZIP containing PNG icons")
    parser.add_argument("--output", required=True, type=Path, help="New or empty output directory")
    parser.add_argument(
        "--strict-links",
        action="store_true",
        help="Fail if any non-empty link is not an absolute HTTP(S) URL",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        manifest = prepare(
            args.json,
            args.icons_zip,
            args.output,
            strict_links=args.strict_links,
        )
    except PreparationError as exc:
        print(f"error_code={exc.code};{exc.safe_message}", file=sys.stderr)
        return 2
    except Exception:
        # Source values and member names must never appear in an unexpected
        # exception traceback. Keep the CLI failure deliberately generic.
        print("error_code=unexpected_failure", file=sys.stderr)
        return 3
    print(f"manifest={args.output.resolve() / 'safe_manifest.json'}")
    print(json.dumps(manifest, ensure_ascii=True, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
