from __future__ import annotations

import contextlib
import io
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

import publish_lanzoumax as tool


class FakeCore:
    def __init__(self) -> None:
        self.primary_id = "folder-primary"
        self.library_id = "folder-library"
        self.root = [
            self._folder(self.primary_id, tool.PRIMARY_FOLDER),
            self._folder(self.library_id, tool.LIBRARY_FOLDER),
        ]
        self.active: dict[str, dict[str, object]] = {}
        self.recycle: dict[str, dict[str, object]] = {}
        self.calls: list[dict[str, object]] = []
        self._next_id = 100
        self.fail_rename_parent: str | None = None
        self.ambiguous_delete_id: str | None = None
        self.fail_restore_id: str | None = None
        self.fail_move_id: str | None = None
        self.ignore_move_id: str | None = None
        self.omit_list_icon_state = False
        self.list_name_override: str | None = None
        self.share_name_override: str | None = None
        self.ambiguous_folder_description_once = False
        self.ambiguous_upload_once = False
        self.ambiguous_file_description_once = False
        self.ambiguous_icon_once = False
        self.fail_download_id: str | None = None

    @staticmethod
    def _folder(identifier: str, name: str) -> dict[str, object]:
        return {
            "id": identifier,
            "name": name,
            "isFolder": True,
            "hasCustomIcon": False,
        }

    def add_file(
        self,
        parent: str,
        name: str,
        *,
        identifier: str | None = None,
        has_custom_icon: bool = False,
        description: str = "",
        content: bytes = b"fake-remote-payload",
    ) -> str:
        if identifier is None:
            identifier = f"file-{self._next_id}"
            self._next_id += 1
        self.active[identifier] = {
            "id": identifier,
            "name": name,
            "isFolder": False,
            "hasCustomIcon": has_custom_icon,
            "description": description,
            "parent": parent,
            "content": content,
        }
        return identifier

    def _record(self, command: dict[str, object]) -> None:
        # Fake credentials are intentionally not retained even in test traces.
        if command.get("op") == "login":
            self.calls.append({"op": "login"})
        else:
            self.calls.append(dict(command))

    def _public_item(self, item: dict[str, object], *, recycle: bool = False) -> dict[str, object]:
        public = {
            "id": item["id"],
            "name": item["name"],
            "isFolder": item["isFolder"],
            "isRecycle": recycle,
        }
        if "hasCustomIcon" in item:
            public["hasCustomIcon"] = item["hasCustomIcon"]
        if "description" in item:
            public["description"] = item["description"]
        return public

    def _find_active(self, identifier: object) -> dict[str, object]:
        if not isinstance(identifier, str) or identifier not in self.active:
            raise tool.PublishError("fake_not_found")
        return self.active[identifier]

    def _find_item(self, identifier: object) -> dict[str, object]:
        if isinstance(identifier, str):
            for item in self.root:
                if item["id"] == identifier:
                    return item
        return self._find_active(identifier)

    def call(self, command: dict[str, object]) -> dict[str, object]:
        self._record(command)
        operation = command.get("op")
        if operation == "login":
            return {"cookie": "fake-cookie-must-never-be-printed", "authenticated": True}
        if operation == "list":
            folder_id = command.get("folderId")
            if folder_id == tool.ROOT_ID:
                items = [dict(item) for item in self.root]
            else:
                items = [
                    self._public_item(item)
                    for item in self.active.values()
                    if item["parent"] == folder_id
                ]
            if self.omit_list_icon_state:
                for item in items:
                    if item.get("isFolder") is False:
                        item.pop("hasCustomIcon", None)
            if self.list_name_override is not None:
                for item in items:
                    if item.get("isFolder") is False:
                        item["name"] = self.list_name_override
            return {
                "items": items,
                "page": command.get("page", 1),
                "pageSize": 200,
                "hasMore": False,
            }
        if operation == "upload":
            name = Path(str(command["path"])).name
            identifier = self.add_file(
                str(command["folderId"]),
                name,
                content=Path(str(command["path"])).read_bytes(),
            )
            if self.ambiguous_upload_once:
                self.ambiguous_upload_once = False
                raise tool.PublishError("core_ambiguous_result")
            return {
                "id": identifier,
                "folderId": command["folderId"],
                "originalName": name,
                "uploadedName": name,
            }
        if operation == "download":
            item = self._find_active(command.get("id"))
            destination = Path(str(command["destination"]))
            destination.parent.mkdir(parents=True, exist_ok=True)
            if str(item["id"]) == self.fail_download_id:
                destination.write_bytes(b"partial-readback")
                raise tool.PublishError("injected_download_failure")
            content = bytes(item.get("content") or b"")
            destination.write_bytes(content)
            return {
                "id": item["id"],
                "path": str(destination),
                "bytesDownloaded": len(content),
                "bytesWritten": len(content),
                "compatUnwrapped": False,
                "originalName": None,
                "directUrlResolved": True,
            }
        if operation == "set_description":
            item = self._find_item(command.get("id"))
            item["description"] = command.get("description")
            if item.get("isFolder") is True and self.ambiguous_folder_description_once:
                self.ambiguous_folder_description_once = False
                raise tool.PublishError("core_ambiguous_result")
            if item.get("isFolder") is False and self.ambiguous_file_description_once:
                self.ambiguous_file_description_once = False
                raise tool.PublishError("core_ambiguous_result")
            return {}
        if operation == "set_icon":
            item = self._find_active(command.get("fileId"))
            item["hasCustomIcon"] = True
            if self.ambiguous_icon_once:
                self.ambiguous_icon_once = False
                raise tool.PublishError("core_ambiguous_result")
            return {"fileId": item["id"]}
        if operation == "share_info":
            item = self._find_item(command.get("id"))
            is_folder = bool(item.get("isFolder"))
            return {
                "id": item["id"],
                "isFolder": is_folder,
                "name": (
                    self.share_name_override
                    if self.share_name_override is not None
                    else item["name"]
                ),
                "description": item.get("description", ""),
                "shareUrl": "https://example.invalid/private-test-file",
                "password": "",
                "directUrl": None,
            }
        if operation == "delete":
            item = self._find_active(command.get("id"))
            identifier = str(item["id"])
            self.recycle[identifier] = self.active.pop(identifier)
            if identifier == self.ambiguous_delete_id:
                self.ambiguous_delete_id = None
                raise tool.PublishError("injected_ambiguous_delete")
            return {"inRecycle": True}
        if operation == "rename":
            item = self._find_active(command.get("id"))
            if item["parent"] == self.fail_rename_parent:
                raise tool.PublishError("injected_rename_failure")
            item["name"] = command.get("name")
            return {}
        if operation == "recycle_list":
            return {
                "items": [
                    self._public_item(item, recycle=True)
                    for item in self.recycle.values()
                ]
            }
        if operation == "recycle_restore":
            identifier = command.get("id")
            if not isinstance(identifier, str) or identifier not in self.recycle:
                raise tool.PublishError("fake_recycle_not_found")
            if identifier == self.fail_restore_id:
                raise tool.PublishError("injected_restore_failure")
            restored = self.recycle.pop(identifier)
            restored["parent"] = tool.ROOT_ID
            self.active[identifier] = restored
            return {"restored": True}
        if operation == "move":
            item = self._find_active(command.get("id"))
            identifier = str(item["id"])
            if identifier == self.fail_move_id:
                raise tool.PublishError("injected_move_failure")
            if identifier != self.ignore_move_id:
                item["parent"] = command.get("targetId")
            return {
                "id": identifier,
                "isFolder": False,
                "targetId": command.get("targetId"),
            }
        if operation in {"recycle_purge", "recycle_empty"}:
            raise AssertionError("destructive recycle operation must never be called")
        raise AssertionError(f"unsupported fake operation: {operation}")


