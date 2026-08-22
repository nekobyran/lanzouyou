#!/usr/bin/env python3
"""Transactional LanzouMax hand-off through the LanzouYOU Rust FFI.

The command intentionally emits counts and stable error codes only. It never
prints credentials, cookies, cloud identifiers, directory listings, or native
responses.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol, Sequence


ROOT_ID = "-1"
PRIMARY_FOLDER = "LanzouMax"
LIBRARY_FOLDER = "软件库合集"
TARGET_FOLDERS = (PRIMARY_FOLDER, LIBRARY_FOLDER)
DESCRIPTION = "官网链接:https://lanzoumax.nkbr.cc/"
PRIMARY_FOLDER_DESCRIPTION = DESCRIPTION
MAX_LIST_ITEMS = 2_000
MAX_LIST_PAGES = 50
MAX_REPLACEMENT_CANDIDATES = 20
MAX_RECYCLE_ITEMS = 2_000
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
MAX_VERSION_LENGTH = 64
VERIFICATION_ATTEMPTS = 12
VERIFICATION_INTERVAL_SECONDS = 1.0
ABSENCE_CONFIRMATIONS = 2

VERSION_BODY = (
    r"[0-9]+(?:\.[0-9]+){0,3}"
    r"(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"
    r"(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"
)
VERSION_RE = re.compile(rf"\A{VERSION_BODY}\Z", re.ASCII)
LIBRARY_APK_RE = re.compile(
    rf"\A(?:LanzouMax|LanzhouMax){VERSION_BODY}\.apk\Z",
    re.IGNORECASE | re.ASCII,
)
VERSIONED_APK_RE = re.compile(
    rf"\A(?:LanzouMax|LanzhouMax)(?P<version>{VERSION_BODY})\.apk\Z",
    re.IGNORECASE | re.ASCII,
)
TOKEN_RE = re.compile(r"\A[0-9a-f]{12,32}\Z", re.ASCII)
STAGING_APK_RE = re.compile(
    r"\ALanzouMax-staging-[0-9a-f]{12,32}\.apk\Z",
    re.ASCII,
)
SAFE_ERROR_RE = re.compile(r"\A[a-z0-9_]{1,64}\Z", re.ASCII)

# Only non-destructive recycle operations are available to this publisher.
ALLOWED_OPERATIONS = frozenset(
    {
        "login",
        "list",
        "upload",
        "set_description",
        "set_icon",
        "share_info",
        "delete",
        "download",
        "rename",
        "move",
        "recycle_list",
        "recycle_restore",
    }
)


class PublishError(Exception):
    """A redaction-safe failure suitable for CLI output."""

    def __init__(self, code: str, *, rollback_incomplete: bool = False) -> None:
        self.code = code if SAFE_ERROR_RE.fullmatch(code) else "publish_failed"
        self.rollback_incomplete = rollback_incomplete
        super().__init__(self.code)


class CoreClient(Protocol):
    def call(self, command: Mapping[str, Any]) -> dict[str, Any]: ...


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        del message
        raise PublishError("arguments_invalid")


class RustCore:
    """Small ownership-safe ctypes adapter for lanzouyou_dispatch/free."""

    def __init__(self, library_path: Path) -> None:
        try:
            self._library = ctypes.CDLL(os.fspath(library_path))
            self._dispatch = self._library.lanzouyou_dispatch
            self._free = self._library.lanzouyou_free
        except (OSError, AttributeError) as exc:
            raise PublishError("core_unavailable") from exc
        self._dispatch.argtypes = [ctypes.c_char_p]
        self._dispatch.restype = ctypes.c_void_p
        self._free.argtypes = [ctypes.c_void_p]
        self._free.restype = None

    def call(self, command: Mapping[str, Any]) -> dict[str, Any]:
        operation = command.get("op")
        if not isinstance(operation, str) or operation not in ALLOWED_OPERATIONS:
            raise PublishError("operation_not_allowed")
        request = json.dumps(
            dict(command), ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
        pointer = self._dispatch(request)
        if not pointer:
            raise PublishError("core_invalid_response")
        try:
            raw = ctypes.string_at(pointer)
        finally:
            self._free(pointer)
        if not raw or len(raw) > MAX_RESPONSE_BYTES:
            raise PublishError("core_invalid_response")
        try:
            envelope = json.loads(raw.decode("utf-8", errors="strict"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise PublishError("core_invalid_response") from exc
        if not isinstance(envelope, dict):
            raise PublishError("core_invalid_response")
        if envelope.get("ok") is not True:
            raw_error = envelope.get("error")
            raw_code = raw_error.get("code") if isinstance(raw_error, dict) else None
            core_code = (
                raw_code
                if isinstance(raw_code, str) and SAFE_ERROR_RE.fullmatch(raw_code)
                else "core_error"
            )
            raise PublishError(f"core_{core_code}")
        data = envelope.get("data")
        if not isinstance(data, dict):
            raise PublishError("core_invalid_response")
        return data


@dataclass(frozen=True)
class CloudItem:
    id: str
    name: str
    is_folder: bool
    has_custom_icon: bool | None = None
    description: str | None = None

    @classmethod
    def from_json(cls, raw: Mapping[str, Any]) -> "CloudItem":
        identifier = raw.get("id")
        name = raw.get("name")
        is_folder = raw.get("isFolder")
        if (
            not isinstance(identifier, str)
            or not identifier
            or not isinstance(name, str)
            or not isinstance(is_folder, bool)
        ):
            raise PublishError("cloud_item_invalid")
        raw_icon_state = raw.get("hasCustomIcon")
        raw_description = raw.get("description")
        return cls(
            id=identifier,
            name=name,
            is_folder=is_folder,
            has_custom_icon=(
                raw_icon_state if isinstance(raw_icon_state, bool) else None
            ),
            description=(
                raw_description if isinstance(raw_description, str) else None
            ),
        )


@dataclass
class TargetPlan:
    folder: CloudItem
    old_items: list[CloudItem]
    stale_staging: list[CloudItem] = field(default_factory=list)
    upload_attempted: bool = False
    stage: CloudItem | None = None


@dataclass(frozen=True)
class PublishSummary:
    dry_run: bool
    target_count: int
    candidate_count: int
    recovered_staging_count: int

    def safe_line(self) -> str:
        result = "dry_run" if self.dry_run else "success"
        staging_key = (
            "staging_candidates" if self.dry_run else "staging_recovered"
        )
        return (
            f"result={result};targets={self.target_count};"
            f"candidates={self.candidate_count};"
            f"{staging_key}={self.recovered_staging_count}"
        )


@dataclass(frozen=True)
class ReadbackSummary:
    target_count: int
    verified_count: int
    sha256: str

    def safe_line(self) -> str:
        if not re.fullmatch(r"[0-9a-f]{64}", self.sha256):
            raise PublishError("readback_summary_invalid")
        return (
            f"result=readback_verified;targets={self.target_count};"
            f"verified={self.verified_count};sha256={self.sha256}"
        )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_readback_temp_root(value: Path) -> Path:
    try:
        requested = Path(value)
        if not requested.is_absolute():
            raise PublishError("readback_temp_invalid")
        if os.name == "nt" and requested.drive.upper() not in {"D:", "H:"}:
            raise PublishError("readback_temp_invalid")
        resolved = requested.resolve(strict=True)
        if (
            not resolved.is_dir()
            or resolved.is_symlink()
            or (os.name == "nt" and resolved.drive.upper() not in {"D:", "H:"})
        ):
            raise PublishError("readback_temp_invalid")
        return resolved
    except PublishError:
        raise
    except (OSError, RuntimeError, ValueError):
        raise PublishError("readback_temp_invalid") from None


def validate_version(version: str) -> str:
    if (
        not isinstance(version, str)
        or len(version) > MAX_VERSION_LENGTH
        or VERSION_RE.fullmatch(version) is None
    ):
        raise PublishError("version_invalid")
    return version


def final_apk_name(version: str) -> str:
    return f"LanzouMax{validate_version(version)}.apk"


def is_library_replacement(name: str) -> bool:
    return isinstance(name, str) and LIBRARY_APK_RE.fullmatch(name) is not None


def is_same_version_replacement(name: str, version: str) -> bool:
    if not isinstance(name, str):
        return False
    validated_version = validate_version(version)
    match = VERSIONED_APK_RE.fullmatch(name)
    return (
        match is not None
        and match.group("version").casefold() == validated_version.casefold()
    )


def select_replacement_candidates(
    folder_name: str,
    items: Sequence[CloudItem],
    version: str,
) -> list[CloudItem]:
    if folder_name == PRIMARY_FOLDER:
        # LanzouMax remains a permanent archive across versions, but republishing
        # the locally built version replaces every same-version spelling variant.
        selected = [
            item
            for item in items
            if not item.is_folder and is_same_version_replacement(item.name, version)
        ]
    elif folder_name == LIBRARY_FOLDER:
        selected = [
            item
            for item in items
            if not item.is_folder and is_library_replacement(item.name)
        ]
    else:
        raise PublishError("target_folder_invalid")
    if len(selected) > MAX_REPLACEMENT_CANDIDATES:
        raise PublishError("candidate_limit_exceeded")
    return selected


class Publisher:
    def __init__(
        self,
        core: CoreClient,
        apk_path: Path,
        icon_path: Path,
        version: str,
        *,
        token_factory: Callable[[], str] | None = None,
    ) -> None:
        self.core = core
        self.apk_path = Path(apk_path).resolve()
        self.icon_path = Path(icon_path).resolve()
        self.version = validate_version(version)
        self.final_name = final_apk_name(version)
        self._token_factory = token_factory or (lambda: uuid.uuid4().hex[:16])

    def authenticate(self, username: str, password: str) -> None:
        if not username or not password:
            raise PublishError("credentials_missing")
        # Login data (including the cookie returned by the native core) is
        # intentionally discarded; the Rust global session owns it.
        self.core.call({"op": "login", "account": username, "password": password})

    def execute(self, *, dry_run: bool = False) -> PublishSummary:
        self._validate_inputs()
        token = self._token_factory()
        if not isinstance(token, str) or TOKEN_RE.fullmatch(token) is None:
            raise PublishError("staging_token_invalid")
        staging_name = f"LanzouMax-staging-{token}.apk"
        plans = self._preflight(staging_name)
        candidate_count = sum(len(plan.old_items) for plan in plans)
        staging_count = sum(len(plan.stale_staging) for plan in plans)
        if dry_run:
            return PublishSummary(
                True,
                len(plans),
                candidate_count,
                staging_count,
            )

        recovered_staging_count = self._recover_staging(plans)
        plans = self._preflight(staging_name)
        if any(plan.stale_staging for plan in plans):
            raise PublishError(
                "staging_recovery_unconfirmed",
                rollback_incomplete=True,
            )
        candidate_count = sum(len(plan.old_items) for plan in plans)
        self._harden_primary_folder_metadata(plans)

        recycled: list[CloudItem] = []
        with tempfile.TemporaryDirectory(
            prefix="lanzoumax-publish-", ignore_cleanup_errors=True
        ) as temp:
            temp_root = Path(temp)
            staging_apk = temp_root / staging_name
            try:
                shutil.copyfile(self.apk_path, staging_apk)
                if staging_apk.stat().st_size != self.apk_path.stat().st_size:
                    raise PublishError("staging_copy_failed")
                for plan in plans:
                    self._stage_target(
                        plan, staging_apk, staging_name, self.icon_path
                    )
                for plan in plans:
                    self._commit_target(plan, staging_name, recycled)
            except PublishError as error:
                rollback_failures = self._rollback(plans, staging_name, recycled)
                raise PublishError(
                    error.code,
                    rollback_incomplete=(
                        error.rollback_incomplete or rollback_failures > 0
                    ),
                ) from None
            except Exception:
                rollback_failures = self._rollback(plans, staging_name, recycled)
                raise PublishError(
                    "publish_failed",
                    rollback_incomplete=rollback_failures > 0,
                ) from None
        return PublishSummary(
            False,
            len(plans),
            candidate_count,
            recovered_staging_count,
        )

    def _harden_primary_folder_metadata(
        self, plans: Sequence[TargetPlan]
    ) -> None:
        primary = [plan.folder for plan in plans if plan.folder.name == PRIMARY_FOLDER]
        if len(primary) != 1:
            raise PublishError("primary_folder_not_unique")
        folder = primary[0]
        try:
            self.core.call(
                {
                    "op": "set_description",
                    "id": folder.id,
                    "isFolder": True,
                    "description": PRIMARY_FOLDER_DESCRIPTION,
                }
            )
        except PublishError as error:
            if error.code != "core_ambiguous_result":
                raise
            # The request may already have committed remotely. Never replay an
            # ambiguous metadata write; the bounded authenticated readback
            # below decides whether it is safe to continue.
        for attempt in range(VERIFICATION_ATTEMPTS):
            metadata = self.core.call(
                {"op": "share_info", "id": folder.id, "isFolder": True}
            )
            if (
                metadata.get("id") == folder.id
                and metadata.get("isFolder") is True
                and metadata.get("description") == PRIMARY_FOLDER_DESCRIPTION
            ):
                return
            if attempt + 1 < VERIFICATION_ATTEMPTS:
                time.sleep(VERIFICATION_INTERVAL_SECONDS)
        raise PublishError("primary_folder_description_unverified")

    def _validate_inputs(self) -> None:
        if (
            not self.apk_path.is_file()
            or self.apk_path.suffix.lower() != ".apk"
            or self.apk_path.stat().st_size <= 0
        ):
            raise PublishError("apk_invalid")
        try:
            icon_size = self.icon_path.stat().st_size
            if (
                not self.icon_path.is_file()
                or self.icon_path.suffix.lower() != ".jpg"
                or not 0 < icon_size < 100_000
            ):
                raise PublishError("icon_invalid")
            with self.icon_path.open("rb") as icon_file:
                start = icon_file.read(3)
                icon_file.seek(-2, os.SEEK_END)
                end = icon_file.read(2)
        except PublishError:
            raise
        except (OSError, ValueError):
            raise PublishError("icon_invalid")
        if start != b"\xff\xd8\xff" or end != b"\xff\xd9":
            raise PublishError("icon_invalid")

    def verify_readback(self, temp_root: Path) -> ReadbackSummary:
        """Download and byte-verify the unique final APK in both fixed targets."""

        self._validate_inputs()
        resolved_root = validate_readback_temp_root(temp_root)

        plans = self._preflight("readback-verification-only")
        selected: list[CloudItem] = []
        for plan in plans:
            if plan.stale_staging:
                raise PublishError("readback_staging_present")
            candidates = plan.old_items
            if len(candidates) != 1 or candidates[0].name != self.final_name:
                raise PublishError("readback_final_not_unique")
            selected.append(candidates[0])
        if len(selected) != len(TARGET_FOLDERS):
            raise PublishError("readback_target_count_invalid")

        expected_bytes = self.apk_path.stat().st_size
        expected_sha256 = sha256_file(self.apk_path)
        verified = 0
        try:
            with tempfile.TemporaryDirectory(
                prefix="lanzoumax-readback-",
                dir=resolved_root,
                ignore_cleanup_errors=False,
            ) as temporary:
                temporary_root = Path(temporary)
                for index, item in enumerate(selected):
                    destination = temporary_root / f"target-{index}.apk"
                    result = self.core.call(
                        {
                            "op": "download",
                            "id": item.id,
                            "name": self.final_name,
                            "destination": os.fspath(destination),
                        }
                    )
                    reported_path = result.get("path")
                    bytes_written = result.get("bytesWritten")
                    if (
                        not isinstance(reported_path, str)
                        or not isinstance(bytes_written, int)
                        or isinstance(bytes_written, bool)
                        or Path(reported_path).resolve(strict=False)
                        != destination.resolve(strict=False)
                        or not destination.is_file()
                        or destination.is_symlink()
                    ):
                        raise PublishError("readback_download_invalid")
                    if (
                        bytes_written != expected_bytes
                        or destination.stat().st_size != expected_bytes
                        or sha256_file(destination) != expected_sha256
                    ):
                        raise PublishError("readback_bytes_mismatch")
                    verified += 1
        except PublishError:
            raise
        except (OSError, RuntimeError, ValueError):
            raise PublishError("readback_cleanup_failed") from None

        try:
            local_changed = (
                self.apk_path.stat().st_size != expected_bytes
                or sha256_file(self.apk_path) != expected_sha256
            )
        except OSError:
            raise PublishError("readback_local_changed") from None
        if local_changed:
            raise PublishError("readback_local_changed")
        if verified != len(TARGET_FOLDERS):
            raise PublishError("readback_target_count_invalid")
        return ReadbackSummary(len(TARGET_FOLDERS), verified, expected_sha256)

    def _list_all(self, folder_id: str) -> list[CloudItem]:
        result: list[CloudItem] = []
        for page in range(1, MAX_LIST_PAGES + 1):
            data = self.core.call(
                {
                    "op": "list",
                    "folderId": folder_id,
                    "page": page,
                    "pageSize": 200,
                }
            )
            raw_items = data.get("items")
            has_more = data.get("hasMore")
            if not isinstance(raw_items, list) or not isinstance(has_more, bool):
                raise PublishError("list_response_invalid")
            for raw in raw_items:
                if not isinstance(raw, dict):
                    raise PublishError("cloud_item_invalid")
                result.append(CloudItem.from_json(raw))
                if len(result) > MAX_LIST_ITEMS:
                    raise PublishError("list_limit_exceeded")
            if not has_more:
                return result
        raise PublishError("list_page_limit_exceeded")

    def _preflight(self, staging_name: str) -> list[TargetPlan]:
        root_items = self._list_all(ROOT_ID)
        folders: dict[str, CloudItem] = {}
        for target_name in TARGET_FOLDERS:
            matches = [
                item
                for item in root_items
                if item.is_folder and item.name == target_name
            ]
            if len(matches) != 1:
                raise PublishError("target_folder_not_unique")
            folders[target_name] = matches[0]
        if len({item.id for item in folders.values()}) != len(TARGET_FOLDERS):
            raise PublishError("target_folder_not_unique")

        plans: list[TargetPlan] = []
        for target_name in TARGET_FOLDERS:
            folder = folders[target_name]
            items = self._list_all(folder.id)
            if any(item.is_folder and item.name == self.final_name for item in items):
                raise PublishError("final_name_conflict")
            plans.append(
                TargetPlan(
                    folder=folder,
                    old_items=select_replacement_candidates(
                        target_name, items, self.version
                    ),
                    stale_staging=[
                        item
                        for item in items
                        if not item.is_folder
                        and STAGING_APK_RE.fullmatch(item.name) is not None
                    ],
                )
            )
        return plans

    def _recover_staging(self, plans: Sequence[TargetPlan]) -> int:
        recovered = 0
        for plan in plans:
            if plan.folder.name not in TARGET_FOLDERS:
                raise PublishError("target_folder_invalid")
            for item in plan.stale_staging:
                if (
                    item.is_folder
                    or STAGING_APK_RE.fullmatch(item.name) is None
                ):
                    raise PublishError("staging_recovery_scope_invalid")
                try:
                    self.core.call(
                        {"op": "delete", "id": item.id, "isFolder": False}
                    )
                except PublishError:
                    # The authenticated absence readback below decides whether
                    # an ambiguous delete actually completed.
                    pass
                try:
                    absent = self._wait_for_item_absent(
                        plan.folder.id,
                        item.id,
                        item.name,
                    )
                except PublishError:
                    absent = False
                if not absent:
                    raise PublishError(
                        "staging_recovery_unconfirmed",
                        rollback_incomplete=True,
                    )
                recovered += 1
        return recovered

    def _wait_for_item_absent(
        self,
        folder_id: str,
        identifier: str | None,
        name: str,
    ) -> bool:
        absent_reads = 0
        for attempt in range(VERIFICATION_ATTEMPTS):
            current = self._list_all(folder_id)
            present = any(
                not item.is_folder
                and (
                    (identifier is not None and item.id == identifier)
                    or item.name == name
                )
                for item in current
            )
            if present:
                absent_reads = 0
            else:
                absent_reads += 1
                if absent_reads >= ABSENCE_CONFIRMATIONS:
                    return True
            if attempt + 1 < VERIFICATION_ATTEMPTS:
                time.sleep(VERIFICATION_INTERVAL_SECONDS)
        return False

    def _stage_target(
        self,
        plan: TargetPlan,
        staging_apk: Path,
        staging_name: str,
        icon_path: Path,
    ) -> None:
        plan.upload_attempted = True
        data = self.core.call(
            {
                "op": "upload",
                "folderId": plan.folder.id,
                "path": os.fspath(staging_apk),
                "compatWrap": False,
                "kind": "file",
            }
        )
        identifier = data.get("id")
        if isinstance(identifier, str) and identifier:
            plan.stage = CloudItem(identifier, staging_name, False, False, None)
        if data.get("uploadedName") != staging_name:
            raise PublishError("staging_upload_invalid")
        if plan.stage is None:
            plan.stage = self._locate_stage(plan.folder.id, staging_name)

        self.core.call(
            {
                "op": "set_description",
                "id": plan.stage.id,
                "isFolder": False,
                "description": DESCRIPTION,
            }
        )
        self.core.call(
            {
                "op": "set_icon",
                "fileId": plan.stage.id,
                "path": os.fspath(icon_path),
            }
        )
        confirmed, _ = self._wait_for_verified_file(
            plan.folder.id,
            plan.stage.id,
            staging_name,
            "staging_verify",
        )
        plan.stage = confirmed

    def _locate_stage(self, folder_id: str, staging_name: str) -> CloudItem:
        matches = [
            item
            for item in self._list_all(folder_id)
            if not item.is_folder and item.name == staging_name
        ]
        if len(matches) != 1:
            raise PublishError("staging_not_unique")
        return matches[0]

    def _wait_for_verified_file(
        self,
        folder_id: str,
        identifier: str,
        expected_name: str,
        failure_prefix: str,
    ) -> tuple[CloudItem, list[CloudItem]]:
        failure_reason = "name_absent"
        for attempt in range(VERIFICATION_ATTEMPTS):
            current = self._list_all(folder_id)
            matches = [
                item
                for item in current
                if not item.is_folder and item.name == expected_name
            ]
            if len(matches) > 1:
                raise PublishError(f"{failure_prefix}_duplicate")
            if len(matches) == 1:
                item = matches[0]
                if item.id != identifier:
                    failure_reason = "id_mismatch"
                elif item.has_custom_icon is False:
                    failure_reason = "icon_false"
                elif item.has_custom_icon is not True:
                    failure_reason = "icon_unknown"
                else:
                    metadata = self.core.call(
                        {
                            "op": "share_info",
                            "id": identifier,
                            "isFolder": False,
                        }
                    )
                    metadata_id = metadata.get("id")
                    metadata_folder = metadata.get("isFolder")
                    metadata_description = metadata.get("description")
                    if (
                        not isinstance(metadata_id, str)
                        or not isinstance(metadata_folder, bool)
                        or not isinstance(metadata_description, str)
                    ):
                        failure_reason = "share_schema"
                    elif metadata_id != identifier:
                        failure_reason = "share_id"
                    elif metadata_folder is not False:
                        failure_reason = "share_kind"
                    elif metadata_description != DESCRIPTION:
                        failure_reason = "description"
                    else:
                        return (
                            CloudItem(
                                item.id,
                                item.name,
                                False,
                                True,
                                DESCRIPTION,
                            ),
                            current,
                        )
            if attempt + 1 < VERIFICATION_ATTEMPTS:
                time.sleep(VERIFICATION_INTERVAL_SECONDS)
        raise PublishError(f"{failure_prefix}_{failure_reason}")

    def _commit_target(
        self,
        plan: TargetPlan,
        staging_name: str,
        recycled: list[CloudItem],
    ) -> None:
        if plan.stage is None:
            raise PublishError("staging_missing")
        _, current = self._wait_for_verified_file(
            plan.folder.id,
            plan.stage.id,
            staging_name,
            "staging_verify",
        )
        current_old = select_replacement_candidates(
            plan.folder.name, current, self.version
        )
        expected = {(item.id, item.name) for item in plan.old_items}
        observed = {(item.id, item.name) for item in current_old}
        if observed != expected:
            raise PublishError("candidate_set_changed")

        if plan.folder.name not in TARGET_FOLDERS:
            raise PublishError("replacement_scope_invalid")
        for item in plan.old_items:
            in_scope = (
                plan.folder.name == PRIMARY_FOLDER
                and is_same_version_replacement(item.name, self.version)
            ) or (
                plan.folder.name == LIBRARY_FOLDER
                and is_library_replacement(item.name)
            )
            if not in_scope:
                raise PublishError("replacement_scope_invalid")
            try:
                self.core.call(
                    {"op": "delete", "id": item.id, "isFolder": False}
                )
                recycled.append(item)
            except PublishError as error:
                if self._is_in_recycle(item.id):
                    recycled.append(item)
                    if error.code == "core_ambiguous_result":
                        # The delete committed but the response was ambiguous.
                        # Recycle readback is authoritative and preserves
                        # rollback capability, so continuing is safe.
                        continue
                    raise
                raise PublishError(error.code, rollback_incomplete=True) from None
        try:
            self.core.call(
                {
                    "op": "rename",
                    "id": plan.stage.id,
                    "isFolder": False,
                    "name": self.final_name,
                }
            )
        except PublishError as error:
            if error.code != "core_ambiguous_result":
                raise
            # Never replay an ambiguous rename: verified final-name readback
            # below decides whether the mutation actually committed.
        self._wait_for_verified_file(
            plan.folder.id,
            plan.stage.id,
            self.final_name,
            "publish_verify",
        )

    def _is_in_recycle(self, identifier: str) -> bool:
        try:
            data = self.core.call({"op": "recycle_list"})
            raw_items = data.get("items")
            if not isinstance(raw_items, list) or len(raw_items) > MAX_RECYCLE_ITEMS:
                return False
            for raw in raw_items:
                if isinstance(raw, dict) and raw.get("id") == identifier:
                    return True
        except PublishError:
            return False
        return False

    def _rollback(
        self,
        plans: Sequence[TargetPlan],
        staging_name: str,
        recycled: Sequence[CloudItem],
    ) -> int:
        failures = 0
        for plan in reversed(plans):
            stage = plan.stage
            if stage is None:
                if not plan.upload_attempted:
                    continue
                try:
                    matches = [
                        item
                        for item in self._list_all(plan.folder.id)
                        if not item.is_folder and item.name == staging_name
                    ]
                except PublishError:
                    failures += 1
                    continue
                if not matches:
                    try:
                        absent = self._wait_for_item_absent(
                            plan.folder.id,
                            None,
                            staging_name,
                        )
                    except PublishError:
                        absent = False
                    if not absent:
                        failures += 1
                    continue
                if len(matches) != 1:
                    failures += 1
                    continue
                stage = matches[0]
            if stage is None:
                continue
            try:
                self.core.call(
                    {"op": "delete", "id": stage.id, "isFolder": False}
                )
            except PublishError:
                pass
            try:
                absent = self._wait_for_item_absent(
                    plan.folder.id,
                    stage.id,
                    staging_name,
                )
            except PublishError:
                absent = False
            if not absent:
                failures += 1

        restore_targets: dict[str, tuple[CloudItem, CloudItem]] = {}
        for plan in plans:
            for item in plan.old_items:
                if item.id in restore_targets:
                    failures += 1
                    continue
                restore_targets[item.id] = (item, plan.folder)
        processed: set[str] = set()
        for item in reversed(recycled):
            if item.id in processed:
                continue
            processed.add(item.id)
            restore_target = restore_targets.get(item.id)
            if restore_target is None:
                failures += 1
                continue
            expected_item, target_folder = restore_target
            try:
                self.core.call(
                    {"op": "recycle_restore", "id": item.id, "isFolder": False}
                )
            except PublishError:
                failures += 1
                continue
            try:
                self.core.call(
                    {
                        "op": "move",
                        "id": item.id,
                        "isFolder": False,
                        "targetId": target_folder.id,
                    }
                )
            except PublishError:
                failures += 1
                continue
            try:
                restored_matches = [
                    restored_item
                    for restored_item in self._list_all(target_folder.id)
                    if not restored_item.is_folder
                    and restored_item.id == expected_item.id
                    and restored_item.name == expected_item.name
                ]
            except PublishError:
                failures += 1
                continue
            if len(restored_matches) != 1:
                failures += 1
        return failures


def build_parser() -> argparse.ArgumentParser:
    parser = SafeArgumentParser(
        description="Publish LanzouMax through the LanzouYOU Rust core."
    )
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--icon", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--core-dll", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--verify-readback", action="store_true")
    parser.add_argument("--readback-temp-root", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        args = build_parser().parse_args(argv)
    except PublishError as error:
        print(f"error_code={error.code};rollback=complete", file=sys.stderr)
        return 2
    try:
        if args.verify_readback != (args.readback_temp_root is not None):
            raise PublishError("readback_temp_invalid")
        readback_temp_root = (
            validate_readback_temp_root(args.readback_temp_root)
            if args.verify_readback
            else None
        )
    except PublishError as error:
        print(f"error_code={error.code};rollback=complete", file=sys.stderr)
        return 2
    username = os.environ.pop("LANZOUYOU_USERNAME", "")
    password = os.environ.pop("LANZOUYOU_PASSWORD", "")
    try:
        if not username or not password:
            raise PublishError("credentials_missing")
        if not args.core_dll.is_file():
            raise PublishError("core_unavailable")
        core = RustCore(args.core_dll.resolve())
        publisher = Publisher(core, args.apk, args.icon, args.version)
        publisher.authenticate(username, password)
        # Drop the Python references as soon as login has copied them into the
        # native request/session. Python strings are immutable, so this is
        # best-effort lifetime reduction rather than guaranteed zeroization.
        username = ""
        password = ""
        if args.verify_readback:
            summary = publisher.verify_readback(readback_temp_root)
        else:
            summary = publisher.execute(dry_run=args.dry_run)
    except PublishError as error:
        rollback = "incomplete" if error.rollback_incomplete else "complete"
        print(f"error_code={error.code};rollback={rollback}", file=sys.stderr)
        return 2
    except Exception:
        print("error_code=publish_failed;rollback=incomplete", file=sys.stderr)
        return 3
    finally:
        username = ""
        password = ""
    print(summary.safe_line())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
