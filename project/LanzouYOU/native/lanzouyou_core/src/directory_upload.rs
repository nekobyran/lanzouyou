use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Component, Path, PathBuf},
};

use serde::Serialize;
use serde_json::Value;

use crate::{
    error::{CoreError, CoreResult},
    icon,
    model::UploadKind,
    operation::OperationHandle,
    session::SessionClient,
    transfer::DirectoryUploadedFile,
    validation,
};

pub(crate) const MAX_DIRECTORY_UPLOAD_DEPTH: usize = 64;
pub(crate) const MAX_DIRECTORY_UPLOAD_ITEMS: usize = 10_000;

#[derive(Clone, Debug, PartialEq, Eq)]
struct DirectoryPlan {
    root: PathBuf,
    root_name: String,
    entries: Vec<PlannedEntry>,
    total_files: usize,
    total_bytes: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct PlannedEntry {
    absolute_path: PathBuf,
    relative_path: PathBuf,
    kind: PlannedEntryKind,
    bytes: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PlannedEntryKind {
    Directory,
    File,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct DirectoryUploadFailure {
    relative_path: String,
    stage: &'static str,
    code: &'static str,
    message: &'static str,
    retriable: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct DirectoryUploadResult {
    state: &'static str,
    atomic: bool,
    partial_remote_retained: bool,
    root_name: String,
    remote_root_id: Option<String>,
    total_directories: usize,
    created_directories: usize,
    total_files: usize,
    processed_files: usize,
    uploaded_files: usize,
    total_bytes: u64,
    uploaded_bytes: u64,
    auto_apk_icons: bool,
    icon_bound_files: usize,
    failures: Vec<DirectoryUploadFailure>,
}

trait DirectoryUploadBackend {
    fn create_folder(&self, parent_id: &str, name: &str) -> CoreResult<String>;

    #[allow(clippy::too_many_arguments)]
    fn upload_file(
        &self,
        folder_id: &str,
        path: &Path,
        compat_wrap: bool,
        kind: UploadKind,
        operation: Option<&OperationHandle>,
        base_uploaded_bytes: u64,
        aggregate_total_bytes: u64,
        planned_original_bytes: u64,
        allowed_root: &Path,
    ) -> CoreResult<DirectoryUploadedFile>;

    fn prepare_icon(&self, source_path: &Path) -> CoreResult<PathBuf>;

    fn set_icon(&self, file_id: &str, icon_path: &Path) -> CoreResult<()>;
}

fn execute_directory_plan<B: DirectoryUploadBackend>(
    backend: &B,
    cloud_parent_id: &str,
    plan: DirectoryPlan,
    compat_wrap: bool,
    kind: UploadKind,
    auto_apk_icons: bool,
    operation: Option<&OperationHandle>,
) -> CoreResult<DirectoryUploadResult> {
    let total_directories = plan
        .entries
        .iter()
        .filter(|entry| entry.kind == PlannedEntryKind::Directory)
        .count()
        .saturating_add(1);
    let mut result = DirectoryUploadResult {
        state: "succeeded",
        atomic: false,
        partial_remote_retained: true,
        root_name: plan.root_name.clone(),
        remote_root_id: None,
        total_directories,
        created_directories: 0,
        total_files: plan.total_files,
        processed_files: 0,
        uploaded_files: 0,
        total_bytes: plan.total_bytes,
        uploaded_bytes: 0,
        auto_apk_icons,
        icon_bound_files: 0,
        failures: Vec::new(),
    };
    if let Some(operation) = operation {
        operation.set_total_units(plan.total_files);
        operation.set_transfer_progress(0, plan.total_bytes);
        if operation.check_cancelled().is_err() {
            operation.finish_cancelled();
            result.state = "cancelled";
            return Ok(result);
        }
    }
    verify_root_unchanged(&plan.root)?;
    let root_id = backend.create_folder(cloud_parent_id, &plan.root_name)?;
    result.remote_root_id = Some(root_id.clone());
    result.created_directories = 1;
    let mut remote_folders = HashMap::from([(PathBuf::new(), root_id)]);
    let mut aggregate_wire_total = plan.total_bytes;
    let mut uploaded_wire_bytes = 0_u64;

    for entry in &plan.entries {
        if operation.is_some_and(OperationHandle::is_cancellation_requested) {
            result.state = "cancelled";
            break;
        }
        let parent = entry
            .relative_path
            .parent()
            .unwrap_or_else(|| Path::new(""));
        let Some(parent_id) = remote_folders.get(parent).cloned() else {
            let stage = "parent_unavailable";
            result.failures.push(directory_failure(
                entry,
                stage,
                &CoreError::new(stage, "父目录不可用", false),
            ));
            if entry.kind == PlannedEntryKind::File {
                result.processed_files = result.processed_files.saturating_add(1);
                if let Some(operation) = operation {
                    operation.complete_unit(result.uploaded_files);
                }
            }
            continue;
        };
        if let Err(error) = verify_planned_entry(&plan.root, entry) {
            let stage = match entry.kind {
                PlannedEntryKind::Directory => "create_folder",
                PlannedEntryKind::File => "upload_file",
            };
            result
                .failures
                .push(directory_failure(entry, stage, &error));
            if entry.kind == PlannedEntryKind::File {
                result.processed_files = result.processed_files.saturating_add(1);
                if let Some(operation) = operation {
                    operation.complete_unit(result.uploaded_files);
                }
            }
            continue;
        }

        match entry.kind {
            PlannedEntryKind::Directory => {
                let name = entry_name(entry)?;
                match backend.create_folder(&parent_id, name) {
                    Ok(id) => {
                        remote_folders.insert(entry.relative_path.clone(), id);
                        result.created_directories = result.created_directories.saturating_add(1);
                    }
                    Err(error) => {
                        result
                            .failures
                            .push(directory_failure(entry, "create_folder", &error))
                    }
                }
            }
            PlannedEntryKind::File => {
                let uploaded = backend.upload_file(
                    &parent_id,
                    &entry.absolute_path,
                    compat_wrap,
                    kind,
                    operation,
                    uploaded_wire_bytes,
                    aggregate_wire_total,
                    entry.bytes,
                    &plan.root,
                );
                match uploaded {
                    Ok(uploaded) => {
                        result.processed_files = result.processed_files.saturating_add(1);
                        result.uploaded_files = result.uploaded_files.saturating_add(1);
                        result.uploaded_bytes = result
                            .uploaded_bytes
                            .saturating_add(uploaded.original_bytes);
                        uploaded_wire_bytes =
                            uploaded_wire_bytes.saturating_add(uploaded.uploaded_bytes);
                        aggregate_wire_total = uploaded.aggregate_total_bytes;
                        if let Some(operation) = operation {
                            operation.complete_unit(result.uploaded_files);
                        }
                        if operation.is_some_and(OperationHandle::is_cancellation_requested) {
                            result.state = "cancelled";
                            break;
                        }
                        if auto_apk_icons && is_apk(&entry.absolute_path) {
                            match backend.prepare_icon(&entry.absolute_path) {
                                Ok(path) => {
                                    let cleanup = PreparedIconCleanup::new(path);
                                    if operation
                                        .is_some_and(OperationHandle::is_cancellation_requested)
                                    {
                                        result.state = "cancelled";
                                        break;
                                    }
                                    match backend.set_icon(&uploaded.id, cleanup.path()) {
                                        Ok(()) => {
                                            result.icon_bound_files =
                                                result.icon_bound_files.saturating_add(1)
                                        }
                                        Err(error) if error.code == "cancelled" => {
                                            result.state = "cancelled";
                                            break;
                                        }
                                        Err(error) => result
                                            .failures
                                            .push(directory_failure(entry, "set_icon", &error)),
                                    }
                                }
                                Err(error) if error.code == "cancelled" => {
                                    result.state = "cancelled";
                                    break;
                                }
                                Err(error) => result.failures.push(directory_failure(
                                    entry,
                                    "prepare_icon",
                                    &error,
                                )),
                            }
                        }
                    }
                    Err(error) if error.code == "cancelled" => {
                        result.state = "cancelled";
                        break;
                    }
                    Err(error) => {
                        result.processed_files = result.processed_files.saturating_add(1);
                        result
                            .failures
                            .push(directory_failure(entry, "upload_file", &error));
                        if let Some(operation) = operation {
                            operation.complete_unit(result.uploaded_files);
                        }
                    }
                }
            }
        }
    }
    if result.state != "cancelled" && !result.failures.is_empty() {
        result.state = "partial";
    }
    if let Some(operation) = operation {
        match result.state {
            "cancelled" => operation.finish_cancelled(),
            "partial" => operation.finish_failed(),
            _ => operation.finish_success(),
        }
    }
    Ok(result)
}

impl SessionClient {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn upload_directory(
        &self,
        folder_id: &str,
        path: &str,
        compat_wrap: bool,
        kind: UploadKind,
        auto_apk_icons: bool,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<Value> {
        validation::id(folder_id, "folderId")?;
        let plan = scan_directory(Path::new(path))?;
        let result = execute_directory_plan(
            self,
            folder_id,
            plan,
            compat_wrap,
            kind,
            auto_apk_icons,
            operation,
        )?;
        serde_json::to_value(result)
            .map_err(|_| CoreError::new("internal_error", "目录上传结果序列化失败", false))
    }
}

impl DirectoryUploadBackend for SessionClient {
    fn create_folder(&self, parent_id: &str, name: &str) -> CoreResult<String> {
        self.mkdir_id(parent_id, name, "")
    }

    fn upload_file(
        &self,
        folder_id: &str,
        path: &Path,
        compat_wrap: bool,
        kind: UploadKind,
        operation: Option<&OperationHandle>,
        base_uploaded_bytes: u64,
        aggregate_total_bytes: u64,
        planned_original_bytes: u64,
        allowed_root: &Path,
    ) -> CoreResult<DirectoryUploadedFile> {
        match operation {
            Some(operation) => self.upload_directory_file_with_operation(
                folder_id,
                path,
                compat_wrap,
                kind,
                operation,
                base_uploaded_bytes,
                aggregate_total_bytes,
                planned_original_bytes,
                allowed_root,
            ),
            None => {
                validate_file_for_upload(path, allowed_root, planned_original_bytes)?;
                let value = self.upload(
                    folder_id,
                    path.to_str()
                        .ok_or_else(|| CoreError::invalid("文件路径不是有效 UTF-8"))?,
                    compat_wrap,
                    kind,
                )?;
                let id = value["id"]
                    .as_str()
                    .ok_or_else(|| {
                        CoreError::new("missing_uploaded_file_id", "无法确认上传文件 ID", false)
                    })?
                    .to_owned();
                let original_bytes = value["originalBytes"]
                    .as_u64()
                    .unwrap_or(planned_original_bytes);
                let uploaded_bytes = value["uploadedBytes"].as_u64().unwrap_or(original_bytes);
                Ok(DirectoryUploadedFile {
                    id,
                    original_bytes,
                    uploaded_bytes,
                    aggregate_total_bytes: aggregate_total_bytes
                        .saturating_sub(planned_original_bytes)
                        .saturating_add(uploaded_bytes),
                })
            }
        }
    }

    fn prepare_icon(&self, source_path: &Path) -> CoreResult<PathBuf> {
        let value = icon::prepare_icon(
            source_path
                .to_str()
                .ok_or_else(|| CoreError::invalid("APK 路径不是有效 UTF-8"))?,
            None,
        )?;
        value["path"]
            .as_str()
            .map(PathBuf::from)
            .ok_or_else(|| CoreError::new("invalid_icon_result", "图标处理结果无效", false))
    }

    fn set_icon(&self, file_id: &str, icon_path: &Path) -> CoreResult<()> {
        self.set_icon(
            file_id,
            icon_path
                .to_str()
                .ok_or_else(|| CoreError::invalid("图标路径不是有效 UTF-8"))?,
        )?;
        Ok(())
    }
}

fn scan_directory(root: &Path) -> CoreResult<DirectoryPlan> {
    scan_directory_with_limits(root, MAX_DIRECTORY_UPLOAD_DEPTH, MAX_DIRECTORY_UPLOAD_ITEMS)
}

fn scan_directory_with_limits(
    root: &Path,
    max_depth: usize,
    max_items: usize,
) -> CoreResult<DirectoryPlan> {
    if !root.is_absolute()
        || root
            .components()
            .any(|component| matches!(component, Component::ParentDir | Component::CurDir))
    {
        return Err(CoreError::invalid("path 必须是无相对片段的绝对目录"));
    }
    reject_reparse_ancestors(root)?;
    let root_metadata = fs::symlink_metadata(root)?;
    if is_link_or_reparse(&root_metadata) {
        return Err(unsafe_local_path());
    }
    if !root_metadata.is_dir() {
        return Err(CoreError::invalid("path 必须指向本地目录"));
    }
    let root = fs::canonicalize(root)?;
    let root_name = root
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| CoreError::invalid("所选目录缺少可上传的名称"))?
        .to_owned();
    validate_upload_name(&root_name)?;

    let mut entries = Vec::new();
    let mut stack = vec![(root.clone(), PathBuf::new(), 0_usize)];
    let mut seen = HashSet::from([root.clone()]);
    let mut total_files = 0_usize;
    let mut total_bytes = 0_u64;
    while let Some((directory, relative_directory, depth)) = stack.pop() {
        for child in fs::read_dir(&directory)? {
            let child = child?;
            if entries.len() >= max_items {
                return Err(CoreError::new(
                    "directory_item_limit",
                    format!("目录项目数不能超过 {max_items}"),
                    false,
                ));
            }
            let name = child
                .file_name()
                .to_str()
                .ok_or_else(|| CoreError::invalid("目录包含无法上传的非 Unicode 名称"))?
                .to_owned();
            validate_upload_name(&name)?;
            let child_depth = depth.saturating_add(1);
            if child_depth > max_depth {
                return Err(CoreError::new(
                    "directory_depth_limit",
                    format!("目录深度不能超过 {max_depth}"),
                    false,
                ));
            }
            let path = child.path();
            let metadata = fs::symlink_metadata(&path)?;
            if is_link_or_reparse(&metadata) {
                return Err(unsafe_local_path());
            }
            let canonical = fs::canonicalize(&path)?;
            if !canonical.starts_with(&root) || !seen.insert(canonical.clone()) {
                return Err(unsafe_local_path());
            }
            let relative_path = relative_directory.join(&name);
            let (kind, bytes) = if metadata.is_dir() {
                stack.push((canonical.clone(), relative_path.clone(), child_depth));
                (PlannedEntryKind::Directory, 0)
            } else if metadata.is_file() {
                total_files = total_files.saturating_add(1);
                total_bytes = total_bytes.checked_add(metadata.len()).ok_or_else(|| {
                    CoreError::new(
                        "directory_byte_overflow",
                        "目录文件总大小超出支持范围",
                        false,
                    )
                })?;
                (PlannedEntryKind::File, metadata.len())
            } else {
                return Err(unsafe_local_path());
            };
            entries.push(PlannedEntry {
                absolute_path: canonical,
                relative_path,
                kind,
                bytes,
            });
        }
    }
    entries.sort_by(|first, second| {
        let first_depth = first.relative_path.components().count();
        let second_depth = second.relative_path.components().count();
        first_depth
            .cmp(&second_depth)
            .then_with(|| entry_order(first.kind).cmp(&entry_order(second.kind)))
            .then_with(|| first.relative_path.cmp(&second.relative_path))
    });
    Ok(DirectoryPlan {
        root,
        root_name,
        entries,
        total_files,
        total_bytes,
    })
}

fn entry_order(kind: PlannedEntryKind) -> u8 {
    match kind {
        PlannedEntryKind::Directory => 0,
        PlannedEntryKind::File => 1,
    }
}

fn validate_upload_name(name: &str) -> CoreResult<()> {
    validation::safe_filename(name)
}

fn reject_reparse_ancestors(path: &Path) -> CoreResult<()> {
    for ancestor in path.ancestors() {
        let metadata = match fs::symlink_metadata(ancestor) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };
        if is_link_or_reparse(&metadata) {
            return Err(unsafe_local_path());
        }
    }
    Ok(())
}

fn is_link_or_reparse(metadata: &fs::Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if is_windows_reparse_attributes(metadata.file_attributes()) {
            return true;
        }
    }
    false
}

fn is_windows_reparse_attributes(attributes: u32) -> bool {
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;
    attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

fn unsafe_local_path() -> CoreError {
    CoreError::new(
        "unsafe_local_path",
        "目录包含链接、重解析点或越界路径，已在上传前拒绝",
        false,
    )
}

fn verify_root_unchanged(root: &Path) -> CoreResult<()> {
    reject_reparse_ancestors(root)?;
    let metadata = fs::symlink_metadata(root)?;
    if is_link_or_reparse(&metadata) || !metadata.is_dir() {
        return Err(unsafe_local_path());
    }
    if fs::canonicalize(root)? != root {
        return Err(unsafe_local_path());
    }
    Ok(())
}

fn verify_planned_entry(root: &Path, entry: &PlannedEntry) -> CoreResult<()> {
    reject_reparse_ancestors(&entry.absolute_path)?;
    let metadata = fs::symlink_metadata(&entry.absolute_path)?;
    if is_link_or_reparse(&metadata) {
        return Err(unsafe_local_path());
    }
    let canonical = fs::canonicalize(&entry.absolute_path)?;
    if !canonical.starts_with(root) {
        return Err(unsafe_local_path());
    }
    if canonical != entry.absolute_path {
        return Err(local_file_changed());
    }
    match entry.kind {
        PlannedEntryKind::Directory if !metadata.is_dir() => Err(local_file_changed()),
        PlannedEntryKind::File if !metadata.is_file() || metadata.len() != entry.bytes => {
            Err(local_file_changed())
        }
        _ => Ok(()),
    }
}

fn validate_file_for_upload(path: &Path, root: &Path, expected_bytes: u64) -> CoreResult<()> {
    let entry = PlannedEntry {
        absolute_path: path.to_path_buf(),
        relative_path: path
            .strip_prefix(root)
            .map(Path::to_path_buf)
            .map_err(|_| unsafe_local_path())?,
        kind: PlannedEntryKind::File,
        bytes: expected_bytes,
    };
    verify_planned_entry(root, &entry)
}

fn local_file_changed() -> CoreError {
    CoreError::new(
        "local_file_changed",
        "本地项目在扫描后发生变化，请重新选择目录",
        false,
    )
}

fn entry_name(entry: &PlannedEntry) -> CoreResult<&str> {
    entry
        .relative_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| CoreError::invalid("目录项目名称不是有效 UTF-8"))
}

fn relative_display_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn directory_failure(
    entry: &PlannedEntry,
    stage: &'static str,
    error: &CoreError,
) -> DirectoryUploadFailure {
    let message = match stage {
        "create_folder" => "未能创建云端目录",
        "upload_file" => "未能上传该文件",
        "prepare_icon" => "未能从 APK 提取合规图标",
        "set_icon" => "文件已上传，但未能设置图标",
        "parent_unavailable" => "上级云端目录不可用，已跳过该项目",
        _ => "该项目未完成",
    };
    DirectoryUploadFailure {
        relative_path: relative_display_path(&entry.relative_path),
        stage,
        code: error.code,
        message,
        retriable: error.retriable,
    }
}

fn is_apk(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("apk"))
}

struct PreparedIconCleanup {
    path: PathBuf,
}

impl PreparedIconCleanup {
    fn new(path: PathBuf) -> Self {
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for PreparedIconCleanup {
    fn drop(&mut self) {
        cleanup_prepared_icon(&self.path);
    }
}

fn cleanup_prepared_icon(path: &Path) {
    let file_name = match path.file_name().and_then(|name| name.to_str()) {
        Some(name) if name.starts_with("prepared-") && name.ends_with(".png") => name,
        _ => return,
    };
    if file_name.len() > 255 {
        return;
    }
    let expected_root = std::env::temp_dir().join("lanzouyou_icons");
    let Ok(expected_root) = fs::canonicalize(expected_root) else {
        return;
    };
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return;
    };
    if is_link_or_reparse(&metadata) || !metadata.is_file() {
        return;
    }
    let Ok(canonical) = fs::canonicalize(path) else {
        return;
    };
    if canonical.parent() != Some(expected_root.as_path()) {
        return;
    }
    let _ = fs::remove_file(canonical);
}

#[cfg(test)]
mod tests {
    use std::{cell::RefCell, fs, path::Path};

