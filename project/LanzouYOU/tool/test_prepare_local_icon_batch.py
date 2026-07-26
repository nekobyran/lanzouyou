from __future__ import annotations

import codecs
import io
import json
import random
import tempfile
import unittest
import zipfile
from pathlib import Path

from PIL import Image

import prepare_local_icon_batch as tool


def png_bytes(
    size: tuple[int, int] = (32, 32),
    *,
    noisy: bool = False,
    trailing_size: int | None = None,
) -> bytes:
    if noisy:
        payload = random.Random(20260713).randbytes(size[0] * size[1] * 4)
        image = Image.frombytes("RGBA", size, payload)
        compress_level = 0
    else:
        image = Image.new("RGBA", size, (20, 90, 180, 255))
        compress_level = 9
    output = io.BytesIO()
    image.save(output, format="PNG", optimize=False, compress_level=compress_level)
    raw = output.getvalue()
    if trailing_size is not None:
        if len(raw) >= trailing_size:
            raise AssertionError("fixture already exceeds requested boundary")
        raw += b"\0" * (trailing_size - len(raw))
    return raw


def favorite(
    marker: str,
    app: str,
    version: str,
    package: str,
    link: str,
) -> dict[str, object]:
    return {
        "customName": marker,
        "includeAppName": True,
        "includeVersion": True,
        "lastKnownAppName": app,
        "lastKnownVersion": version,
        "link": link,
        "packageName": package,
    }


def write_json(path: Path, favorites: list[dict[str, object]]) -> None:
    payload = {"schemaVersion": 1, "favorites": favorites}
    encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    path.write_bytes(codecs.BOM_UTF8 + encoded)


def write_zip(path: Path, members: list[tuple[str, bytes]]) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, raw in members:
            archive.writestr(name, raw)