class EventuallyConsistentFakeCore(FakeCore):
    """Model independent list/share metadata caches lagging behind mutations."""

    def __init__(self, stale_reads: int) -> None:
        super().__init__()
        self.stale_reads = stale_reads
        self._stale_icons: dict[str, list[object]] = {}
        self._stale_descriptions: dict[str, list[object]] = {}
        self._stale_names: dict[str, dict[str, object]] = {}

    @staticmethod
    def _take_stale(state: list[object] | None) -> object | None:
        if state is None or int(state[1]) <= 0:
            return None
        state[1] = int(state[1]) - 1
        return state[0]

    def call(self, command: dict[str, object]) -> dict[str, object]:
        operation = command.get("op")
        if operation == "set_description":
            item = self._find_item(command.get("id"))
            previous = item.get("description", "")
            result = super().call(command)
            self._stale_descriptions[str(item["id"])] = [
                previous,
                self.stale_reads,
            ]
            return result
        if operation == "set_icon":
            item = self._find_active(command.get("fileId"))
            previous = item.get("hasCustomIcon", False)
            result = super().call(command)
            self._stale_icons[str(item["id"])] = [previous, self.stale_reads]
            return result
        if operation == "rename":
            item = self._find_active(command.get("id"))
            previous = item["name"]
            result = super().call(command)
            self._stale_names[str(item["id"])] = {
                "value": previous,
                "list": self.stale_reads,
                "share": self.stale_reads,
            }
            return result

        result = super().call(command)
        if operation == "list":
            for raw in result["items"]:
                if raw.get("isFolder") is True:
                    continue
                identifier = str(raw["id"])
                # The real task-5 file listing does not reliably expose the
                # per-file description, so exact description verification must
                # use the read-only share metadata endpoint instead.
                raw.pop("description", None)
                stale_icon = self._take_stale(self._stale_icons.get(identifier))
                if stale_icon is not None:
                    raw["hasCustomIcon"] = stale_icon
                stale_name = self._stale_names.get(identifier)
                if stale_name is not None and int(stale_name["list"]) > 0:
                    stale_name["list"] = int(stale_name["list"]) - 1
                    raw["name"] = stale_name["value"]
        elif operation == "share_info":
            identifier = str(result["id"])
            stale_description = self._take_stale(
                self._stale_descriptions.get(identifier)
            )
            if stale_description is not None:
                result["description"] = stale_description
            stale_name = self._stale_names.get(identifier)
            if stale_name is not None and int(stale_name["share"]) > 0:
                stale_name["share"] = int(stale_name["share"]) - 1
                result["name"] = stale_name["value"]
        return result


class DelayedDeleteFakeCore(FakeCore):
    """Keep deleted files visible in authenticated listings for bounded reads."""

    def __init__(self, stale_reads: int, *, never_clear: bool = False) -> None:
        super().__init__()
        self.stale_reads = stale_reads
        self.never_clear = never_clear
        self._listing_ghosts: dict[str, dict[str, object]] = {}

    def call(self, command: dict[str, object]) -> dict[str, object]:
        operation = command.get("op")
        if operation == "delete":
            item = dict(self._find_active(command.get("id")))
            result = super().call(command)
            self._listing_ghosts[str(item["id"])] = {
                "item": item,
                "remaining": self.stale_reads,
            }
            return result

        result = super().call(command)
        if operation == "list":
            folder_id = command.get("folderId")
            for ghost in self._listing_ghosts.values():
                item = ghost["item"]
                if item["parent"] != folder_id:
                    continue
                remaining = int(ghost["remaining"])
                if self.never_clear or remaining > 0:
                    result["items"].append(self._public_item(item))
                    if not self.never_clear:
                        ghost["remaining"] = remaining - 1
        return result

    def visible_ghost_count(self) -> int:
        return sum(
            self.never_clear or int(ghost["remaining"]) > 0
            for ghost in self._listing_ghosts.values()
        )


def cloud(identifier: str, name: str, *, folder: bool = False) -> tool.CloudItem:
    return tool.CloudItem(identifier, name, folder, False, "")


