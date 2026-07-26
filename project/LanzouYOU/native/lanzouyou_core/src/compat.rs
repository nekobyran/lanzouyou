use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

use crate::{
    error::{CoreError, CoreResult},
    model::UploadKind,
    validation,
};

const MAGIC: &[u8; 8] = b"LZYOU001";
const FOOTER_SIZE: u64 = 20;
static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

pub struct PreparedUpload {
    pub path: PathBuf,
    pub remote_name: String,
    pub original_name: String,
    pub original_bytes: u64,
    pub upload_bytes: u64,
    pub compat_wrapped: bool,
    temporary: bool,
}

impl Drop for PreparedUpload {
    fn drop(&mut self) {
        if self.temporary {
            let _ = fs::remove_file(&self.path);
        }
    }
}

pub struct UnwrapInfo {
    pub unwrapped: bool,
    pub original_name: Option<String>,
    pub bytes: u64,
}

pub fn prepare(path: &Path, requested_wrap: bool, kind: UploadKind) -> CoreResult<PreparedUpload> {
    if !path.is_file() {
        return Err(CoreError::invalid("上传路径不是文件"));
    }
    let original_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| CoreError::invalid("文件名不是有效 UTF-8"))?
        .to_owned();
    validation::safe_filename(&original_name)?;
    let original_bytes = path.metadata()?.len();
    let must_wrap = requested_wrap || !is_supported(&original_name, kind);
    if !must_wrap {
        return Ok(PreparedUpload {
            path: path.to_path_buf(),
            remote_name: original_name.clone(),
            original_name,
            original_bytes,
            upload_bytes: original_bytes,
            compat_wrapped: false,
            temporary: false,
        });
    }

    let temp_root = std::env::temp_dir().join("lanzouyou_upload");
    fs::create_dir_all(&temp_root)?;
    let stem = path
        .file_stem()
        .and_then(|name| name.to_str())
        .unwrap_or("file");
    let remote_name = format!("{}.lzyou.zip", sanitize_stem(stem));
    let temp_path = temp_root.join(unique_name(&remote_name));
    wrap(path, &temp_path, &original_name, original_bytes)?;
    let upload_bytes = temp_path.metadata()?.len();
    Ok(PreparedUpload {
        path: temp_path,
        remote_name,
        original_name,
        original_bytes,
        upload_bytes,
        compat_wrapped: true,
        temporary: true,
    })
}

fn wrap(
    source: &Path,
    destination: &Path,
    original_name: &str,
    original_len: u64,
) -> CoreResult<()> {
    let mut input = File::open(source)?;
    let mut output = File::create(destination)?;
    std::io::copy(&mut input, &mut output)?;
    let name = original_name.as_bytes();
    let name_len = u32::try_from(name.len()).map_err(|_| CoreError::invalid("文件名过长"))?;
    output.write_all(name)?;
    output.write_all(&original_len.to_le_bytes())?;
    output.write_all(&name_len.to_le_bytes())?;
    output.write_all(MAGIC)?;
    output.flush()?;
    Ok(())
}

pub fn unwrap_in_place(path: &Path) -> CoreResult<UnwrapInfo> {
    let mut file = OpenOptions::new().read(true).write(true).open(path)?;
    let total = file.metadata()?.len();
    if total < FOOTER_SIZE {
        return Ok(UnwrapInfo {
            unwrapped: false,
            original_name: None,
            bytes: total,
        });
    }
    file.seek(SeekFrom::End(-(FOOTER_SIZE as i64)))?;
    let mut footer = [0_u8; FOOTER_SIZE as usize];
    file.read_exact(&mut footer)?;
    if &footer[12..20] != MAGIC {
        return Ok(UnwrapInfo {
            unwrapped: false,
            original_name: None,
            bytes: total,
        });
    }
    let original_len = u64::from_le_bytes(footer[0..8].try_into().unwrap_or([0; 8]));
    let name_len = u32::from_le_bytes(footer[8..12].try_into().unwrap_or([0; 4])) as u64;
    if original_len
        .checked_add(name_len)
        .and_then(|value| value.checked_add(FOOTER_SIZE))
        != Some(total)
    {
        return Err(CoreError::parse("兼容包尾校验失败"));
    }
    file.seek(SeekFrom::Start(original_len))?;
    let mut name = vec![0_u8; name_len as usize];
    file.read_exact(&mut name)?;
    let original_name =
        String::from_utf8(name).map_err(|_| CoreError::parse("兼容包原始文件名无效"))?;
    validation::safe_filename(&original_name)?;
    file.set_len(original_len)?;
    Ok(UnwrapInfo {
        unwrapped: true,
        original_name: Some(original_name),
        bytes: original_len,
    })
}

fn is_supported(name: &str, _kind: UploadKind) -> bool {
    let extension = Path::new(name)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let supported = [
        "ppt",
        "xapk",
        "ke",
        "azw",
        "cpk",
        "gho",
        "dwg",
        "db",
        "docx",
        "deb",
        "e",
        "ttf",
        "xls",
        "bat",
        "crx",
        "rpm",
        "txf",
        "pdf",
        "apk",
        "ipa",
        "txt",
        "mobi",
        "osk",
        "dmg",
        "rp",
        "osz",
        "jar",
        "ttc",
        "z",
        "w3x",
        "xlsx",
        "cetrainer",
        "ct",
        "rar",
        "mp3",
        "pptx",
        "mobileconfig",
        "epub",
        "imazingapp",
        "doc",
        "iso",
        "img",
        "appimage",
        "7z",
        "rplib",
        "lolgezi",
        "exe",
        "azw3",
        "zip",
        "conf",
        "tar",
        "dll",
        "flac",
        "xpa",
        "lua",
        "cad",
        "hwt",
        "accdb",
        "ce",
        "xmind",
        "enc",
        "bds",
        "bdi",
        "ssf",
        "it",
        "gz",
    ];
    supported.contains(&extension.as_str())
}

fn sanitize_stem(value: &str) -> String {
    let result: String = value
        .chars()
        .filter(|character| character.is_alphanumeric() || matches!(character, '_' | '-'))
        .take(80)
        .collect();
    if result.is_empty() {
        "file".to_owned()
    } else {
        result
    }
}

fn unique_name(remote_name: &str) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or_default();
    let count = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{nanos}-{count}-{remote_name}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compat_wrap_roundtrip_preserves_bytes_and_name() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("icon.custom");
        fs::write(&source, b"exact bytes").unwrap();
        let prepared = prepare(&source, true, UploadKind::File).unwrap();
        assert!(prepared.compat_wrapped);
        let downloaded = directory.path().join("download.bin");
        fs::copy(&prepared.path, &downloaded).unwrap();
        let info = unwrap_in_place(&downloaded).unwrap();
        assert!(info.unwrapped);
        assert_eq!(info.original_name.as_deref(), Some("icon.custom"));
        assert_eq!(fs::read(downloaded).unwrap(), b"exact bytes");
    }
}