    use tempfile::tempdir;

    use super::*;

    static TEST_ICON_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

    #[test]
    fn test_scan_directory_preserves_hierarchy_and_sorts_parents_first() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("软件合集");
        fs::create_dir_all(root.join("工具/网络")).unwrap();
        fs::write(root.join("根目录.txt"), b"root").unwrap();
        fs::write(root.join("工具/说明.txt"), b"docs").unwrap();
        fs::write(root.join("工具/网络/client.apk"), b"apk").unwrap();

        let plan = scan_directory(&root).unwrap();

        assert!(plan.root.is_absolute());
        assert_eq!(plan.root_name, "软件合集");
        assert_eq!(plan.total_files, 3);
        assert_eq!(plan.total_bytes, 11);
        let rows = plan
            .entries
            .iter()
            .map(|entry| {
                (
                    entry.relative_path.to_string_lossy().replace('\\', "/"),
                    entry.kind,
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(
            rows,
            vec![
                ("工具".to_owned(), PlannedEntryKind::Directory),
                ("根目录.txt".to_owned(), PlannedEntryKind::File),
                ("工具/网络".to_owned(), PlannedEntryKind::Directory),
                ("工具/说明.txt".to_owned(), PlannedEntryKind::File),
                ("工具/网络/client.apk".to_owned(), PlannedEntryKind::File),
            ]
        );
    }

    #[test]
    fn test_scan_directory_rejects_relative_root_and_unsafe_remote_names() {
        assert_eq!(
            scan_directory(Path::new("relative/folder"))
                .unwrap_err()
                .code,
            "invalid_argument"
        );

        let temp = tempdir().unwrap();
        let root = temp.path().join("safe-root");
        fs::create_dir_all(&root).unwrap();
        #[cfg(not(windows))]
        {
            fs::write(root.join("name. "), b"bad").unwrap();
            assert_eq!(scan_directory(&root).unwrap_err().code, "invalid_argument");
        }
        #[cfg(windows)]
        {
            // Win32 normalizes trailing dots/spaces before a test fixture can
            // be created. The exact validator used by the scanner must still
            // reject the remote name before any network operation.
            assert_eq!(
                validate_upload_name("name. ").unwrap_err().code,
                "invalid_argument"
            );
        }
    }

    #[test]
    fn test_scan_directory_enforces_depth_and_item_limits_before_remote_work() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("root");
        fs::create_dir_all(root.join("a/b/c")).unwrap();
        assert_eq!(
            scan_directory_with_limits(&root, 2, 100).unwrap_err().code,
            "directory_depth_limit"
        );

        let shallow = temp.path().join("shallow");
        fs::create_dir_all(&shallow).unwrap();
        fs::write(shallow.join("1.txt"), b"1").unwrap();
        fs::write(shallow.join("2.txt"), b"2").unwrap();
        assert_eq!(
            scan_directory_with_limits(&shallow, 64, 1)
                .unwrap_err()
                .code,
            "directory_item_limit"
        );
    }

    #[test]
    fn test_scan_directory_rejects_symlink_or_reparse_escape() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("root");
        let outside = temp.path().join("outside.txt");
        fs::create_dir_all(&root).unwrap();
        fs::write(&outside, b"secret").unwrap();
        let link = root.join("escape.txt");

        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, &link).unwrap();
        #[cfg(windows)]
        if std::os::windows::fs::symlink_file(&outside, &link).is_err() {
            // Symlink creation can be disabled by local Windows policy. Other
            // scanner tests still exercise the same metadata path.
            return;
        }

