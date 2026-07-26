use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{CoreError, CoreResult};

use super::entity::EntityValidator;

const METADATA_SCHEMA_VERSION: u8 = 1;
const MAX_METADATA_BYTES: u64 = 64 * 1024;
static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct TransferMetadata {
    pub schema_version: u8,
    pub file_name: String,
    pub committed_bytes: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub etag: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_modified: Option<String>,
    pub generation: u64,
    pub control_epoch: u64,
}

impl TransferMetadata {
    pub(crate) fn new(file_name: String, generation: u64, control_epoch: u64) -> Self {
        Self {
            schema_version: METADATA_SCHEMA_VERSION,
            file_name,
            committed_bytes: 0,
            total_bytes: None,
            etag: None,
            last_modified: None,
            generation,
            control_epoch,
        }
    }

    pub(crate) fn validator(&self) -> EntityValidator {
        EntityValidator {
            etag: self.etag.clone(),
            last_modified: self.last_modified.clone(),
            total_bytes: self.total_bytes,
        }
    }

    pub(crate) fn set_validator(&mut self, validator: &EntityValidator) {
        self.etag.clone_from(&validator.etag);
        self.last_modified.clone_from(&validator.last_modified);
        self.total_bytes = validator.total_bytes;
    }

    fn validate(&self, expected_file_name: &str) -> CoreResult<()> {
        if self.schema_version != METADATA_SCHEMA_VERSION
            || self.file_name != expected_file_name
            || self.committed_bytes > self.total_bytes.unwrap_or(u64::MAX)
            || self
                .etag
                .as_ref()
                .into_iter()
                .chain(self.last_modified.as_ref())
                .any(|value| {
                    value.is_empty() || value.len() > 512 || value.chars().any(char::is_control)
                })
        {
            return Err(metadata_corrupt("下载断点元数据格式无效"));
        }
        crate::validation::safe_filename(&self.file_name)?;
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct TransferPaths {
    root: PathBuf,
    pub part: PathBuf,
    pub metadata: PathBuf,
}

impl TransferPaths {
    pub(crate) fn for_identity(
        directory: &Path,
        source_id: &str,
        canonical_share_url: &str,
        file_name: &str,
    ) -> CoreResult<Self> {
        if !directory.is_absolute() {
            return Err(CoreError::invalid("下载目录必须是绝对路径"));
        }
        crate::validation::safe_filename(file_name)?;
        fs::create_dir_all(directory)?;
        let root = fs::canonicalize(directory)?;
        if !root.is_dir() {
            return Err(CoreError::invalid("下载目录不是文件夹"));
        }
        let fingerprint = identity_fingerprint(source_id, canonical_share_url, file_name);
        Ok(Self {
            part: root.join(format!(".lanzouyou-{fingerprint}.part")),
            metadata: root.join(format!(".lanzouyou-{fingerprint}.meta.json")),
            root,
        })
    }

    pub(crate) fn load_or_new(
        &self,
        file_name: &str,
        generation: u64,
        control_epoch: u64,
    ) -> CoreResult<TransferMetadata> {
        self.ensure_root_unchanged()?;
        if !self.metadata.exists() {
            return Ok(TransferMetadata::new(
                file_name.to_owned(),
                generation,
                control_epoch,
            ));
        }
        reject_link_or_reparse(&self.metadata)?;
        let file = open_read_nofollow(&self.metadata)?;
        if file.metadata()?.len() > MAX_METADATA_BYTES {
            return Err(metadata_corrupt("下载断点元数据过大"));
        }
        let mut bytes = Vec::new();
        file.take(MAX_METADATA_BYTES + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_METADATA_BYTES {
            return Err(metadata_corrupt("下载断点元数据过大"));
        }
        let metadata: TransferMetadata =
            serde_json::from_slice(&bytes).map_err(|_| metadata_corrupt("下载断点元数据损坏"))?;
        metadata.validate(file_name)?;
        self.ensure_root_unchanged()?;
        Ok(metadata)
    }

    pub(crate) fn open_part(&self) -> CoreResult<File> {
        self.ensure_root_unchanged()?;
        if self.part.exists() {
            reject_link_or_reparse(&self.part)?;
        }
        let file = open_part_nofollow(&self.part)?;
        reject_open_reparse(&file)?;
        self.ensure_path_inside_root(&self.part)?;
        Ok(file)
    }

    /// Reconciles durable metadata with the actual part length. Bytes beyond
    /// the last fsynced `committedBytes` are discarded; if storage lost tail
    /// bytes, committed progress is lowered instead of seeking into a hole.
    pub(crate) fn repair_part(
        &self,
        file: &mut File,
        metadata: &mut TransferMetadata,
    ) -> CoreResult<bool> {
        let actual = file.metadata()?.len();
        let original = metadata.committed_bytes;
        if actual > metadata.committed_bytes {
            file.set_len(metadata.committed_bytes)?;
        } else if actual < metadata.committed_bytes {
            metadata.committed_bytes = actual;
        }
        file.seek(SeekFrom::Start(metadata.committed_bytes))?;
        Ok(actual != original)
    }

    pub(crate) fn write_metadata_atomic(&self, metadata: &TransferMetadata) -> CoreResult<()> {
        self.ensure_root_unchanged()?;
        metadata.validate(&metadata.file_name)?;
        let bytes = serde_json::to_vec(metadata)
            .map_err(|_| CoreError::new("internal_error", "下载元数据序列化失败", false))?;
        if bytes.len() as u64 > MAX_METADATA_BYTES {
            return Err(metadata_corrupt("下载断点元数据过大"));
        }
        let temp = self.root.join(format!(
            ".lanzouyou-meta-{}-{}.tmp",
            std::process::id(),
            TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let result = (|| {
            let mut file = create_new_nofollow(&temp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            drop(file);
            self.ensure_root_unchanged()?;
            atomic_replace(&temp, &self.metadata)?;
            sync_directory(&self.root)?;
            self.ensure_root_unchanged()?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temp);
        }
        result
    }

    pub(crate) fn remove_metadata(&self) -> CoreResult<()> {
        self.ensure_root_unchanged()?;
        match fs::remove_file(&self.metadata) {
            Ok(()) => sync_directory(&self.root),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        }
    }

    pub(crate) fn verify_part_before_publish(&self) -> CoreResult<()> {
        self.ensure_root_unchanged()?;
        reject_link_or_reparse(&self.part)?;
        self.ensure_path_inside_root(&self.part)
    }

    fn ensure_root_unchanged(&self) -> CoreResult<()> {
        let current = fs::canonicalize(&self.root)?;
        if current != self.root || !current.is_dir() {
            Err(path_escape())
        } else {
            reject_link_or_reparse(&self.root)
        }
    }

    fn ensure_path_inside_root(&self, path: &Path) -> CoreResult<()> {
        let parent = path.parent().ok_or_else(path_escape)?;
        if fs::canonicalize(parent)? != self.root {
            return Err(path_escape());
        }
        if path.exists() {
            let canonical = fs::canonicalize(path)?;
            if canonical.parent() != Some(self.root.as_path()) {
                return Err(path_escape());
            }
        }
        Ok(())
    }
}

fn identity_fingerprint(source_id: &str, canonical_share_url: &str, file_name: &str) -> String {
    let mut digest = Sha256::new();
    for value in [source_id, canonical_share_url, file_name] {
        digest.update((value.len() as u64).to_be_bytes());
        digest.update(value.as_bytes());
    }
    digest
        .finalize()
        .iter()
        .take(16)
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn reject_link_or_reparse(path: &Path) -> CoreResult<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || metadata_is_reparse(&metadata) {
        Err(path_escape())
    } else {
        Ok(())
    }
}

#[cfg(target_os = "windows")]
fn metadata_is_reparse(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;

    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(target_os = "windows"))]
fn metadata_is_reparse(_metadata: &fs::Metadata) -> bool {
    false
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn configure_nofollow(options: &mut OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt;
    options.custom_flags(libc::O_NOFOLLOW);
}

#[cfg(target_os = "windows")]
fn configure_nofollow(options: &mut OpenOptions) {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT;

    options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
}

#[cfg(not(any(target_os = "android", target_os = "linux", target_os = "windows")))]
fn configure_nofollow(_options: &mut OpenOptions) {}

fn open_part_nofollow(path: &Path) -> CoreResult<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true);
    configure_nofollow(&mut options);
    options.open(path).map_err(CoreError::io)
}

fn open_read_nofollow(path: &Path) -> CoreResult<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    configure_nofollow(&mut options);
    let file = options.open(path).map_err(CoreError::io)?;
    reject_open_reparse(&file)?;
    Ok(file)
}

fn create_new_nofollow(path: &Path) -> CoreResult<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    configure_nofollow(&mut options);
    let file = options.open(path).map_err(CoreError::io)?;
    reject_open_reparse(&file)?;
    Ok(file)
}

fn reject_open_reparse(file: &File) -> CoreResult<()> {
    if metadata_is_reparse(&file.metadata()?) {
        Err(path_escape())
    } else {
        Ok(())
    }
}

#[cfg(target_os = "windows")]
fn atomic_replace(source: &Path, destination: &Path) -> CoreResult<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let source = source
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let destination = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let result = unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        Err(CoreError::io(std::io::Error::last_os_error()))
    } else {
        Ok(())
    }
}