class PublishLanzouMaxTests(unittest.TestCase):
    VERSION = "1.2.3"
    TOKEN = "0123456789abcdef"

    def make_apk(self, root: Path) -> Path:
        apk = root / "source.apk"
        apk.write_bytes(b"fake-apk-payload")
        return apk

    def make_icon(self, root: Path) -> Path:
        icon = root / "app_icon.jpg"
        icon.write_bytes(b"\xff\xd8\xff\xe0fake-jpeg-payload\xff\xd9")
        return icon

    def populated_fake(self) -> tuple[FakeCore, dict[str, str]]:
        fake = FakeCore()
        identifiers = {
            "primary_old": fake.add_file(
                fake.primary_id,
                "LanzouMax0.9.0.apk",
                identifier="primary-old",
            ),
            "primary_alt_old": fake.add_file(
                fake.primary_id,
                "LANZHOUMAX0.8.0.apk",
                identifier="primary-alt-old",
            ),
            "library_old_a": fake.add_file(
                fake.library_id,
                "lanzoumax1.0.0.apk",
                identifier="library-old-a",
            ),
            "library_old_b": fake.add_file(
                fake.library_id,
                "LANZHOUMAX2.0.0-BETA.1.apk",
                identifier="library-old-b",
            ),
            "keep_prefix": fake.add_file(
                fake.library_id,
                "prefix-LanzouMax1.0.0.apk",
                identifier="library-keep-prefix",
            ),
            "keep_suffix": fake.add_file(
                fake.library_id,
                "LanzouMax1.0.0.apk.bak",
                identifier="library-keep-suffix",
            ),
            "keep_unrelated": fake.add_file(
                fake.primary_id,
                "private-unrelated.apk",
                identifier="primary-keep",
            ),
        }
        return fake, identifiers

    def publisher(self, fake: FakeCore, apk: Path) -> tool.Publisher:
        return tool.Publisher(
            fake,
            apk,
            self.make_icon(apk.parent),
            self.VERSION,
            token_factory=lambda: self.TOKEN,
        )

    def test_matchers_are_anchored_case_insensitive_and_primary_replaces_only_same_version(self) -> None:
        positives = (
            "LanzouMax1.apk",
            "lanzoumax1.2.3.apk",
            "LANZHOUMAX2.0.0-BETA.1.apk",
            "LanzouMax3.4+build.7.apk",
        )
        negatives = (
            "prefix-LanzouMax1.2.apk",
            "LanzouMax1.2.apk.bak",
            "LanzouMax.apk",
            "LanzouMax1.2.exe",
            "LanzouMax1.2.3 copy.apk",
        )
        for name in positives:
            self.assertTrue(tool.is_library_replacement(name), name)
        for name in negatives:
            self.assertFalse(tool.is_library_replacement(name), name)

        final_name = tool.final_apk_name(self.VERSION)
        items = [
            cloud("a", final_name),
            cloud("b", "LANZHOUMAX1.2.3.APK"),
            cloud("c", "LanzouMax1.2.4.apk"),
            cloud("d", final_name, folder=True),
            cloud("e", f"prefix-{final_name}"),
        ]
        self.assertEqual(
            [
                item.id
                for item in tool.select_replacement_candidates(
                    tool.PRIMARY_FOLDER, items, self.VERSION
                )
            ],
            ["a", "b"],
        )
        self.assertEqual(
            [
                item.id
                for item in tool.select_replacement_candidates(
                    tool.LIBRARY_FOLDER, items, self.VERSION
                )
            ],
            ["a", "b", "c"],
        )

    def test_success_archives_primary_history_and_replaces_only_library_candidates(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake, identifiers = self.populated_fake()
            apk = self.make_apk(root)
            icon = self.make_icon(root)
            source_icon_bytes = icon.read_bytes()
            publisher = tool.Publisher(
                fake,
                apk,
                icon,
                self.VERSION,
                token_factory=lambda: self.TOKEN,
            )
            publisher.authenticate("fake-user", "fake-password")

            summary = publisher.execute()
            set_icon_paths = [
                Path(str(call["path"]))
                for call in fake.calls
                if call["op"] == "set_icon"
            ]
            uploaded_icon_bytes = [path.read_bytes() for path in set_icon_paths]

        self.assertEqual(summary.target_count, 2)
        self.assertEqual(summary.candidate_count, 2)
        operations = [str(call["op"]) for call in fake.calls]
        self.assertNotIn("prepare_icon", operations)
        self.assertEqual(len(set_icon_paths), 2)
        self.assertEqual(set(set_icon_paths), {icon.resolve()})
        self.assertEqual(uploaded_icon_bytes, [source_icon_bytes, source_icon_bytes])
        self.assertEqual(operations.count("upload"), 2)
        self.assertEqual(operations.count("set_description"), 3)
        self.assertEqual(operations.count("set_icon"), 2)
        self.assertLess(max(i for i, op in enumerate(operations) if op == "set_icon"), operations.index("delete"))
        descriptions = [
            call["description"]
            for call in fake.calls
            if call["op"] == "set_description"
        ]
        self.assertEqual(tool.DESCRIPTION, "官网链接:https://lanzoumax.nkbr.cc/")
        self.assertEqual(
            descriptions,
            [
                tool.PRIMARY_FOLDER_DESCRIPTION,
                tool.DESCRIPTION,
                tool.DESCRIPTION,
            ],
        )
        self.assertNotIn("LanzouPlus", tool.PRIMARY_FOLDER_DESCRIPTION)
        self.assertNotIn("github.com", tool.PRIMARY_FOLDER_DESCRIPTION)
        self.assertNotIn("https://nkbr.cc/", tool.PRIMARY_FOLDER_DESCRIPTION)
        self.assertEqual(
            tool.PRIMARY_FOLDER_DESCRIPTION,
            "官网链接:https://lanzoumax.nkbr.cc/",
        )
        self.assertEqual(fake.root[0]["description"], tool.PRIMARY_FOLDER_DESCRIPTION)
        self.assertTrue(
            all(call["compatWrap"] is False and call["kind"] == "file" for call in fake.calls if call["op"] == "upload")
        )

        final_name = tool.final_apk_name(self.VERSION)
        for folder_id in (fake.primary_id, fake.library_id):
            published = [
                item
                for item in fake.active.values()
                if item["parent"] == folder_id and item["name"] == final_name
            ]
            self.assertEqual(len(published), 1)
            self.assertIs(published[0]["hasCustomIcon"], True)
            self.assertEqual(published[0]["description"], tool.DESCRIPTION)
        self.assertIn(identifiers["keep_prefix"], fake.active)
        self.assertIn(identifiers["keep_suffix"], fake.active)
        self.assertIn(identifiers["keep_unrelated"], fake.active)
        for key in ("primary_old", "primary_alt_old"):
            self.assertIn(identifiers[key], fake.active)
            self.assertNotIn(identifiers[key], fake.recycle)
        for key in ("library_old_a", "library_old_b"):
            self.assertIn(identifiers[key], fake.recycle)
        deleted_ids = {
            str(call["id"])
            for call in fake.calls
            if call["op"] == "delete"
        }
        self.assertFalse(
            {identifiers["primary_old"], identifiers["primary_alt_old"]}
            & deleted_ids
        )
        self.assertFalse({"recycle_purge", "recycle_empty"} & set(operations))

    def test_ambiguous_primary_folder_description_uses_readback_without_replay(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake, _ = self.populated_fake()
            fake.root[0]["description"] = (
                "基于开源项目LanzouPlus\n"
                "github链接:https://github.com/nekobyran/lanzouplus\n"
                "作者发布页:https://nkbr.cc/"
            )
            fake.ambiguous_folder_description_once = True
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            summary = publisher.execute()

        self.assertEqual(summary.target_count, 2)
        folder_writes = [
            call
            for call in fake.calls
            if call["op"] == "set_description" and call.get("isFolder") is True
        ]
        self.assertEqual(len(folder_writes), 1)
        self.assertEqual(fake.root[0]["description"], tool.PRIMARY_FOLDER_DESCRIPTION)
        self.assertEqual(sum(call["op"] == "upload" for call in fake.calls), 2)

    def test_ambiguous_staging_mutations_use_readback_without_replay(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake, _ = self.populated_fake()
            fake.ambiguous_upload_once = True
            fake.ambiguous_file_description_once = True
            fake.ambiguous_icon_once = True
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            summary = publisher.execute()

        self.assertEqual(summary.target_count, 2)
        self.assertEqual(sum(call["op"] == "upload" for call in fake.calls), 2)
        self.assertEqual(
            sum(
                call["op"] == "set_description"
                and call.get("isFolder") is False
                for call in fake.calls
            ),
            2,
        )
        self.assertEqual(sum(call["op"] == "set_icon" for call in fake.calls), 2)
        final_name = tool.final_apk_name(self.VERSION)
        for folder_id in (fake.primary_id, fake.library_id):
            published = [
                item
                for item in fake.active.values()
                if item["parent"] == folder_id and item["name"] == final_name
            ]
            self.assertEqual(len(published), 1)
            self.assertIs(published[0]["hasCustomIcon"], True)
            self.assertEqual(published[0]["description"], tool.DESCRIPTION)
    def test_eventually_consistent_metadata_and_rename_are_polled_until_visible(self) -> None:

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = EventuallyConsistentFakeCore(stale_reads=2)
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            with mock.patch("time.sleep", return_value=None) as sleep:
                summary = publisher.execute()

        self.assertEqual(summary.target_count, 2)
        self.assertGreater(sleep.call_count, 0)
        self.assertLess(
            sleep.call_count,
            6 * tool.VERIFICATION_ATTEMPTS,
        )
        self.assertGreaterEqual(
            sum(call["op"] == "share_info" for call in fake.calls),
            6,
        )
        final_name = tool.final_apk_name(self.VERSION)
        for folder_id in (fake.primary_id, fake.library_id):
            published = [
                item
                for item in fake.active.values()
                if item["parent"] == folder_id and item["name"] == final_name
            ]
            self.assertEqual(len(published), 1)

    def test_metadata_polling_is_bounded_and_rolls_back_when_never_visible(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = EventuallyConsistentFakeCore(stale_reads=10_000)
            fake.root[0]["description"] = tool.PRIMARY_FOLDER_DESCRIPTION
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            with (
                mock.patch("time.sleep", return_value=None) as sleep,
                self.assertRaises(tool.PublishError) as raised,
            ):
                publisher.execute()

        self.assertEqual(raised.exception.code, "staging_verify_icon_false")
        self.assertFalse(raised.exception.rollback_incomplete)
        self.assertEqual(sleep.call_count, tool.VERIFICATION_ATTEMPTS)
        self.assertFalse(
            any(
                str(item["name"]).startswith("LanzouMax-staging-")
                for item in fake.active.values()
            )
        )

    def test_metadata_failure_uses_stable_redacted_subcodes(self) -> None:
        cases = (
            ("icon-unknown", "omit_list_icon_state", True, "staging_verify_icon_unknown"),
            ("list-name", "list_name_override", "wrong.apk", "staging_verify_name_absent"),
        )
        for label, attribute, value, expected_code in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                fake = FakeCore()
                setattr(fake, attribute, value)
                publisher = self.publisher(fake, self.make_apk(root))
                publisher.authenticate("fake-user", "fake-password")

                with (
                    mock.patch("time.sleep", return_value=None),
                    self.assertRaises(tool.PublishError) as raised,
                ):
                    publisher.execute()

                self.assertEqual(raised.exception.code, expected_code)
                self.assertRegex(raised.exception.code, tool.SAFE_ERROR_RE)
                self.assertFalse(raised.exception.rollback_incomplete)

    def test_share_info_name_is_non_authoritative_when_list_identity_is_exact(self) -> None:
        for stale_name in ("", "permanently-old-name.apk"):
            with self.subTest(stale_name=stale_name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                fake = FakeCore()
                fake.share_name_override = stale_name
                publisher = self.publisher(fake, self.make_apk(root))
                publisher.authenticate("fake-user", "fake-password")

                with mock.patch("time.sleep", return_value=None):
                    summary = publisher.execute()

                self.assertEqual(summary.target_count, 2)
                self.assertEqual(summary.recovered_staging_count, 0)

    def test_strict_staging_recovery_recycles_only_anchored_names_before_upload(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = FakeCore()
            stale = {
                fake.add_file(
                    fake.primary_id,
                    "LanzouMax-staging-0123456789ab.apk",
                    identifier="stale-primary",
                ),
                fake.add_file(
                    fake.library_id,
                    "LanzouMax-staging-fedcba9876543210.apk",
                    identifier="stale-library",
                ),
            }
            keep = {
                fake.add_file(
                    fake.primary_id,
                    "LanzouMax-staging-not-hex.apk",
                    identifier="keep-non-hex",
                ),
                fake.add_file(
                    fake.library_id,
                    "prefix-LanzouMax-staging-0123456789ab.apk",
                    identifier="keep-prefix",
                ),
            }
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            with mock.patch("time.sleep", return_value=None):
                summary = publisher.execute()

        self.assertEqual(summary.recovered_staging_count, 2)
        self.assertEqual(summary.safe_line(), "result=success;targets=2;candidates=0;staging_recovered=2")
        self.assertTrue(stale.issubset(fake.recycle))
        self.assertTrue(keep.issubset(fake.active))
        recovered_deletes = {
            str(call["id"])
            for call in fake.calls
            if call["op"] == "delete" and str(call["id"]).startswith("stale-")
        }
        self.assertEqual(recovered_deletes, stale)

    def test_dry_run_reports_strict_staging_candidates_without_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = FakeCore()
            stale_id = fake.add_file(
                fake.primary_id,
                "LanzouMax-staging-0123456789ab.apk",
                identifier="stale-primary",
            )
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            summary = publisher.execute(dry_run=True)

        self.assertEqual(summary.recovered_staging_count, 1)
        self.assertEqual(
            summary.safe_line(),
            "result=dry_run;targets=2;candidates=0;staging_candidates=1",
        )
        self.assertIn(stale_id, fake.active)
        self.assertEqual({str(call["op"]) for call in fake.calls}, {"login", "list"})

    def test_staging_recovery_fails_before_upload_when_absence_never_confirms(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = DelayedDeleteFakeCore(stale_reads=0, never_clear=True)
            fake.add_file(
                fake.primary_id,
                "LanzouMax-staging-0123456789ab.apk",
                identifier="stale-primary",
            )
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            with (
                mock.patch("time.sleep", return_value=None),
                self.assertRaises(tool.PublishError) as raised,
            ):
                publisher.execute()

        self.assertEqual(raised.exception.code, "staging_recovery_unconfirmed")
        self.assertTrue(raised.exception.rollback_incomplete)
        self.assertNotIn("upload", {str(call["op"]) for call in fake.calls})

    def test_rollback_waits_for_staging_absence_before_reporting_complete(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = DelayedDeleteFakeCore(stale_reads=2)
            fake.fail_rename_parent = fake.primary_id
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            with (
                mock.patch("time.sleep", return_value=None) as sleep,
                self.assertRaises(tool.PublishError) as raised,
            ):
                publisher.execute()

        self.assertEqual(raised.exception.code, "injected_rename_failure")
        self.assertFalse(raised.exception.rollback_incomplete)
        self.assertGreater(sleep.call_count, 0)
        self.assertEqual(fake.visible_ghost_count(), 0)

    def test_rollback_is_incomplete_when_staging_absence_never_confirms(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = DelayedDeleteFakeCore(stale_reads=0, never_clear=True)
            fake.fail_rename_parent = fake.primary_id
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            with (
                mock.patch("time.sleep", return_value=None),
                self.assertRaises(tool.PublishError) as raised,
            ):
                publisher.execute()

        self.assertEqual(raised.exception.code, "injected_rename_failure")
        self.assertTrue(raised.exception.rollback_incomplete)

    def test_same_version_rerun_replaces_primary_and_library_but_preserves_other_history(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake, identifiers = self.populated_fake()
            primary_current = fake.add_file(
                fake.primary_id,
                tool.final_apk_name(self.VERSION),
                identifier="primary-current",
                has_custom_icon=True,
                description=tool.DESCRIPTION,
            )
            primary_current_alt = fake.add_file(
                fake.primary_id,
                "LANZHOUMAX1.2.3.APK",
                identifier="primary-current-alt",
                has_custom_icon=False,
                description="outdated",
            )
            library_current = fake.add_file(
                fake.library_id,
                tool.final_apk_name(self.VERSION),
                identifier="library-current",
                has_custom_icon=True,
                description=tool.DESCRIPTION,
            )
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            summary = publisher.execute()

        self.assertEqual(summary.target_count, 2)
        self.assertEqual(summary.candidate_count, 5)
        uploads = [call for call in fake.calls if call["op"] == "upload"]
        self.assertEqual(len(uploads), 2)
        self.assertEqual(
            {str(call["folderId"]) for call in uploads},
            {fake.primary_id, fake.library_id},
        )
        self.assertIn(primary_current, fake.recycle)
        self.assertIn(primary_current_alt, fake.recycle)
        for key in ("primary_old", "primary_alt_old"):
            self.assertIn(identifiers[key], fake.active)
            self.assertNotIn(identifiers[key], fake.recycle)
        for key in ("library_old_a", "library_old_b"):
            self.assertIn(identifiers[key], fake.recycle)
        self.assertIn(library_current, fake.recycle)

    def test_failure_in_second_directory_removes_new_uploads_and_restores_old_items(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake, identifiers = self.populated_fake()
            primary_current = fake.add_file(
                fake.primary_id,
                tool.final_apk_name(self.VERSION),
                identifier="primary-current",
                has_custom_icon=True,
                description=tool.DESCRIPTION,
            )
            fake.fail_rename_parent = fake.library_id
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            with self.assertRaises(tool.PublishError) as raised:
                publisher.execute()

        self.assertEqual(raised.exception.code, "injected_rename_failure")
        self.assertFalse(raised.exception.rollback_incomplete)
        for key in ("primary_old", "primary_alt_old", "library_old_a", "library_old_b"):
            self.assertIn(identifiers[key], fake.active)
            self.assertNotIn(identifiers[key], fake.recycle)
        self.assertIn(primary_current, fake.active)
        self.assertNotIn(primary_current, fake.recycle)
        self.assertEqual(fake.active[primary_current]["parent"], fake.primary_id)
        for key in ("library_old_a", "library_old_b"):
            self.assertEqual(
                fake.active[identifiers[key]]["parent"], fake.library_id
            )
        staging_prefix = "LanzouMax-staging-"
        self.assertFalse(
            any(str(item["name"]).startswith(staging_prefix) for item in fake.active.values())
        )
        uploaded_ids = {
            str(call["fileId"])
            for call in fake.calls
            if call["op"] == "set_icon"
        }
        self.assertTrue(uploaded_ids)
        self.assertTrue(uploaded_ids.issubset(fake.recycle))
        operations = [str(call["op"]) for call in fake.calls]
        restored_ids = {
            str(call["id"])
            for call in fake.calls
            if call["op"] == "recycle_restore"
        }
        self.assertEqual(
            restored_ids,
            {
                primary_current,
                identifiers["library_old_a"],
                identifiers["library_old_b"],
            },
        )
        self.assertFalse({"recycle_purge", "recycle_empty"} & set(operations))

    def test_ambiguous_delete_is_detected_in_recycle_and_restored(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake, identifiers = self.populated_fake()
            primary_current = fake.add_file(
                fake.primary_id,
                "lanzhoumax1.2.3.apk",
                identifier="primary-current",
            )
            fake.ambiguous_delete_id = primary_current
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            with self.assertRaises(tool.PublishError) as raised:
                publisher.execute()

        self.assertEqual(raised.exception.code, "injected_ambiguous_delete")
        self.assertFalse(raised.exception.rollback_incomplete)
        self.assertIn(primary_current, fake.active)
        self.assertNotIn(primary_current, fake.recycle)
        self.assertIn(identifiers["primary_old"], fake.active)
        self.assertNotIn(identifiers["primary_old"], fake.recycle)
        operations = [str(call["op"]) for call in fake.calls]
        self.assertIn("recycle_list", operations)
        self.assertIn("recycle_restore", operations)
        self.assertIn("move", operations)
        self.assertEqual(fake.active[primary_current]["parent"], fake.primary_id)

    def test_rollback_marks_incomplete_on_restore_move_or_verification_failure(self) -> None:
        cases = (
            ("restore", "fail_restore_id", "primary-current"),
            ("move", "fail_move_id", "library-old-a"),
            ("verification", "ignore_move_id", "library-old-b"),
        )
        for label, failure_attribute, failure_id in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                fake, _ = self.populated_fake()
                fake.add_file(
                    fake.primary_id,
                    tool.final_apk_name(self.VERSION),
                    identifier="primary-current",
                )
                setattr(fake, failure_attribute, failure_id)
                fake.fail_rename_parent = fake.library_id
                publisher = self.publisher(fake, self.make_apk(root))
                publisher.authenticate("fake-user", "fake-password")

                with self.assertRaises(tool.PublishError) as raised:
                    publisher.execute()

                self.assertEqual(raised.exception.code, "injected_rename_failure")
                self.assertTrue(raised.exception.rollback_incomplete)

    def test_dry_run_performs_only_login_and_bounded_lists(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake, _ = self.populated_fake()
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            summary = publisher.execute(dry_run=True)

        self.assertTrue(summary.dry_run)
        self.assertEqual(summary.candidate_count, 2)
        operations = {str(call["op"]) for call in fake.calls}
        self.assertEqual(operations, {"login", "list"})

    def test_verify_readback_downloads_both_exact_final_files_and_cleans_temp(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = FakeCore()
            apk = self.make_apk(root)
            payload = apk.read_bytes()
            for parent, identifier in (
                (fake.primary_id, "primary-final"),
                (fake.library_id, "library-final"),
            ):
                fake.add_file(
                    parent,
                    tool.final_apk_name(self.VERSION),
                    identifier=identifier,
                    content=payload,
                )
            readback_root = root / "readback"
            readback_root.mkdir()
            publisher = self.publisher(fake, apk)
            publisher.authenticate("fake-user", "fake-password")

            summary = publisher.verify_readback(readback_root)

            self.assertEqual(summary.target_count, 2)
            self.assertEqual(summary.verified_count, 2)
            self.assertEqual(
                summary.safe_line(),
                "result=readback_verified;targets=2;verified=2",
            )
            self.assertEqual(list(readback_root.iterdir()), [])
            operations = [str(call["op"]) for call in fake.calls]
            self.assertEqual(operations.count("download"), 2)
            self.assertEqual(set(operations), {"login", "list", "download"})

    def test_verify_readback_rejects_hash_mismatch_and_cleans_temp(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = FakeCore()
            apk = self.make_apk(root)
            payload = apk.read_bytes()
            fake.add_file(
                fake.primary_id,
                tool.final_apk_name(self.VERSION),
                identifier="primary-final",
                content=payload,
            )
            fake.add_file(
                fake.library_id,
                tool.final_apk_name(self.VERSION),
                identifier="library-final",
                content=b"X" + payload[1:],
            )
            readback_root = root / "readback"
            readback_root.mkdir()
            publisher = self.publisher(fake, apk)
            publisher.authenticate("fake-user", "fake-password")

            with self.assertRaises(tool.PublishError) as raised:
                publisher.verify_readback(readback_root)

            self.assertEqual(raised.exception.code, "readback_bytes_mismatch")
            self.assertEqual(list(readback_root.iterdir()), [])

    def test_verify_readback_rejects_size_mismatch_and_cleans_temp(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = FakeCore()
            apk = self.make_apk(root)
            payload = apk.read_bytes()
            fake.add_file(
                fake.primary_id,
                tool.final_apk_name(self.VERSION),
                identifier="primary-final",
                content=payload,
            )
            fake.add_file(
                fake.library_id,
                tool.final_apk_name(self.VERSION),
                identifier="library-final",
                content=b"short",
            )
            readback_root = root / "readback"
            readback_root.mkdir()
            publisher = self.publisher(fake, apk)
            publisher.authenticate("fake-user", "fake-password")

            with self.assertRaises(tool.PublishError) as raised:
                publisher.verify_readback(readback_root)

            self.assertEqual(raised.exception.code, "readback_bytes_mismatch")
            self.assertEqual(list(readback_root.iterdir()), [])

    def test_verify_readback_requires_one_exact_final_per_target_before_download(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = FakeCore()
            apk = self.make_apk(root)
            payload = apk.read_bytes()
            fake.add_file(
                fake.primary_id,
                tool.final_apk_name(self.VERSION),
                identifier="primary-final-a",
                content=payload,
            )
            fake.add_file(
                fake.primary_id,
                tool.final_apk_name(self.VERSION).upper(),
                identifier="primary-final-b",
                content=payload,
            )
            fake.add_file(
                fake.library_id,
                tool.final_apk_name(self.VERSION),
                identifier="library-final",
                content=payload,
            )
            readback_root = root / "readback"
            readback_root.mkdir()
            publisher = self.publisher(fake, apk)
            publisher.authenticate("fake-user", "fake-password")

            with self.assertRaises(tool.PublishError) as raised:
                publisher.verify_readback(readback_root)

            self.assertEqual(raised.exception.code, "readback_final_not_unique")
            self.assertNotIn("download", {str(call["op"]) for call in fake.calls})
            self.assertEqual(list(readback_root.iterdir()), [])

    def test_verify_readback_cleans_partial_download_on_core_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = FakeCore()
            apk = self.make_apk(root)
            payload = apk.read_bytes()
            fake.add_file(
                fake.primary_id,
                tool.final_apk_name(self.VERSION),
                identifier="primary-final",
                content=payload,
            )
            fake.add_file(
                fake.library_id,
                tool.final_apk_name(self.VERSION),
                identifier="library-final",
                content=payload,
            )
            fake.fail_download_id = "library-final"
            readback_root = root / "readback"
            readback_root.mkdir()
            publisher = self.publisher(fake, apk)
            publisher.authenticate("fake-user", "fake-password")

            with self.assertRaises(tool.PublishError) as raised:
                publisher.verify_readback(readback_root)

            self.assertEqual(raised.exception.code, "injected_download_failure")
            self.assertEqual(list(readback_root.iterdir()), [])

    def test_verify_readback_blocks_if_local_apk_changes_during_readback(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = FakeCore()
            apk = self.make_apk(root)
            payload = apk.read_bytes()
            for parent, identifier in (
                (fake.primary_id, "primary-final"),
                (fake.library_id, "library-final"),
            ):
                fake.add_file(
                    parent,
                    tool.final_apk_name(self.VERSION),
                    identifier=identifier,
                    content=payload,
                )
            readback_root = root / "readback"
            readback_root.mkdir()
            publisher = self.publisher(fake, apk)
            publisher.authenticate("fake-user", "fake-password")
            original_call = fake.call
            mutated = False

            def mutate_after_first_download(command: dict[str, object]) -> dict[str, object]:
                nonlocal mutated
                result = original_call(command)
                if command.get("op") == "download" and not mutated:
                    apk.write_bytes(b"changed-local-apk")
                    mutated = True
                return result

            with (
                mock.patch.object(fake, "call", side_effect=mutate_after_first_download),
                self.assertRaises(tool.PublishError) as raised,
            ):
                publisher.verify_readback(readback_root)

            self.assertEqual(raised.exception.code, "readback_local_changed")
            self.assertEqual(list(readback_root.iterdir()), [])

    @unittest.skipUnless(os.name == "nt", "Windows drive policy required")
    def test_verify_readback_temp_root_rejects_system_drive_without_access(self) -> None:
        with self.assertRaises(tool.PublishError) as raised:
            tool.validate_readback_temp_root(
                Path(r"C:\forbidden-readback-root-that-must-not-be-accessed")
            )
        self.assertEqual(raised.exception.code, "readback_temp_invalid")

    def test_invalid_jpeg_icon_fails_before_cloud_listing_or_mutation(self) -> None:
        cases = {
            "missing": ("missing.jpg", None),
            "empty": ("empty.jpg", b""),
            "extension": ("icon.png", b"\xff\xd8\xffdata\xff\xd9"),
            "magic": ("icon.jpg", b"not-a-jpeg"),
            "limit": (
                "icon.jpg",
                b"\xff\xd8\xff" + (b"x" * 99_995) + b"\xff\xd9",
            ),
        }
        for label, (name, content) in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                fake, _ = self.populated_fake()
                icon = root / name
                if content is not None:
                    icon.write_bytes(content)
                publisher = tool.Publisher(
                    fake,
                    self.make_apk(root),
                    icon,
                    self.VERSION,
                    token_factory=lambda: self.TOKEN,
                )
                publisher.authenticate("fake-user", "fake-password")

                with self.assertRaises(tool.PublishError) as raised:
                    publisher.execute()

                self.assertEqual(raised.exception.code, "icon_invalid")
                self.assertEqual(
                    [str(call["op"]) for call in fake.calls], ["login"]
                )

    def test_duplicate_root_target_and_candidate_limit_fail_before_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake, _ = self.populated_fake()
            fake.root.append(FakeCore._folder("duplicate-primary", tool.PRIMARY_FOLDER))
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")
            with self.assertRaises(tool.PublishError) as duplicate:
                publisher.execute()
            self.assertEqual(duplicate.exception.code, "target_folder_not_unique")
            self.assertEqual({str(call["op"]) for call in fake.calls}, {"login", "list"})

            limited, _ = self.populated_fake()
            for index in range(tool.MAX_REPLACEMENT_CANDIDATES + 1):
                limited.add_file(limited.library_id, f"LanzouMax9.0.{index}.apk")
            publisher = self.publisher(limited, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")
            with self.assertRaises(tool.PublishError) as over_limit:
                publisher.execute()
            self.assertEqual(over_limit.exception.code, "candidate_limit_exceeded")
            self.assertEqual({str(call["op"]) for call in limited.calls}, {"login", "list"})

    def test_primary_same_version_candidate_limit_fails_before_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake, _ = self.populated_fake()
            for index in range(tool.MAX_REPLACEMENT_CANDIDATES + 1):
                spelling = "LanzouMax" if index % 2 == 0 else "LanzhouMax"
                fake.add_file(
                    fake.primary_id,
                    f"{spelling}{self.VERSION}.apk",
                    identifier=f"primary-current-{index}",
                )
            publisher = self.publisher(fake, self.make_apk(root))
            publisher.authenticate("fake-user", "fake-password")

            with self.assertRaises(tool.PublishError) as raised:
                publisher.execute()

        self.assertEqual(raised.exception.code, "candidate_limit_exceeded")
        self.assertEqual({str(call["op"]) for call in fake.calls}, {"login", "list"})
        self.assertEqual(fake.recycle, {})

    def test_cli_uses_environment_credentials_and_redacts_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            apk = self.make_apk(root)
            icon = self.make_icon(root)
            dll = root / "fake-core.dll"
            dll.write_bytes(b"fake")
            fake, _ = self.populated_fake()
            stdout = io.StringIO()
            stderr = io.StringIO()
            environment = {
                "LANZOUYOU_USERNAME": "fake-private-user",
                "LANZOUYOU_PASSWORD": "fake-private-password",
            }
            with (
                mock.patch.object(tool, "RustCore", return_value=fake),
                mock.patch.dict(os.environ, environment, clear=False),
                contextlib.redirect_stdout(stdout),
                contextlib.redirect_stderr(stderr),
            ):
                result = tool.main(
                    [
                        "--apk",
                        str(apk),
                        "--icon",
                        str(icon),
                        "--version",
                        self.VERSION,
                        "--core-dll",
                        str(dll),
                        "--dry-run",
                    ]
                )

        self.assertEqual(result, 0)
        combined = stdout.getvalue() + stderr.getvalue()
        for forbidden in (
            "fake-private-user",
            "fake-private-password",
            "fake-cookie-must-never-be-printed",
            "folder-primary",
            "private-unrelated.apk",
        ):
            self.assertNotIn(forbidden, combined)
        self.assertEqual(
            stdout.getvalue().strip(),
            "result=dry_run;targets=2;candidates=2;staging_candidates=0",
        )

    def test_cli_verify_readback_emits_only_safe_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            apk = self.make_apk(root)
            icon = self.make_icon(root)
            dll = root / "fake-core.dll"
            dll.write_bytes(b"fake")
            fake = FakeCore()
            payload = apk.read_bytes()
            fake.add_file(
                fake.primary_id,
                tool.final_apk_name(self.VERSION),
                identifier="private-primary-id",
                content=payload,
            )
            fake.add_file(
                fake.library_id,
                tool.final_apk_name(self.VERSION),
                identifier="private-library-id",
                content=payload,
            )
            readback_root = root / "private-readback-root"
            readback_root.mkdir()
            stdout = io.StringIO()
            stderr = io.StringIO()
            environment = {
                "LANZOUYOU_USERNAME": "fake-private-user",
                "LANZOUYOU_PASSWORD": "fake-private-password",
            }
            with (
                mock.patch.object(tool, "RustCore", return_value=fake),
                mock.patch.dict(os.environ, environment, clear=False),
                contextlib.redirect_stdout(stdout),
                contextlib.redirect_stderr(stderr),
            ):
                result = tool.main(
                    [
                        "--apk", str(apk),
                        "--icon", str(icon),
                        "--version", self.VERSION,
                        "--core-dll", str(dll),
                        "--verify-readback",
                        "--readback-temp-root", str(readback_root),
                    ]
                )

        self.assertEqual(result, 0)
        self.assertEqual(
            stdout.getvalue().strip(),
            "result=readback_verified;targets=2;verified=2",
        )
        combined = stdout.getvalue() + stderr.getvalue()
        for forbidden in (
            "fake-private-user",
            "fake-private-password",
            "fake-cookie-must-never-be-printed",
            "private-primary-id",
            "private-library-id",
            "private-readback-root",
        ):
            self.assertNotIn(forbidden, combined)

    def test_cli_rejects_combined_dry_run_and_verify_readback(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = tool.main(
                [
                    "--apk", "private-local-name.apk",
                    "--icon", "private-icon.jpg",
                    "--version", self.VERSION,
                    "--core-dll", "private-core.dll",
                    "--dry-run",
                    "--verify-readback",
                ]
            )
        self.assertEqual(result, 2)
        self.assertEqual(
            stderr.getvalue().strip(),
            "error_code=arguments_invalid;rollback=complete",
        )
        self.assertNotIn("private-", stdout.getvalue() + stderr.getvalue())

    def test_entrypoints_expose_no_plaintext_credentials_or_destructive_recycle_ops(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            invalid_result = tool.main(["--apk", "private-local-name.apk"])
        self.assertEqual(invalid_result, 2)
        self.assertEqual(stderr.getvalue().strip(), "error_code=arguments_invalid;rollback=complete")
        self.assertNotIn("private-local-name", stdout.getvalue() + stderr.getvalue())

        parser_dests = {action.dest for action in tool.build_parser()._actions}
        self.assertNotIn("username", parser_dests)
        self.assertNotIn("password", parser_dests)
        self.assertNotIn("recycle_purge", tool.ALLOWED_OPERATIONS)
        self.assertNotIn("recycle_empty", tool.ALLOWED_OPERATIONS)
        self.assertNotIn("prepare_icon", tool.ALLOWED_OPERATIONS)
        self.assertIn("move", tool.ALLOWED_OPERATIONS)
        self.assertIn("download", tool.ALLOWED_OPERATIONS)

        publisher_source = Path(tool.__file__).read_text("utf-8")
        self.assertNotIn('"op": "prepare_icon"', publisher_source)

        workspace = Path(__file__).resolve().parents[3]
        powershell = (workspace / "command" / "Publish-LanzouMax.ps1").read_text("utf-8")
        self.assertIn(
            "release/lanzou-native-java_android/local/LanzouMax.apk", powershell
        )
        self.assertIn(
            "resource/lanzoumax/lanzoumax-publish-icon.jpg",
            powershell,
        )
        self.assertIn("'--icon', $icon.FullName", powershell)
        self.assertNotIn("[string]$ApkPath", powershell)
        self.assertNotIn("[string]$IconPath", powershell)
        self.assertIn("[string]$CredentialFile", powershell)
        self.assertIn("backup/private/lanzouyou-publisher-credential.dpapi", powershell)
        self.assertIn("ConvertTo-SecureString -String $protectedText", powershell)
        self.assertIn("SecureStringToBSTR", powershell)
        self.assertIn("$credentialPayload['account']", powershell)
        self.assertIn("ProtectedData]::Unprotect", powershell)
        self.assertIn("flutter_secure_storage.dat", powershell)
        self.assertIn("provider_session_cookie", powershell)
        self.assertIn("LANZOUYOU_SESSION_COOKIE", powershell)
        self.assertIn("LANZOUYOU_USERNAME", powershell)
        self.assertIn("LANZOUYOU_PASSWORD", powershell)
        self.assertIn("ProcessStartInfo", powershell)
        self.assertIn("$startInfo.Environment['LANZOUYOU_USERNAME']", powershell)
        self.assertIn("[switch]$Publish", powershell)
        self.assertIn("[switch]$VerifyReadback", powershell)
        self.assertIn("[Alias('?', 'Help')]", powershell)
        self.assertIn("'--verify-readback'", powershell)
        self.assertIn("'--readback-temp-root', $PublishTemp", powershell)
        self.assertNotIn("SetEnvironmentVariable('LANZOUYOU_USERNAME'", powershell)
        self.assertNotIn("[string]$Username", powershell)
        self.assertNotIn("[string]$Password", powershell)
        success_pattern = re.search(
            r"\$safeSuccessPattern = '([^']+)'",
            powershell,
        )
        self.assertIsNotNone(success_pattern)
        output_allowlist = re.compile(success_pattern.group(1))
        self.assertIsNotNone(
            output_allowlist.fullmatch(
                "result=success;targets=2;candidates=2;staging_recovered=1"
            )
        )
        self.assertIsNotNone(
            output_allowlist.fullmatch(
                "result=dry_run;targets=2;candidates=2;staging_candidates=1"
            )
        )
        self.assertIsNotNone(
            output_allowlist.fullmatch(
                "result=readback_verified;targets=2;verified=2"
            )
        )
        self.assertIsNone(
            output_allowlist.fullmatch(
                "result=success;targets=2;candidates=2;staging_candidates=1"
            )
        )
        self.assertIsNone(
            output_allowlist.fullmatch(
                "result=dry_run;targets=2;candidates=2;staging_recovered=1"
            )
        )

    @unittest.skipUnless(os.name == "nt" and shutil.which("pwsh"), "PowerShell 7 required")
    def test_powershell_question_mark_is_safe_help_not_default_publish(self) -> None:
        workspace = Path(__file__).resolve().parents[3]
        script = workspace / "command" / "Publish-LanzouMax.ps1"
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(script), "-?"],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("-Publish", result.stdout)
        self.assertIn("-VerifyReadback", result.stdout)
        self.assertNotIn("固定构建 APK 不存在", result.stdout + result.stderr)

    def test_workspace_fixed_publish_icon_is_already_compliant_raw_jpeg(self) -> None:
        workspace = Path(__file__).resolve().parents[3]
        icon = (
            workspace
            / "resource"
            / "lanzoumax"
            / "lanzoumax-publish-icon.jpg"
        )
        raw = icon.read_bytes()
        self.assertEqual(icon.suffix.lower(), ".jpg")
        self.assertTrue(0 < len(raw) < 100_000)
        self.assertEqual(raw[:3], b"\xff\xd8\xff")
        self.assertEqual(raw[-2:], b"\xff\xd9")

    @unittest.skipUnless(
        os.name == "nt" and shutil.which("pwsh") and shutil.which("rustc"),
        "PowerShell 7 and rustc on Windows required",
    )
    def test_powershell_reads_convertfromsecurestring_dpapi_account_schema_with_fake_child(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            new_tools = root / "sdk" / "build-tools" / "35.0.0"
            old_tools = root / "sdk" / "build-tools" / "34.0.0"
            binary_dir = root / "bin"
            new_tools.mkdir(parents=True)
            old_tools.mkdir(parents=True)
            binary_dir.mkdir()

            def compile_stub(source: str, destination: Path) -> None:
                source_path = destination.with_suffix(".rs")
                source_path.write_text(source, encoding="utf-8")
                result = subprocess.run(
                    ["rustc", str(source_path), "-C", "opt-level=0", "-o", str(destination)],
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    capture_output=True,
                    timeout=120,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

            compile_stub(
                "fn main() { println!(\"package: name='cc.fake' versionCode='1' versionName='1.2.3'\"); }\n",
                new_tools / "aapt2.exe",
            )
            compile_stub(
                "fn main() { println!(\"package: name='cc.fake' versionCode='1' versionName='0.1.0'\"); }\n",
                old_tools / "aapt2.exe",
            )
            compile_stub(
                textwrap.dedent(
                    r'''
                    fn value_after(args: &[String], flag: &str) -> String {
                        args.windows(2)
                            .find(|pair| pair[0] == flag)
                            .map(|pair| pair[1].clone())
                            .unwrap_or_default()
                    }

                    fn main() {
                        let account = std::env::var("LANZOUYOU_USERNAME").unwrap_or_default();
                        let password = std::env::var("LANZOUYOU_PASSWORD").unwrap_or_default();
                        if account != "fake-account" || password != "fake-password" {
                            std::process::exit(9);
                        }
                        let args: Vec<String> = std::env::args().skip(1).collect();
                        let apk = value_after(&args, "--apk").replace('\\', "/");
                        let icon = value_after(&args, "--icon").replace('\\', "/");
                        let version = value_after(&args, "--version");
                        if !apk.ends_with("/release/lanzou-native-java_android/local/LanzouMax.apk")
                            || !icon.ends_with("/resource/lanzoumax/lanzoumax-publish-icon.jpg")
                            || version != "1.2.3"
                            || !args.iter().any(|arg| arg == "--dry-run")
                        {
                            std::process::exit(10);
                        }
                        println!("result=dry_run;targets=2;candidates=0;staging_candidates=0");
                    }
                    '''
                ).strip()
                + "\n",
                binary_dir / "python.exe",
            )

            setup = root / "make-credential.ps1"
            setup.write_text(
                textwrap.dedent(
                    r'''
                    param([Parameter(Mandatory = $true)][string]$Root)
                    $ErrorActionPreference = 'Stop'
                    $payload = '{"account":"fake-account","password":"fake-password","schema":1}'
                    $secure = ConvertTo-SecureString -String $payload -AsPlainText -Force
                    $protected = ConvertFrom-SecureString -SecureString $secure
                    [System.IO.File]::WriteAllText(
                        (Join-Path $Root 'credential.dpapi'),
                        $protected,
                        [System.Text.Encoding]::ASCII
                    )
                    '''
                ).strip()
                + "\n",
                encoding="utf-8",
            )
            setup_result = subprocess.run(
                ["pwsh", "-NoProfile", "-File", str(setup), "-Root", str(root)],
                text=True,
                encoding="utf-8",
                errors="replace",
                capture_output=True,
                timeout=120,
                check=False,
            )
            self.assertEqual(setup_result.returncode, 0, setup_result.stderr)
            protected = (root / "credential.dpapi").read_text("ascii").strip()
            self.assertRegex(protected, r"\A[0-9A-Fa-f]+\Z")
            self.assertNotIn("fake-account", protected)
            self.assertNotIn("fake-password", protected)

            source_workspace = Path(__file__).resolve().parents[3]
            workspace = root / "workspace"
            script = workspace / "command" / "Publish-LanzouMax.ps1"
            python_tool = workspace / "project" / "LanzouYOU" / "tool" / "publish_lanzoumax.py"
            apk = workspace / "release" / "lanzou-native-java_android" / "local" / "LanzouMax.apk"
            icon = (
                workspace
                / "resource"
                / "lanzoumax"
                / "lanzoumax-publish-icon.jpg"
            )
            core = root / "fake-core.dll"
            script.parent.mkdir(parents=True)
            python_tool.parent.mkdir(parents=True)
            apk.parent.mkdir(parents=True)
            icon.parent.mkdir(parents=True)
            shutil.copyfile(
                source_workspace / "command" / "Publish-LanzouMax.ps1", script
            )
            python_tool.write_text("# fake child entry\n", encoding="utf-8")
            apk.write_bytes(b"fake-apk")
            icon.write_bytes(b"\xff\xd8\xff\xe0fake-jpeg\xff\xd9")
            core.write_bytes(b"fake-core")
            environment = os.environ.copy()
            environment.pop("LANZOUYOU_USERNAME", None)
            environment.pop("LANZOUYOU_PASSWORD", None)
            environment["PATH"] = str(root / "bin") + os.pathsep + environment.get("PATH", "")
            result = subprocess.run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-File",
                    str(script),
                    "-CoreDllPath",
                    str(core),
                    "-AndroidSdkPath",
                    str(root / "sdk"),
                    "-CredentialFile",
                    str(root / "credential.dpapi"),
                    "-PythonPath",
                    str(root / "bin" / "python.exe"),
                    "-DryRun",
                ],
                text=True,
                encoding="utf-8",
                errors="replace",
                capture_output=True,
                timeout=120,
                check=False,
                env=environment,
            )
            combined = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, combined)
            self.assertEqual(
                result.stdout.strip(),
                "result=dry_run;targets=2;candidates=0;staging_candidates=0",
            )
            self.assertEqual(result.stderr.strip(), "")
            self.assertNotIn("fake-account", combined)
            self.assertNotIn("fake-password", combined)


if __name__ == "__main__":
    unittest.main()
