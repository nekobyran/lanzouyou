use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

use regex::Regex;
use serde::Deserialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use zip::{write::SimpleFileOptions, CompressionMethod, DateTime, ZipArchive, ZipWriter};

use crate::error::{CoreError, CoreResult};

const MAX_TEMPLATE_BYTES: u64 = 268_435_456;
const MAX_ENTRIES: usize = 30_000;
const MAX_ENTRY_BYTES: u64 = 134_217_728;
const MAX_TOTAL_BYTES: u64 = 268_435_456;
const MAX_RATIO: u64 = 1_000;
const MAX_RUNTIME_CONFIG_BYTES: usize = 1_048_576;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone)]
pub(crate) struct ArchiveEntry {
    pub(crate) name: String,
    pub(crate) data: Vec<u8>,
    pub(crate) compression: CompressionMethod,
    pub(crate) unix_mode: Option<u32>,
    pub(crate) modified: Option<DateTime>,
    pub(crate) is_dir: bool,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RuntimeIdentity {
    pub(crate) project_id: String,
    pub(crate) display_name: String,
    pub(crate) application_id: String,
    pub(crate) version_name: String,
    pub(crate) version_code: u32,
    pub(crate) windows_exe_name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeEnvelope {
    schema_version: u32,
    identity: RuntimeIdentity,
    branding: RuntimeBranding,
    #[serde(default)]
    home: RuntimeHome,
    sources: Vec<RuntimeSource>,
    features: RuntimeFeatures,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeBranding {
    seed_color: String,
    official_url: String,
    publisher: String,
    logo_asset: String,
    theme_mode: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeSource {
    source_id: String,
    title: String,
    share_url: String,
    password: String,
    searchable: bool,
    recommended: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeFeatures {
    browse: bool,
    search: bool,
    download: bool,
    show_description: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeHome {
    #[serde(default = "default_true")]
    visible: bool,
    #[serde(default)]
    splash_image: String,
    #[serde(default)]
    splash_text: String,
    #[serde(default)]
    carousel_images: Vec<String>,
    #[serde(default)]
    announcement_url: String,
    #[serde(default)]
    web_pages: Vec<RuntimeWebPage>,
}

impl Default for RuntimeHome {
    fn default() -> Self {
        Self {
            visible: true,
            splash_image: String::new(),
            splash_text: String::new(),
            carousel_images: Vec::new(),
            announcement_url: String::new(),
            web_pages: Vec::new(),
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeWebPage {
    name: String,
    url: String,
    #[serde(default)]
    icon: String,
}

const fn default_true() -> bool {
    true
}

pub(crate) fn validate_runtime(value: &Value) -> CoreResult<RuntimeIdentity> {
    let encoded =
        serde_json::to_vec(value).map_err(|_| CoreError::invalid("运行时配置不是有效 JSON"))?;
    if encoded.len() > MAX_RUNTIME_CONFIG_BYTES {
        return Err(CoreError::invalid("运行时配置超过 1 MiB"));
    }
    let envelope: RuntimeEnvelope = serde_json::from_value(value.clone())
        .map_err(|_| CoreError::invalid("运行时配置字段缺失、类型错误或包含未知字段"))?;
    if envelope.schema_version != 1 {
        return Err(CoreError::invalid("仅支持运行时配置 schemaVersion 1"));
    }
    let RuntimeEnvelope {
        identity,
        branding,
        home,
        sources,
        features,
        ..
    } = envelope;
    let project_id = Regex::new(r"^[a-z][a-z0-9_]{1,39}$").unwrap();
    let application_id = Regex::new(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,7}$").unwrap();
    let version_name = Regex::new(r"^\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9.-]+)?$").unwrap();
    let windows_name = Regex::new(r"^[a-z][a-z0-9_-]{1,39}$").unwrap();
    if !project_id.is_match(&identity.project_id) || is_windows_device_name(&identity.project_id) {
        return Err(CoreError::invalid("项目 ID 格式无效"));
    }
    if identity.display_name.trim().is_empty()
        || identity.display_name.chars().count() > 80
        || identity.display_name.chars().any(char::is_control)
    {
        return Err(CoreError::invalid("应用名称格式无效"));
    }
    if !application_id.is_match(&identity.application_id) {
        return Err(CoreError::invalid("Android applicationId 格式无效"));
    }
    if identity.application_id.len() > 127 {
        return Err(CoreError::invalid(
            "Android applicationId 不能超过 127 字节",
        ));
    }
    if !version_name.is_match(&identity.version_name) || identity.version_code == 0 {
        return Err(CoreError::invalid("Android 版本信息格式无效"));
    }
    if identity
        .version_name
        .split(['-', '+'])
        .next()
        .unwrap_or_default()
        .split('.')
        .any(|part| part.parse::<u16>().is_err())
    {
        return Err(CoreError::invalid("版本号数值段不能超过 65535"));
    }
    if !windows_name.is_match(&identity.windows_exe_name)
        || is_windows_device_name(&identity.windows_exe_name)
    {
        return Err(CoreError::invalid("Windows exe 名格式无效"));
    }

    let seed_color = Regex::new(r"^#[0-9A-Fa-f]{6}$").unwrap();
    if !seed_color.is_match(&branding.seed_color) {
        return Err(CoreError::invalid("主题色必须使用 #RRGGBB"));
    }
    if branding.logo_asset != "assets/runtime/logo.png" {
        return Err(CoreError::invalid("图标资源路径不是固定值"));
    }
    if !matches!(branding.theme_mode.as_str(), "system" | "light" | "dark") {
        return Err(CoreError::invalid("主题模式无效"));
    }
    if branding.publisher.chars().count() > 80 || branding.publisher.chars().any(char::is_control) {
        return Err(CoreError::invalid("发布者名称格式无效"));
    }
    if !branding.official_url.is_empty() {
        validate_official_url(&branding.official_url)?;
    }
    if home.splash_text.chars().count() > 2_000
        || home.carousel_images.len() > 50
        || home.web_pages.len() > 50
    {
        return Err(CoreError::invalid("主页内容超过安全上限"));
    }
    for url in home
        .carousel_images
        .iter()
        .chain([&home.splash_image, &home.announcement_url])
    {
        if !url.is_empty() {
            validate_official_url(url)?;
        }
    }
    for page in home.web_pages {
        if page.name.trim().is_empty()
            || page.name.chars().count() > 80
            || page.name.chars().any(char::is_control)
        {
            return Err(CoreError::invalid("网页页面名称格式无效"));
        }
        validate_official_url(&page.url)?;
        if !page.icon.is_empty() {
            validate_official_url(&page.icon)?;
        }
    }
    let _ = home.visible;

    if sources.is_empty() || sources.len() > 4_096 {
        return Err(CoreError::invalid("软件库来源数量必须为 1-4096 个"));
    }
    let source_id = Regex::new(r"^[a-z][a-z0-9_-]{1,63}$").unwrap();
    let mut source_ids = HashSet::with_capacity(sources.len());
    for source in sources {
        if !source_id.is_match(&source.source_id) || !source_ids.insert(source.source_id.clone()) {
            return Err(CoreError::invalid("软件库来源 ID 无效或重复"));
        }
        if source.title.trim().is_empty()
            || source.title.chars().count() > 80
            || source.title.chars().any(char::is_control)
        {
            return Err(CoreError::invalid("软件库来源标题格式无效"));
        }
        if source.password.chars().count() > 64 || source.password.chars().any(char::is_control) {
            return Err(CoreError::invalid("软件库来源密码格式无效"));
        }
        if source.share_url.len() > 2_048 {
            return Err(CoreError::invalid("软件库来源地址过长"));
        }
        super::url::validate_page_url(&source.share_url, &super::url::SecurityPolicy::Production)
            .map_err(|_| CoreError::invalid("软件库来源不是受信的蓝奏 HTTPS 地址"))?;
        let _ = (source.searchable, source.recommended);
    }
    let _ = (
        features.browse,
        features.search,
        features.download,
        features.show_description,
    );
    Ok(identity)
}

fn validate_official_url(value: &str) -> CoreResult<()> {
    if value.len() > 2_048 || value.chars().any(char::is_control) {
        return Err(CoreError::invalid("官网地址格式无效"));
    }
    super::url::reject_explicit_port(value)
        .map_err(|_| CoreError::invalid("官网地址不允许显式端口"))?;
    let url = reqwest::Url::parse(value).map_err(|_| CoreError::invalid("官网地址格式无效"))?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port_or_known_default() != Some(443)
    {
        return Err(CoreError::invalid("官网地址必须是无凭据的 HTTPS 地址"));
    }
    Ok(())
}

pub(crate) fn canonical_runtime_json(value: &Value) -> CoreResult<Vec<u8>> {
    validate_runtime(value)?;
    let mut data =
        serde_json::to_vec(value).map_err(|_| CoreError::invalid("运行时配置不是有效 JSON"))?;
    data.push(b'\n');
    Ok(data)
}

pub(crate) fn read_archive(path: &Path) -> CoreResult<Vec<ArchiveEntry>> {
    let metadata = fs::metadata(path).map_err(CoreError::io)?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_TEMPLATE_BYTES {
        return Err(CoreError::invalid("壳模板大小无效"));
    }
    let file = File::open(path).map_err(CoreError::io)?;
    let mut archive = ZipArchive::new(file)
        .map_err(|error| CoreError::parse(format!("壳模板不是有效 ZIP: {error}")))?;
    if archive.is_empty() || archive.len() > MAX_ENTRIES {
        return Err(CoreError::invalid("壳模板条目数量无效"));
    }

    let mut entries = Vec::with_capacity(archive.len());
    let mut names = HashSet::new();
    let mut total = 0_u64;
    for index in 0..archive.len() {
        let mut file = archive
            .by_index(index)
            .map_err(|error| CoreError::parse(format!("读取壳模板条目失败: {error}")))?;
        let name = std::str::from_utf8(file.name_raw())
            .map_err(|_| CoreError::invalid("壳模板包含非 UTF-8 路径"))?
            .to_owned();
        validate_entry_name(&name)?;
        let folded = name.to_lowercase();
        if !names.insert(folded) {
            return Err(CoreError::invalid("壳模板包含重复路径"));
        }
        let size = file.size();
        let compressed = file.compressed_size();
        if size > MAX_ENTRY_BYTES {
            return Err(CoreError::invalid("壳模板单个条目过大"));
        }
        total = total
            .checked_add(size)
            .ok_or_else(|| CoreError::invalid("壳模板展开大小溢出"))?;
        if total > MAX_TOTAL_BYTES {
            return Err(CoreError::invalid("壳模板展开后超过 256 MiB"));
        }
        if size > 1_048_576 && (compressed == 0 || size / compressed.max(1) > MAX_RATIO) {
            return Err(CoreError::invalid("壳模板压缩比异常"));
        }
        let mut data = Vec::with_capacity(usize::try_from(size).unwrap_or(0));
        file.read_to_end(&mut data).map_err(CoreError::io)?;
        if data.len() as u64 != size {
            return Err(CoreError::parse("壳模板条目长度不一致"));
        }
        entries.push(ArchiveEntry {
            name,
            data,
            compression: file.compression(),
            unix_mode: file.unix_mode(),
            modified: file.last_modified(),
            is_dir: file.is_dir(),
        });
    }
    Ok(entries)
}

pub(crate) fn write_archive(
    path: &Path,
    entries: &[ArchiveEntry],
    android_alignment: bool,
) -> CoreResult<()> {
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(path)
        .map_err(CoreError::io)?;
    let mut writer = ZipWriter::new(file);
    for entry in entries {
        let mut options = SimpleFileOptions::default().compression_method(entry.compression);
        if let Some(mode) = entry.unix_mode {
            options = options.unix_permissions(mode);
        }
        if let Some(modified) = entry.modified {
            options = options.last_modified_time(modified);
        }
        if entry.compression == CompressionMethod::Stored {
            let alignment = if android_alignment
                && entry.name.starts_with("lib/")
                && entry.name.ends_with(".so")
            {
                16_384
            } else {
                4
            };
            options = options.with_alignment(alignment);
        }
        if entry.is_dir {
            writer
                .add_directory(&entry.name, options)
                .map_err(|error| CoreError::io(format!("写入 ZIP 目录失败: {error}")))?;
        } else {
            writer
                .start_file(&entry.name, options)
                .map_err(|error| CoreError::io(format!("写入 ZIP 条目失败: {error}")))?;
            writer.write_all(&entry.data).map_err(CoreError::io)?;
        }
    }
    let file = writer
        .finish()
        .map_err(|error| CoreError::io(format!("完成 ZIP 失败: {error}")))?;
    file.sync_all().map_err(CoreError::io)
}

pub(crate) fn entry_mut<'a>(
    entries: &'a mut [ArchiveEntry],
    name: &str,
) -> CoreResult<&'a mut ArchiveEntry> {
    entries
        .iter_mut()
        .find(|entry| entry.name == name && !entry.is_dir)
        .ok_or_else(|| CoreError::invalid(format!("壳模板缺少固定条目 {name}")))
}

pub(crate) fn temp_sibling(output: &Path, role: &str) -> CoreResult<PathBuf> {
    let parent = output
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or_else(|| CoreError::invalid("输出路径缺少父目录"))?;
    fs::create_dir_all(parent).map_err(CoreError::io)?;
    let name = output
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| CoreError::invalid("输出文件名无效"))?;
    for _ in 0..32 {
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let candidate = parent.join(format!(
            ".{name}.{role}.{}.{}",
            std::process::id(),
            sequence
        ));
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Err(CoreError::io("无法分配临时输出文件"))
}

pub(crate) fn commit_file(temp: &Path, output: &Path) -> CoreResult<()> {
    if output.exists() {
        return Err(CoreError::invalid("输出路径已存在，拒绝覆盖"));
    }
    match fs::hard_link(temp, output) {
        Ok(()) => {
            fs::remove_file(temp).map_err(CoreError::io)?;
            Ok(())
        }
        Err(_) if output.exists() => Err(CoreError::invalid("输出路径已存在，拒绝覆盖")),
        Err(_) => copy_file_noclobber(temp, output),
    }
}

fn copy_file_noclobber(temp: &Path, output: &Path) -> CoreResult<()> {
    let mut created = false;
    let result = (|| {
        let mut source = File::open(temp).map_err(CoreError::io)?;
        let mut target = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(output)
            .map_err(|error| {
                if error.kind() == std::io::ErrorKind::AlreadyExists {
                    CoreError::invalid("输出路径已存在，拒绝覆盖")
                } else {
                    CoreError::io(error)
                }
            })?;
        created = true;
        std::io::copy(&mut source, &mut target).map_err(CoreError::io)?;
        target.sync_all().map_err(CoreError::io)
    })();
    if result.is_err() {
        if created {
            let _ = fs::remove_file(output);
        }
        return result;
    }
    fs::remove_file(temp).map_err(CoreError::io)
}

pub(crate) fn ensure_distinct(template: &Path, output: &Path) -> CoreResult<()> {
    let template = fs::canonicalize(template).map_err(CoreError::io)?;
    let output_absolute = absolute_output(output)?;
    if paths_equal(&template, &output_absolute) {
        return Err(CoreError::invalid("输出路径不能覆盖壳模板"));
    }
    Ok(())
}

pub(crate) fn sha256_file(path: &Path) -> CoreResult<String> {
    let mut file = File::open(path).map_err(CoreError::io)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 65_536];
    loop {
        let read = file.read(&mut buffer).map_err(CoreError::io)?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(hex_lower(&digest.finalize()))
}

pub(crate) fn response_output_path(path: &Path) -> CoreResult<String> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().map_err(CoreError::io)?.join(path)
    };
    Ok(absolute.to_string_lossy().into_owned())
}

pub(crate) fn hex_lower(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(output, "{byte:02x}");
    }
    output
}

fn absolute_output(output: &Path) -> CoreResult<PathBuf> {
    if output.exists() {
        return fs::canonicalize(output).map_err(CoreError::io);
    }
    let parent = output
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or_else(|| CoreError::invalid("输出路径缺少父目录"))?;
    fs::create_dir_all(parent).map_err(CoreError::io)?;
    let parent = fs::canonicalize(parent).map_err(CoreError::io)?;
    let name = output
        .file_name()
        .ok_or_else(|| CoreError::invalid("输出文件名无效"))?;
    Ok(parent.join(name))
}

fn paths_equal(first: &Path, second: &Path) -> bool {
    #[cfg(windows)]
    {
        first
            .to_string_lossy()
            .eq_ignore_ascii_case(&second.to_string_lossy())
    }
    #[cfg(not(windows))]
    {
        first == second
    }
}

fn validate_entry_name(name: &str) -> CoreResult<()> {
    if name.is_empty()
        || name.starts_with('/')
        || name.starts_with('\\')
        || name.contains('\\')
        || name.contains('\0')
    {
        return Err(CoreError::invalid("壳模板包含不安全路径"));
    }
    let trimmed = name.trim_end_matches('/');
    if trimmed.is_empty() || trimmed.len() > 1024 {
        return Err(CoreError::invalid("壳模板路径长度无效"));
    }
    let path = Path::new(trimmed);
    for component in path.components() {
        match component {
            Component::Normal(value) => {
                let value = value.to_string_lossy();
                if value.is_empty()
                    || value.len() > 255
                    || value.contains(':')
                    || value.chars().any(char::is_control)
                    || value.ends_with('.')
                    || value.ends_with(' ')
                    || is_windows_device_name(&value)
                {
                    return Err(CoreError::invalid("壳模板包含不安全路径"));
                }
            }
            _ => return Err(CoreError::invalid("壳模板包含路径穿越")),
        }
    }
    Ok(())
}

fn is_windows_device_name(value: &str) -> bool {
    let base = value
        .split('.')
        .next()
        .unwrap_or_default()
        .trim_end_matches([' ', '.'])
        .to_ascii_uppercase();
    matches!(base.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || base
            .strip_prefix("COM")
            .or_else(|| base.strip_prefix("LPT"))
            .is_some_and(|suffix| suffix.len() == 1 && matches!(suffix.as_bytes()[0], b'1'..=b'9'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn runtime_with_source_count(count: usize) -> Value {
        let sources = (0..count)
            .map(|index| {
                serde_json::json!({
                    "sourceId": format!("source-{index}"),
                    "title": format!("软件库 {index}"),
                    "shareUrl": "https://www.lanzouw.com/b123",
                    "password": "",
                    "searchable": true,
                    "recommended": index == 0
                })
            })
            .collect::<Vec<_>>();
        serde_json::json!({
            "schemaVersion": 1,
            "identity": {
                "projectId": "my_library",
                "displayName": "我的软件库",
                "applicationId": "cc.nkbr.library",
                "versionName": "1.2.3",
                "versionCode": 7,
                "windowsExeName": "my-library"
            },
            "branding": {
                "seedColor": "#2563EB",
                "officialUrl": "https://example.com/",
                "publisher": "发布者",
                "logoAsset": "assets/runtime/logo.png",
                "themeMode": "system"
            },
            "sources": sources,
            "features": {
                "browse": true,
                "search": true,
                "download": true,
                "showDescription": true
            }
        })
    }

    #[test]
    fn test_commit_file_never_overwrites_existing_output() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source.bin");
        let output = temp.path().join("output.bin");
        fs::write(&source, b"new").unwrap();
        fs::write(&output, b"existing").unwrap();
        assert!(commit_file(&source, &output).is_err());
        assert_eq!(fs::read(&source).unwrap(), b"new");
        assert_eq!(fs::read(&output).unwrap(), b"existing");
    }

    #[test]
    fn test_commit_file_publishes_and_removes_temporary_file() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source.bin");
        let output = temp.path().join("output.bin");
        fs::write(&source, b"published").unwrap();
        commit_file(&source, &output).unwrap();
        assert!(!source.exists());
        assert_eq!(fs::read(output).unwrap(), b"published");
    }

    #[test]
    fn test_validate_entry_name_rejects_zip_slip_and_windows_paths() {
        for value in ["../x", "a/../../x", "/x", "C:/x", "a\\b", "./x"] {
            assert!(validate_entry_name(value).is_err(), "{value}");
        }
        assert!(validate_entry_name("data/flutter_assets/a.json").is_ok());
        for value in [
            "CON",
            "data/prn.txt",
            "AUX.json",
            "com1.dll",
            "LPT9",
            "name. ",
            "name.",
            "bad\u{0001}name",
        ] {
            assert!(validate_entry_name(value).is_err(), "{value}");
        }
    }

    #[test]
    fn test_runtime_identity_contract_is_strict() {
        let valid = serde_json::json!({
            "schemaVersion": 1,
            "identity": {
                "projectId": "my_library",
                "displayName": "我的软件库",
                "applicationId": "cc.nkbr.library",
                "versionName": "1.2.3",
                "versionCode": 7,
                "windowsExeName": "my-library"
            },
            "branding": {
                "seedColor": "#2563EB",
                "officialUrl": "https://example.com/",
                "publisher": "发布者",
                "logoAsset": "assets/runtime/logo.png",
                "themeMode": "system"
            },
            "sources": [{
                "sourceId": "source-1",
                "title": "软件库",
                "shareUrl": "https://www.lanzouw.com/b123",
                "password": "",
                "searchable": true,
                "recommended": true
            }],
            "features": {
                "browse": true,
                "search": true,
                "download": true,
                "showDescription": true
            }
        });
        assert!(validate_runtime(&valid).is_ok());
        let mut invalid = valid;
        invalid["identity"]["windowsExeName"] = Value::String("../x".to_owned());
        assert!(validate_runtime(&invalid).is_err());
    }

    #[test]
    fn test_runtime_supports_current_606_source_catalog_and_bounded_overlay_ceiling() {
        assert!(validate_runtime(&runtime_with_source_count(606)).is_ok());
        assert!(validate_runtime(&runtime_with_source_count(4_096)).is_ok());
        let error = match validate_runtime(&runtime_with_source_count(4_097)) {
            Ok(_) => panic!("4097 sources must exceed the bounded overlay ceiling"),
            Err(error) => error,
        };
        assert_eq!(error.code, "invalid_argument");
        assert_eq!(error.message, "软件库来源数量必须为 1-4096 个");
    }

    #[test]
    fn test_runtime_rejects_nonstandard_https_port_and_oversized_version_part() {
        let base = serde_json::json!({
            "schemaVersion": 1,
            "identity": {
                "projectId": "my_library",
                "displayName": "软件库",
                "applicationId": "cc.nkbr.library",
                "versionName": "1.2.3",
                "versionCode": 1,
                "windowsExeName": "my-library"
            },
            "branding": {
                "seedColor": "#2563EB",
                "officialUrl": "https://example.com:444/",
                "publisher": "",
                "logoAsset": "assets/runtime/logo.png",
                "themeMode": "system"
            },
            "sources": [{
                "sourceId": "source-1",
                "title": "库",
                "shareUrl": "https://www.lanzouw.com/b1",
                "password": "",
                "searchable": true,
                "recommended": true
            }],
            "features": {
                "browse": true,
                "search": true,
                "download": true,
                "showDescription": true
            }
        });
        assert!(validate_runtime(&base).is_err());
        let mut version = base;
        version["branding"]["officialUrl"] = Value::String("https://example.com/".to_owned());
        version["identity"]["versionName"] = Value::String("1.70000.0".to_owned());
        assert!(validate_runtime(&version).is_err());
    }

    #[test]
    fn test_runtime_rejects_explicit_default_https_ports() {
        let mut value = serde_json::json!({
            "schemaVersion": 1,
            "identity": {
                "projectId": "my_library",
                "displayName": "软件库",
                "applicationId": "cc.nkbr.library",
                "versionName": "1.2.3",
                "versionCode": 1,
                "windowsExeName": "my-library"
            },
            "branding": {
                "seedColor": "#2563EB",
                "officialUrl": "https://example.com:443/",
                "publisher": "",
                "logoAsset": "assets/runtime/logo.png",
                "themeMode": "system"
            },
            "sources": [{
                "sourceId": "source-1",
                "title": "库",
                "shareUrl": "https://www.lanzouw.com/b1",
                "password": "",
                "searchable": true,
                "recommended": true
            }],
            "features": {
                "browse": true,
                "search": true,
                "download": true,
                "showDescription": true
            }
        });
        assert!(validate_runtime(&value).is_err());
        value["branding"]["officialUrl"] = Value::String("https://example.com/".to_owned());
        value["sources"][0]["shareUrl"] =
            Value::String("https://www.lanzouw.com:443/b1".to_owned());
        assert!(validate_runtime(&value).is_err());
    }

    #[test]
    fn test_runtime_rejects_windows_device_names_for_project_and_exe() {
        let mut value = serde_json::json!({
            "schemaVersion": 1,
            "identity": {
                "projectId": "con",
                "displayName": "库",
                "applicationId": "cc.nkbr.library",
                "versionName": "1.0.0",
                "versionCode": 1,
                "windowsExeName": "valid-name"
            },
            "branding": {"seedColor":"#2563EB","officialUrl":"","publisher":"","logoAsset":"assets/runtime/logo.png","themeMode":"system"},
            "sources": [{"sourceId":"source-1","title":"库","shareUrl":"https://www.lanzouw.com/b1","password":"","searchable":true,"recommended":true}],
            "features": {"browse":true,"search":true,"download":true,"showDescription":true}
        });
        assert!(validate_runtime(&value).is_err());
        value["identity"]["projectId"] = Value::String("valid_project".to_owned());
        value["identity"]["windowsExeName"] = Value::String("LPT1".to_ascii_lowercase());
        assert!(validate_runtime(&value).is_err());
    }
}