#[cfg(not(target_os = "windows"))]
fn atomic_replace(source: &Path, destination: &Path) -> CoreResult<()> {
    fs::rename(source, destination).map_err(CoreError::io)
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn sync_directory(path: &Path) -> CoreResult<()> {
    File::open(path)?.sync_all()?;
    Ok(())
}

#[cfg(not(any(target_os = "android", target_os = "linux")))]
fn sync_directory(_path: &Path) -> CoreResult<()> {
    Ok(())
}

fn metadata_corrupt(message: &str) -> CoreError {
    CoreError::new("metadata_corrupt", message, false)
}

fn path_escape() -> CoreError {
    CoreError::new(
        "download_path_escape",
        "下载临时路径离开了目标目录或经过了链接",
        false,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(directory: &Path) -> TransferPaths {
        TransferPaths::for_identity(
            directory,
            "source-one",
            "https://www.lanzouw.com/b1",
            "app.apk",
        )
        .unwrap()
    }

    #[test]
    fn test_paths_are_deterministic_bounded_and_identity_scoped() {
        let directory = tempfile::tempdir().unwrap();
        let first = paths(directory.path());
        let same = paths(directory.path());
        let other = TransferPaths::for_identity(
            directory.path(),
            "source-two",
            "https://www.lanzouw.com/b1",
            "app.apk",
        )
        .unwrap();

        assert_eq!(first, same);
        assert_ne!(first.part, other.part);
        let canonical_directory = fs::canonicalize(directory.path()).unwrap();
        assert_eq!(first.part.parent(), Some(canonical_directory.as_path()));
        assert!(first.part.file_name().unwrap().to_string_lossy().len() < 80);
    }

    #[test]
    fn test_metadata_roundtrip_is_strict_and_contains_no_transport_secrets() {
        let directory = tempfile::tempdir().unwrap();
        let paths = paths(directory.path());
        let mut metadata = TransferMetadata::new("app.apk".to_owned(), 2, 7);
        metadata.committed_bytes = 4;
        metadata.total_bytes = Some(10);
        metadata.etag = Some("\"v1\"".to_owned());
        paths.write_metadata_atomic(&metadata).unwrap();

        assert_eq!(paths.load_or_new("app.apk", 0, 0).unwrap(), metadata);
        let raw = fs::read_to_string(&paths.metadata).unwrap();
        for forbidden in [
            "accessCode",
            "password",
            "directUrl",
            "cookie",
            "authorization",
            "https://",
        ] {
            assert!(!raw
                .to_ascii_lowercase()
                .contains(&forbidden.to_ascii_lowercase()));
        }

        let unknown = raw.replacen('{', "{\"unknown\":true,", 1);
        fs::write(&paths.metadata, unknown).unwrap();
        assert_eq!(
            paths.load_or_new("app.apk", 0, 0).unwrap_err().code,
            "metadata_corrupt"
        );
    }

    #[test]
    fn test_part_repair_truncates_uncommitted_tail_and_lowers_lost_progress() {
        let directory = tempfile::tempdir().unwrap();
        let paths = paths(directory.path());
        let mut file = paths.open_part().unwrap();
        file.write_all(b"abcdefgh").unwrap();
        file.sync_all().unwrap();
        let mut metadata = TransferMetadata::new("app.apk".to_owned(), 0, 0);
        metadata.committed_bytes = 4;

        assert!(paths.repair_part(&mut file, &mut metadata).unwrap());
        assert_eq!(file.metadata().unwrap().len(), 4);
        assert_eq!(metadata.committed_bytes, 4);

        file.set_len(2).unwrap();
        assert!(paths.repair_part(&mut file, &mut metadata).unwrap());
        assert_eq!(metadata.committed_bytes, 2);
    }

    #[test]
    fn test_corrupt_metadata_is_not_silently_reset() {
        let directory = tempfile::tempdir().unwrap();
        let paths = paths(directory.path());
        fs::write(&paths.metadata, b"not-json").unwrap();

        let error = paths.load_or_new("app.apk", 0, 0).unwrap_err();

        assert_eq!(error.code, "metadata_corrupt");
        assert!(paths.metadata.exists());
    }

    #[cfg(any(target_os = "windows", target_os = "linux"))]
    #[test]
    fn test_part_symlink_is_rejected_without_touching_target() {
        let directory = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let outside_file = outside.path().join("outside.bin");
        fs::write(&outside_file, b"protected").unwrap();
        let paths = paths(directory.path());

        #[cfg(target_os = "windows")]
        if std::os::windows::fs::symlink_file(&outside_file, &paths.part).is_err() {
            return;
        }
        #[cfg(target_os = "linux")]
        std::os::unix::fs::symlink(&outside_file, &paths.part).unwrap();

        assert_eq!(paths.open_part().unwrap_err().code, "download_path_escape");
        assert_eq!(fs::read(outside_file).unwrap(), b"protected");
    }
}