        let error = scan_directory(&root).unwrap_err();
        assert_eq!(error.code, "unsafe_local_path");
    }

    #[test]
    fn test_windows_reparse_attribute_is_rejected_even_when_not_symlink() {
        assert!(is_windows_reparse_attributes(0x0400));
        assert!(is_windows_reparse_attributes(0x0420));
        assert!(!is_windows_reparse_attributes(0x0020));
    }

    #[test]
    fn test_upload_name_validation_rejects_ambiguous_and_reserved_components() {
        for value in [".", "..", "name. ", "CON", "LPT1.log", "bad\u{1}name"] {
            assert!(
                validate_upload_name(value).is_err(),
                "accepted unsafe upload component: {value:?}"
            );
        }
        assert!(validate_upload_name("合法软件.apk").is_ok());
    }

    #[test]
    fn test_execute_directory_plan_preserves_empty_folders_and_only_icons_apks() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("软件合集");
        fs::create_dir_all(root.join("工具/空目录")).unwrap();
        fs::write(root.join("工具/App.APK"), b"apk").unwrap();
        fs::write(root.join("说明.txt"), b"text").unwrap();
        let plan = scan_directory(&root).unwrap();
        let backend = FakeDirectoryBackend::default();
        let operation = test_operation("directory-execute-success");

