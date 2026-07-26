use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

use serde_json::{json, Value};

use crate::{
    compat,
    error::{CoreError, CoreResult},
    http_client::UploadProgressWindow,
    model::{CopySummary, UploadKind},
    operation::OperationHandle,
    parser,
    session::{map, SessionClient},
    validation,
};

struct CopyContext<'a> {
    temp_root: &'a Path,
    visited: &'a mut HashSet<String>,
    summary: &'a mut CopySummary,
}

static COPY_TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DirectoryUploadedFile {
    pub(crate) id: String,
    pub(crate) original_bytes: u64,
    pub(crate) uploaded_bytes: u64,
    pub(crate) aggregate_total_bytes: u64,
}

impl SessionClient {
    pub fn upload(
        &self,
        folder_id: &str,
        path: &str,
        compat_wrap: bool,
        kind: UploadKind,
    ) -> CoreResult<Value> {
        self.upload_with_operation(folder_id, path, compat_wrap, kind, None)
    }

    pub(crate) fn upload_with_operation(
        &self,
        folder_id: &str,
        path: &str,
        compat_wrap: bool,
        kind: UploadKind,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<Value> {
        if let Some(operation) = operation {
            operation.check_cancelled()?;
            operation.set_total_units(1);
        }
        self.require_session()?;
        validation::id(folder_id, "folderId")?;
        let prepared = compat::prepare(Path::new(path), compat_wrap, kind)?;
        if let Some(operation) = operation {
            operation.check_cancelled()?;
            operation.set_transfer_progress(0, prepared.upload_bytes);
        }
        let fields = map(&[
            ("task", "1"),
            ("vie", "2"),
            ("ve", "2"),
            ("id", "WU_FILE_0"),
            ("name", &prepared.remote_name),
            ("folder_id_bb_n", folder_id),
        ]);
        let url = format!("{}/html5up.php", self.http.bases.pc);
        let response = match operation {
            Some(operation) => self.http.upload_with_operation(
                &url,
                &self.cookie,
                &fields,
                &prepared.path,
                &prepared.remote_name,
                Some(operation),
            ),
            None => self.http.upload(
                &url,
                &self.cookie,
                &fields,
                &prepared.path,
                &prepared.remote_name,
            ),
        }?;
        let value = parser::api_json(response.text()?)?;
        let id = parser::upload_file_id(&value)?.ok_or_else(|| {
            CoreError::new(
                "missing_uploaded_file_id",
                "上传完成但核心无法安全确认新文件 ID",
                false,
            )
        })?;
        let result = json!({
            "id": id,
            "folderId": folder_id,
            "originalName": prepared.original_name,
            "uploadedName": prepared.remote_name,
            "originalBytes": prepared.original_bytes,
            "uploadedBytes": prepared.upload_bytes,
            "compatWrapped": prepared.compat_wrapped,
            "kind": match kind { UploadKind::Auto => "auto", UploadKind::File => "file" }
        });
        if let Some(operation) = operation {
            operation.set_transfer_progress(prepared.upload_bytes, prepared.upload_bytes);
            operation.complete_unit(0);
        }
        Ok(result)
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn upload_directory_file_with_operation(
        &self,
        folder_id: &str,
        path: &Path,
        compat_wrap: bool,
        kind: UploadKind,
        operation: &OperationHandle,
        base_uploaded_bytes: u64,
        aggregate_total_bytes: u64,
        planned_original_bytes: u64,
        allowed_root: &Path,
    ) -> CoreResult<DirectoryUploadedFile> {
        operation.check_cancelled()?;
        self.require_session()?;
        validation::id(folder_id, "folderId")?;
        validate_directory_upload_source(path, allowed_root, planned_original_bytes)?;
        let prepared = compat::prepare(path, compat_wrap, kind)?;
        operation.check_cancelled()?;
        let aggregate_total_bytes = aggregate_total_bytes
            .saturating_sub(planned_original_bytes)
            .saturating_add(prepared.upload_bytes)
            .max(base_uploaded_bytes.saturating_add(prepared.upload_bytes));
        operation.set_transfer_progress(base_uploaded_bytes, aggregate_total_bytes);
        let fields = map(&[
            ("task", "1"),
            ("vie", "2"),
            ("ve", "2"),
            ("id", "WU_FILE_0"),
            ("name", &prepared.remote_name),
            ("folder_id_bb_n", folder_id),
        ]);
        let url = format!("{}/html5up.php", self.http.bases.pc);
        let response = self.http.upload_with_progress_window(
            &url,
            &self.cookie,
            &fields,
            &prepared.path,
            &prepared.remote_name,
            Some(operation),
            Some(UploadProgressWindow {
                base_bytes: base_uploaded_bytes,
                total_bytes: aggregate_total_bytes,
            }),
        )?;
        let value = parser::api_json(response.text()?)?;
        let id = parser::upload_file_id(&value)?.ok_or_else(|| {
            CoreError::new(
                "missing_uploaded_file_id",
                "上传完成但核心无法安全确认新文件 ID",
                false,
            )
        })?;
        operation.set_transfer_progress(
            base_uploaded_bytes.saturating_add(prepared.upload_bytes),
            aggregate_total_bytes,
        );
        Ok(DirectoryUploadedFile {
            id,
            original_bytes: prepared.original_bytes,
            uploaded_bytes: prepared.upload_bytes,
            aggregate_total_bytes,
        })
    }

    pub fn download(
        &self,
        id: &str,
        requested_name: Option<&str>,
        destination: &str,
    ) -> CoreResult<Value> {
        self.download_with_operation(id, requested_name, destination, None)
    }

    pub(crate) fn download_with_operation(
        &self,
        id: &str,
        requested_name: Option<&str>,
        destination: &str,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<Value> {
        if let Some(operation) = operation {
            operation.check_cancelled()?;
            operation.set_total_units(1);
        }
        self.require_session()?;
        validation::id(id, "id")?;
        let share = self.share_record(id, false)?;
        let name = requested_name
            .filter(|name| !name.trim().is_empty())
            .or_else(|| (!share.name.is_empty()).then_some(share.name.as_str()))
            .unwrap_or("download.bin");
        validation::safe_filename(name)?;
        let requested = PathBuf::from(destination);
        let directory_target = requested.is_dir()
            || destination.ends_with(std::path::MAIN_SEPARATOR)
            || destination.ends_with('/');
        let destination_path = if directory_target {
            fs::create_dir_all(&requested)?;
            requested.join(name)
        } else {
            requested
        };
        self.download_to_path_mode(
            id,
            &destination_path,
            directory_target.then_some(destination_path.parent().unwrap_or_else(|| Path::new("."))),
            operation,
        )
    }

    pub(crate) fn download_to_path(&self, id: &str, destination: &Path) -> CoreResult<Value> {
        self.download_to_path_mode(id, destination, None, None)
    }

    fn download_to_path_mode(
        &self,
        id: &str,
        destination: &Path,
        directory_target: Option<&Path>,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<Value> {
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        let share = self.share_record(id, false)?;
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        let direct_url = self.resolve_direct_url(&share.url, &share.password)?;
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        Self::validate_destination(destination)?;
        if destination.exists() {
            return Err(CoreError::new("already_exists", "目标文件已存在", false));
        }
        let part_path = part_path(destination);
        if part_path.exists() {
            fs::remove_file(&part_path)?;
        }
        let result = (|| {
            let downloaded = match operation {
                Some(operation) => self.http.download_with_operation(
                    &direct_url,
                    "down_ip=1",
                    &part_path,
                    Some(operation),
                ),
                None => self.http.download(&direct_url, "down_ip=1", &part_path),
            }?;
            if let Some(operation) = operation {
                operation.check_cancelled()?;
            }
            let unpacked = compat::unwrap_in_place(&part_path)?;
            let final_path =
                finalize_download(&part_path, destination, directory_target, &unpacked)?;
            let value = json!({
                "id": id,
                "path": final_path.to_string_lossy(),
                "bytesDownloaded": downloaded,
                "bytesWritten": unpacked.bytes,
                "compatUnwrapped": unpacked.unwrapped,
                "originalName": unpacked.original_name,
                "directUrlResolved": true
            });
            if let Some(operation) = operation {
                operation.complete_unit(0);
            }
            Ok(value)
        })();
        cleanup_partial_download(&part_path, &result);
        result
    }

    pub fn move_item(&self, id: &str, is_folder: bool, target_id: &str) -> CoreResult<Value> {
        validation::id(id, "id")?;
        validation::id(target_id, "targetId")?;
        if id == target_id {
            return Err(CoreError::invalid("不能移动到自身"));
        }
        if !is_folder {
            self.move_file(id, target_id)?;
            return Ok(json!({"id": id, "isFolder": false, "targetId": target_id}));
        }
        self.ensure_not_descendant(id, target_id)?;
        let mut visited = HashSet::new();
        let mut summary = CopySummary::default();
        let new_id = self.move_folder_recursive(id, target_id, 0, &mut visited, &mut summary)?;
        Ok(json!({
            "id": id,
            "newId": new_id,
            "isFolder": true,
            "targetId": target_id,
            "filesMoved": summary.files,
            "foldersMoved": summary.folders
        }))
    }

    fn ensure_not_descendant(&self, source_id: &str, target_id: &str) -> CoreResult<()> {
        if target_id == "-1" {
            return Ok(());
        }
        let value = self.task(map(&[("task", "47"), ("folder_id", target_id)]))?;
        if value
            .get("info")
            .and_then(Value::as_array)
            .map(|parents| {
                parents.iter().any(|entry| {
                    entry.get("folderid").and_then(value_string).as_deref() == Some(source_id)
                })
            })
            .unwrap_or(false)
        {
            Err(CoreError::invalid("不能把目录移动到其子目录"))
        } else {
            Ok(())
        }
    }

    fn move_folder_recursive(
        &self,
        source_id: &str,
        target_id: &str,
        depth: usize,
        visited: &mut HashSet<String>,
        summary: &mut CopySummary,
    ) -> CoreResult<String> {
        if depth > 64 || !visited.insert(source_id.to_owned()) {
            return Err(CoreError::invalid("目录层级过深或存在循环"));
        }
        let share = self.share_record(source_id, true)?;
        let new_id = self.mkdir_id(target_id, &share.name, &share.description)?;
        if !share.password.is_empty() {
            self.set_password(&new_id, true, &share.password)?;
        }
        let items = self.list_all(source_id)?;
        for item in items {
            if item.is_folder {
                self.move_folder_recursive(&item.id, &new_id, depth + 1, visited, summary)?;
            } else {
                self.move_file(&item.id, &new_id)?;
                summary.files += 1;
            }
        }
        self.delete(source_id, true)?;
        self.recycle_action(source_id, true, true)?;
        summary.folders += 1;
        visited.remove(source_id);
        Ok(new_id)
    }

    pub fn copy_item(
        &self,
        id: &str,
        is_folder: bool,
        name: &str,
        target_id: &str,
        temp_dir: &str,
    ) -> CoreResult<Value> {
        validation::id(id, "id")?;
        validation::id(target_id, "targetId")?;
        validation::safe_filename(name)?;
        let temp_root = PathBuf::from(temp_dir);
        fs::create_dir_all(&temp_root)?;
        if !temp_root.is_dir() {
            return Err(CoreError::invalid("tempDir 不是目录"));
        }
        let mut summary = CopySummary::default();
        let mut visited = HashSet::new();
        let created_id = if is_folder {
            let mut context = CopyContext {
                temp_root: &temp_root,
                visited: &mut visited,
                summary: &mut summary,
            };
            Some(self.copy_folder_recursive(id, name, target_id, 0, &mut context)?)
        } else {
            self.copy_file(id, name, target_id, &temp_root, &mut summary)?;
            None
        };
        Ok(json!({
            "id": id,
            "createdId": created_id,
            "targetId": target_id,
            "filesCopied": summary.files,
            "foldersCopied": summary.folders,
            "bytesCopied": summary.bytes
        }))
    }

    fn copy_folder_recursive(
        &self,
        source_id: &str,
        name: &str,
        target_id: &str,
        depth: usize,
        context: &mut CopyContext<'_>,
    ) -> CoreResult<String> {
        if depth > 64 || !context.visited.insert(source_id.to_owned()) {
            return Err(CoreError::invalid("目录层级过深或存在循环"));
        }
        let share = self.share_record(source_id, true)?;
        let new_id = self.mkdir_id(target_id, name, &share.description)?;
        if !share.password.is_empty() {
            self.set_password(&new_id, true, &share.password)?;
        }
        for item in self.list_all(source_id)? {
            if item.is_folder {
                self.copy_folder_recursive(&item.id, &item.name, &new_id, depth + 1, context)?;
            } else {
                self.copy_file(
                    &item.id,
                    &item.name,
                    &new_id,
                    context.temp_root,
                    context.summary,
                )?;
            }
        }
        context.summary.folders += 1;
        context.visited.remove(source_id);
        Ok(new_id)
    }

    fn copy_file(
        &self,
        id: &str,
        name: &str,
        target_id: &str,
        temp_root: &Path,
        summary: &mut CopySummary,
    ) -> CoreResult<()> {
        validation::safe_filename(name)?;
        let work_dir = create_copy_temp_dir(temp_root, id)?;
        let temp = work_dir.join(name);
        let operation = (|| {
            let downloaded = self.download_to_path(id, &temp)?;
            let bytes = downloaded["bytesWritten"].as_u64().unwrap_or_default();
            self.upload(
                target_id,
                temp.to_string_lossy().as_ref(),
                false,
                UploadKind::Auto,
            )?;
            summary.files += 1;
            summary.bytes += bytes;
            Ok(())
        })();
        let _ = fs::remove_file(&temp);
        let _ = fs::remove_dir(&work_dir);
        operation
    }
}

fn validate_directory_upload_source(
    path: &Path,
    allowed_root: &Path,
    expected_bytes: u64,
) -> CoreResult<()> {
    let metadata = fs::symlink_metadata(path)?;
    let mut unsafe_path = metadata.file_type().is_symlink() || !metadata.is_file();
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;
        unsafe_path |= metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0;
    }
    if unsafe_path {
        return Err(CoreError::new(
            "unsafe_local_path",
            "文件在扫描后变成链接或重解析点，已拒绝上传",
            false,
        ));
    }
    let canonical = fs::canonicalize(path)?;
    if !canonical.starts_with(allowed_root) {
        return Err(CoreError::new(
            "unsafe_local_path",
            "文件在扫描后移出所选目录，已拒绝上传",
            false,
        ));
    }
    if metadata.len() != expected_bytes {
        return Err(CoreError::new(
            "local_file_changed",
            "文件在扫描后发生变化，请重新选择目录",
            false,
        ));
    }
    Ok(())
}

fn value_string(value: &Value) -> Option<String> {
    value
        .as_str()
        .map(ToOwned::to_owned)
        .or_else(|| value.as_i64().map(|number| number.to_string()))
}

fn part_path(destination: &Path) -> PathBuf {
    let file_name = destination
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("download");
    destination.with_file_name(format!(".{file_name}.lanzouyou.part"))
}

fn cleanup_partial_download<T>(part_path: &Path, result: &CoreResult<T>) {
    if result.is_err() {
        let _ = fs::remove_file(part_path);
    }
}

fn create_copy_temp_dir(root: &Path, id: &str) -> CoreResult<PathBuf> {
    for _ in 0..16 {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|value| value.as_nanos())
            .unwrap_or_default();
        let counter = COPY_TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = root.join(format!(".lanzouyou-copy-{id}-{timestamp}-{counter}"));
        match fs::create_dir(&path) {
            Ok(()) => return Ok(path),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Err(CoreError::io("无法创建唯一复制临时目录"))
}

fn finalize_download(
    part_path: &Path,
    requested_destination: &Path,
    directory_target: Option<&Path>,
    unpacked: &compat::UnwrapInfo,
) -> CoreResult<PathBuf> {
    let final_path = match (directory_target, unpacked.original_name.as_deref()) {
        (Some(directory), Some(original_name)) if unpacked.unwrapped => {
            validation::safe_filename(original_name)?;
            directory.join(original_name)
        }
        _ => requested_destination.to_path_buf(),
    };
    if final_path.exists() {
        return Err(CoreError::new("already_exists", "目标文件已存在", false));
    }
    SessionClient::validate_destination(&final_path)?;
    fs::rename(part_path, &final_path)?;
    Ok(final_path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wrapped_part(directory: &Path) -> (PathBuf, compat::UnwrapInfo) {
        let source = directory.join("original.custom");
        fs::write(&source, b"exact payload").unwrap();
        let prepared = compat::prepare(&source, false, UploadKind::File).unwrap();
        let part = directory.join(".remote.lzyou.zip.lanzouyou.part");
        fs::copy(&prepared.path, &part).unwrap();
        fs::remove_file(source).unwrap();
        let info = compat::unwrap_in_place(&part).unwrap();
        (part, info)
    }

    #[test]
    fn test_finalize_download_directory_restores_original_name() {
        let directory = tempfile::tempdir().unwrap();
        let (part, info) = wrapped_part(directory.path());
        let remote_destination = directory.path().join("remote.lzyou.zip");

        let final_path =
            finalize_download(&part, &remote_destination, Some(directory.path()), &info).unwrap();

        assert_eq!(final_path, directory.path().join("original.custom"));
        assert_eq!(fs::read(final_path).unwrap(), b"exact payload");
        assert!(!remote_destination.exists());
    }

    #[test]
    fn test_cancelled_download_removes_partial_file() {
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join(".payload.lanzouyou.part");
        fs::write(&part, b"partial").unwrap();
        let result: CoreResult<()> = Err(CoreError::cancelled());

        cleanup_partial_download(&part, &result);

        assert!(!part.exists());
    }

    #[test]
    fn test_finalize_download_directory_refuses_existing_original_name() {
        let directory = tempfile::tempdir().unwrap();
        let (part, info) = wrapped_part(directory.path());
        let existing = directory.path().join("original.custom");
        fs::write(&existing, b"keep me").unwrap();

        let error = finalize_download(
            &part,
            &directory.path().join("remote.lzyou.zip"),
            Some(directory.path()),
            &info,
        )
        .unwrap_err();

        assert_eq!(error.code, "already_exists");
        assert_eq!(fs::read(existing).unwrap(), b"keep me");
    }
}