class PrepareLocalIconBatchTests(unittest.TestCase):
    def test_utf8_sig_exact_mapping_safe_manifest_and_small_png_copy(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            json_path = root / "input.json"
            zip_path = root / "icons.zip"
            out = root / "prepared"
            first = png_bytes()
            second = png_bytes((40, 40))
            rows = [
                favorite("A", "Ａｌｐｈａ", "1.0", "org.example.alpha", "https://example.test/a"),
                favorite("B", "Beta", "2.0", "org.example.beta", "not-a-url"),
                favorite("C", "Gamma", "3.0", "org.example.gamma", ""),
            ]
            write_json(json_path, rows)
            write_zip(
                zip_path,
                [
                    ("A_Alpha_1.0.png", first),
                    ("B_Beta_2.0.png", second),
                    ("C_Gamma_3.0.png", first),
                ],
            )

            manifest = tool.prepare(json_path, zip_path, out)

            self.assertEqual(manifest["counts"]["json_entry_count"], 3)
            self.assertEqual(manifest["counts"]["mapped_count"], 3)
            self.assertEqual(manifest["counts"]["valid_http_link_count"], 1)
            self.assertEqual(manifest["counts"]["invalid_http_link_count"], 1)
            self.assertEqual(manifest["counts"]["missing_link_count"], 1)
            self.assertEqual(manifest["counts"]["copied_png_count"], 3)
            self.assertEqual(sum(manifest["ambiguities"].values()), 0)

            alpha_hash = tool.hash_unique_key(tool.normalize_unique_key("org.example.alpha"))
            self.assertEqual((out / "icons" / f"{alpha_hash}.png").read_bytes(), first)
            manifest_text = (out / "safe_manifest.json").read_text("ascii")
            for forbidden in (
                "Alpha",
                "Beta",
                "Gamma",
                "org.example",
                "example.test",
                "not-a-url",
            ):
                self.assertNotIn(forbidden, manifest_text)
            self.assertEqual(
                sorted(path.name for path in (out / "icons").iterdir()),
                sorted(f"{tool.hash_unique_key(tool.normalize_unique_key(row['packageName']))}.png" for row in rows),
            )

    def test_oversize_png_is_deterministic_and_strictly_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            json_path = root / "input.json"
            zip_path = root / "icons.zip"
            out_a = root / "prepared-a"
            out_b = root / "prepared-b"
            source = png_bytes((512, 512), noisy=True)
            self.assertGreaterEqual(len(source), tool.LIMIT_BYTES)
            row = favorite("X", "Noise", "9.1", "org.example.noise", "https://example.test/n")
            write_json(json_path, [row])
            write_zip(zip_path, [("X_Noise_9.1.png", source)])

            first_manifest = tool.prepare(json_path, zip_path, out_a)
            second_manifest = tool.prepare(json_path, zip_path, out_b)

            key_hash = tool.hash_unique_key(tool.normalize_unique_key("org.example.noise"))
            first = (out_a / "icons" / f"{key_hash}.png").read_bytes()
            second = (out_b / "icons" / f"{key_hash}.png").read_bytes()
            self.assertLess(len(first), tool.LIMIT_BYTES)
            self.assertEqual(first, second)
            self.assertEqual(first_manifest, second_manifest)
            self.assertEqual(first_manifest["counts"]["transformed_png_count"], 1)
            self.assertEqual(first_manifest["counts"]["source_oversize_png_count"], 1)

    def test_exact_limit_follows_transform_path_to_keep_less_than_invariant(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            json_path = root / "input.json"
            zip_path = root / "icons.zip"
            out = root / "prepared"
            source = png_bytes(trailing_size=tool.LIMIT_BYTES)
            write_json(
                json_path,
                [favorite("E", "Edge", "1", "org.example.edge", "https://example.test/e")],
            )
            write_zip(zip_path, [("E_Edge_1.png", source)])

            manifest = tool.prepare(json_path, zip_path, out)

            key_hash = tool.hash_unique_key(tool.normalize_unique_key("org.example.edge"))
            self.assertLess((out / "icons" / f"{key_hash}.png").stat().st_size, tool.LIMIT_BYTES)
            self.assertEqual(manifest["counts"]["transformed_png_count"], 1)

    def test_strict_links_fails_without_echoing_source_value(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            json_path = root / "input.json"
            zip_path = root / "icons.zip"
            write_json(
                json_path,
                [favorite("L", "Link", "1", "org.example.link", "private-invalid-value")],
            )
            write_zip(zip_path, [("L_Link_1.png", png_bytes())])

            with self.assertRaises(tool.PreparationError) as raised:
                tool.prepare(json_path, zip_path, root / "prepared", strict_links=True)

            self.assertEqual(raised.exception.code, "preflight_failed")
            self.assertNotIn("private-invalid-value", raised.exception.safe_message)

    def test_zip_traversal_is_rejected_without_member_name_in_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            zip_path = root / "icons.zip"
            write_zip(zip_path, [("../private-name.png", png_bytes())])

            with self.assertRaises(tool.PreparationError) as raised:
                tool.scan_archive(zip_path)

            self.assertEqual(raised.exception.code, "zip_unsafe_path")
            self.assertNotIn("private-name", raised.exception.safe_message)

    def test_analysis_reports_duplicate_stem_ambiguity_by_count_only(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            json_path = root / "input.json"
            zip_path = root / "icons.zip"
            write_json(
                json_path,
                [
                    favorite("D", "Same", "1", "org.example.one", "https://example.test/1"),
                    favorite("D", "Same", "1", "org.example.two", "https://example.test/2"),
                ],
            )
            write_zip(
                zip_path,
                [("one/D_Same_1.png", png_bytes()), ("two/D_Same_1.png", png_bytes())],
            )
            _, records = tool.load_records(json_path)
            _, icons, _ = tool.scan_archive(zip_path)

            result = tool.analyze(records, icons)

            self.assertEqual(result.ambiguities["ambiguous_entry_count"], 2)
            self.assertEqual(result.ambiguities["ambiguous_png_count"], 2)
            self.assertEqual(result.counts["mapped_count"], 0)


if __name__ == "__main__":
    unittest.main()