        let result = execute_directory_plan(
            &backend,
            "-1",
            plan,
            false,
            UploadKind::Auto,
            true,
            Some(&operation),
        )
        .unwrap();

        assert_eq!(result.state, "succeeded");
        assert!(!result.atomic);
        assert!(result.partial_remote_retained);
        assert_eq!(result.total_directories, 3);
        assert_eq!(result.created_directories, 3);
        assert_eq!(result.total_files, 2);
        assert_eq!(result.uploaded_files, 2);
        assert_eq!(result.icon_bound_files, 1);
        assert!(result.failures.is_empty());
        assert_eq!(backend.created.borrow().len(), 3);
        assert_eq!(backend.uploaded.borrow().len(), 2);
        assert_eq!(backend.prepared_icons.borrow().len(), 1);
        assert_eq!(backend.bound_icons.borrow().len(), 1);
        assert!(!backend.prepared_icons.borrow()[0].exists());
        assert_eq!(
            operation.status().state,
            crate::operation::OperationState::Succeeded
        );
        crate::operation::forget("directory-execute-success").unwrap();
    }

    #[test]
    fn test_execute_directory_plan_partial_failure_retains_remote_root_and_continues() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("bad.apk"), b"bad").unwrap();
        fs::write(root.join("good.apk"), b"good").unwrap();
        let plan = scan_directory(&root).unwrap();
        let backend = FakeDirectoryBackend {
            fail_upload_name: Some("bad.apk".to_owned()),
            ..FakeDirectoryBackend::default()
        };
        let operation = test_operation("directory-execute-partial");

        let result = execute_directory_plan(
            &backend,
            "-1",
            plan,
            false,
            UploadKind::Auto,
            false,
            Some(&operation),
        )
        .unwrap();

        assert_eq!(result.state, "partial");
        assert!(result.remote_root_id.is_some());
        assert_eq!(result.processed_files, 2);
        assert_eq!(result.uploaded_files, 1);
        assert_eq!(result.failures.len(), 1);
        assert_eq!(result.failures[0].relative_path, "bad.apk");
        assert_eq!(result.failures[0].stage, "upload_file");
        assert_eq!(
            operation.status().state,
            crate::operation::OperationState::Failed
        );
        crate::operation::forget("directory-execute-partial").unwrap();
    }

    #[test]
    fn test_execute_directory_plan_cancellation_stops_before_next_file() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("a.apk"), b"aaa").unwrap();
        fs::write(root.join("b.apk"), b"bbb").unwrap();
        let plan = scan_directory(&root).unwrap();
        let operation = test_operation("directory-execute-cancel");
        let backend = FakeDirectoryBackend {
            cancel_after_first_upload: Some(operation.clone()),
            ..FakeDirectoryBackend::default()
        };

        let result = execute_directory_plan(
            &backend,
            "-1",
            plan,
            false,
            UploadKind::Auto,
            false,
            Some(&operation),
        )
        .unwrap();

        assert_eq!(result.state, "cancelled");
        assert_eq!(result.processed_files, 1);
        assert_eq!(result.uploaded_files, 1);
        assert_eq!(backend.uploaded.borrow().len(), 1);
        assert_eq!(
            operation.status().state,
            crate::operation::OperationState::Cancelled
        );
        crate::operation::forget("directory-execute-cancel").unwrap();
    }

    #[test]
    fn test_execute_directory_plan_rechecks_local_file_before_upload() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        let file = root.join("changed.apk");
        fs::write(&file, b"before").unwrap();
        let plan = scan_directory(&root).unwrap();
        fs::write(&file, b"changed-after-scan").unwrap();
        let backend = FakeDirectoryBackend::default();
        let operation = test_operation("directory-execute-changed");

        let result = execute_directory_plan(
            &backend,
            "-1",
            plan,
            false,
            UploadKind::Auto,
            false,
            Some(&operation),
        )
        .unwrap();

        assert_eq!(result.state, "partial");
        assert_eq!(result.uploaded_files, 0);
        assert_eq!(result.failures[0].code, "local_file_changed");
        assert!(backend.uploaded.borrow().is_empty());
        crate::operation::forget("directory-execute-changed").unwrap();
    }

    #[test]
    fn test_prepared_icon_cleanup_is_exact_on_binding_failure() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("app.apk"), b"apk").unwrap();
        let icon_root = std::env::temp_dir().join("lanzouyou_icons");
        fs::create_dir_all(&icon_root).unwrap();
        let sibling = icon_root.join("prepared-sibling-must-stay.png");
        fs::write(&sibling, b"sibling").unwrap();
        let backend = FakeDirectoryBackend {
            fail_set_icon: true,
            ..FakeDirectoryBackend::default()
        };
        let operation = test_operation("directory-icon-failure-cleanup");

        let result = execute_directory_plan(
            &backend,
            "-1",
            scan_directory(&root).unwrap(),
            false,
            UploadKind::Auto,
            true,
            Some(&operation),
        )
        .unwrap();

        assert_eq!(result.state, "partial");
        assert_eq!(result.failures[0].stage, "set_icon");
        assert!(!backend.prepared_icons.borrow()[0].exists());
        assert!(sibling.exists());
        fs::remove_file(sibling).unwrap();
        crate::operation::forget("directory-icon-failure-cleanup").unwrap();
    }

    #[test]
    fn test_prepared_icon_cleanup_runs_when_cancelled_after_prepare() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("app.apk"), b"apk").unwrap();
        let operation = test_operation("directory-icon-cancel-cleanup");
        let backend = FakeDirectoryBackend {
            cancel_during_prepare: Some(operation.clone()),
            ..FakeDirectoryBackend::default()
        };

        let result = execute_directory_plan(
            &backend,
            "-1",
            scan_directory(&root).unwrap(),
            false,
            UploadKind::Auto,
            true,
            Some(&operation),
        )
        .unwrap();

        assert_eq!(result.state, "cancelled");
        assert!(!backend.prepared_icons.borrow()[0].exists());
        assert!(backend.bound_icons.borrow().is_empty());
        crate::operation::forget("directory-icon-cancel-cleanup").unwrap();
    }

    #[derive(Default)]
    struct FakeDirectoryBackend {
        next_id: RefCell<u64>,
        created: RefCell<Vec<(String, String, String)>>,
        uploaded: RefCell<Vec<String>>,
        prepared_icons: RefCell<Vec<PathBuf>>,
        bound_icons: RefCell<Vec<(String, PathBuf)>>,
        fail_upload_name: Option<String>,
        cancel_after_first_upload: Option<OperationHandle>,
        fail_set_icon: bool,
        cancel_during_prepare: Option<OperationHandle>,
    }

    impl DirectoryUploadBackend for FakeDirectoryBackend {
        fn create_folder(&self, parent_id: &str, name: &str) -> CoreResult<String> {
            let mut next = self.next_id.borrow_mut();
            *next += 1;
            let id = (100 + *next).to_string();
            self.created
                .borrow_mut()
                .push((parent_id.to_owned(), name.to_owned(), id.clone()));
            Ok(id)
        }

        fn upload_file(
            &self,
            _folder_id: &str,
            path: &Path,
            _compat_wrap: bool,
            _kind: UploadKind,
            operation: Option<&OperationHandle>,
            base_uploaded_bytes: u64,
            aggregate_total_bytes: u64,
            planned_original_bytes: u64,
            _allowed_root: &Path,
        ) -> CoreResult<DirectoryUploadedFile> {
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            if self.fail_upload_name.as_deref() == Some(name.as_str()) {
                return Err(CoreError::remote("fixture upload failure", true));
            }
            self.uploaded.borrow_mut().push(name);
            if let Some(operation) = operation {
                operation.set_transfer_progress(
                    base_uploaded_bytes.saturating_add(planned_original_bytes),
                    aggregate_total_bytes,
                );
            }
            if self.uploaded.borrow().len() == 1 {
                if let Some(handle) = &self.cancel_after_first_upload {
                    handle.request_cancel();
                }
            }
            Ok(DirectoryUploadedFile {
                id: format!("file-{}", self.uploaded.borrow().len()),
                original_bytes: planned_original_bytes,
                uploaded_bytes: planned_original_bytes,
                aggregate_total_bytes,
            })
        }

        fn prepare_icon(&self, _source_path: &Path) -> CoreResult<PathBuf> {
            let root = std::env::temp_dir().join("lanzouyou_icons");
            fs::create_dir_all(&root)?;
            let path = root.join(format!(
                "prepared-directory-test-{}.png",
                TEST_ICON_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ));
            fs::write(&path, b"icon")?;
            self.prepared_icons.borrow_mut().push(path.clone());
            if let Some(operation) = &self.cancel_during_prepare {
                operation.request_cancel();
            }
            Ok(path)
        }

        fn set_icon(&self, file_id: &str, icon_path: &Path) -> CoreResult<()> {
            if self.fail_set_icon {
                return Err(CoreError::remote("fixture icon binding failed", true));
            }
            self.bound_icons
                .borrow_mut()
                .push((file_id.to_owned(), icon_path.to_path_buf()));
            Ok(())
        }
    }

    fn test_operation(id: &str) -> OperationHandle {
        crate::operation::begin(Some(id), crate::operation::OperationKind::DirectoryUpload)
            .unwrap()
            .unwrap()
    }
}
