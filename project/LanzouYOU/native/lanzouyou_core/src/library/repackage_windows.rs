use std::{fs, path::PathBuf};

use editpe::{
    types::{VersionU16, VersionU32},
    Image, VersionInfo, VersionStringTable,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{CoreError, CoreResult};

use super::{
    repackage_android::{encode_square_png, load_icon},
    repackage_common::{
        canonical_runtime_json, commit_file, ensure_distinct, entry_mut, read_archive,
        response_output_path, sha256_file, temp_sibling, validate_runtime, write_archive,
        ArchiveEntry, RuntimeIdentity,
    },
};

const PLACEHOLDER_EXE: &str = "lanzou_library_shell.exe";
const RUNTIME_PATH: &str = "data/flutter_assets/assets/runtime/library.json";
const LOGO_PATH: &str = "data/flutter_assets/assets/runtime/logo.png";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WindowsRepackageRequest {
    pub(crate) template_path: String,
    pub(crate) output_path: String,
    pub(crate) runtime_config: Value,
    #[serde(default)]
    pub(crate) icon_path: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WindowsRepackageResult {
    archive_path: String,
    sha256: String,
    exe_name: String,
}

pub(crate) fn repackage_windows(
    request: WindowsRepackageRequest,
) -> CoreResult<WindowsRepackageResult> {
    let template = PathBuf::from(&request.template_path);
    let output = PathBuf::from(&request.output_path);
    ensure_distinct(&template, &output)?;
    let identity = validate_runtime(&request.runtime_config)?;
    let runtime_json = canonical_runtime_json(&request.runtime_config)?;
    let exe_name = format!("{}.exe", identity.windows_exe_name);
    let temp = temp_sibling(&output, "windows")?;

    let result = (|| {
        let mut entries = read_archive(&template)?;
        validate_windows_layout(&entries)?;
        if !PLACEHOLDER_EXE.eq_ignore_ascii_case(&exe_name)
            && entries
                .iter()
                .any(|entry| entry.name.eq_ignore_ascii_case(&exe_name))
        {
            return Err(CoreError::invalid("Windows 壳模板已存在目标 exe 同名条目"));
        }
        entry_mut(&mut entries, RUNTIME_PATH)?.data = runtime_json;

        let icon_path = request
            .icon_path
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty());
        if let Some(path) = icon_path {
            let icon = load_icon(PathBuf::from(path).as_path())?;
            entry_mut(&mut entries, LOGO_PATH)?.data = encode_square_png(&icon, 512)?;
        }

        let executable = entry_mut(&mut entries, PLACEHOLDER_EXE)?;
        executable.data = rewrite_executable(
            &executable.data,
            &identity,
            icon_path.map(PathBuf::from).as_deref(),
        )?;
        executable.name = exe_name.clone();
        write_archive(&temp, &entries, false)?;
        verify_windows_payload(&temp, &request.runtime_config, &identity, &exe_name)?;
        let sha256 = sha256_file(&temp)?;
        commit_file(&temp, &output)?;
        let archive_path = response_output_path(&output)?;
        Ok(WindowsRepackageResult {
            archive_path,
            sha256,
            exe_name,
        })
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

fn validate_windows_layout(entries: &[ArchiveEntry]) -> CoreResult<()> {
    for name in [PLACEHOLDER_EXE, RUNTIME_PATH, LOGO_PATH] {
        if !entries
            .iter()
            .any(|entry| entry.name == name && !entry.is_dir)
        {
            return Err(CoreError::invalid(format!(
                "Windows 壳模板缺少固定条目 {name}"
            )));
        }
    }
    Ok(())
}

fn rewrite_executable(
    bytes: &[u8],
    identity: &RuntimeIdentity,
    icon_path: Option<&std::path::Path>,
) -> CoreResult<Vec<u8>> {
    let mut image = Image::parse(bytes.to_vec())
        .map_err(|error| CoreError::parse(format!("Windows 壳 exe 无效: {error}")))?;
    let mut resources = image.resource_directory().cloned().unwrap_or_default();
    if let Some(path) = icon_path {
        let path = path
            .to_str()
            .ok_or_else(|| CoreError::invalid("自定义图标路径不是有效 UTF-8"))?;
        resources.set_main_icon_file(path).map_err(|error| {
            CoreError::new(
                "image_error",
                format!("写入 Windows exe 图标失败: {error}"),
                false,
            )
        })?;
    }

    let mut version = resources
        .get_version_info()
        .map_err(|error| CoreError::parse(format!("读取 Windows exe 版本信息失败: {error}")))?
        .unwrap_or_else(default_version_info);
    if version.strings.is_empty() {
        version.strings.push(default_string_table());
    }
    for table in &mut version.strings {
        table
            .strings
            .insert("FileDescription".to_owned(), identity.display_name.clone());
        table
            .strings
            .insert("ProductName".to_owned(), identity.display_name.clone());
        table
            .strings
            .insert("InternalName".to_owned(), identity.windows_exe_name.clone());
        table.strings.insert(
            "OriginalFilename".to_owned(),
            format!("{}.exe", identity.windows_exe_name),
        );
        table
            .strings
            .insert("FileVersion".to_owned(), identity.version_name.clone());
        table
            .strings
            .insert("ProductVersion".to_owned(), identity.version_name.clone());
    }
    let fixed = fixed_version(&identity.version_name)?;
    version.info.file_version = fixed;
    version.info.product_version = fixed;
    resources
        .set_version_info(&version)
        .map_err(|error| CoreError::parse(format!("写入 Windows exe 版本信息失败: {error}")))?;
    image
        .set_resource_directory(resources)
        .map_err(|error| CoreError::parse(format!("重建 Windows exe 资源失败: {error}")))?;
    let mut output = Vec::new();
    image
        .write_writer(&mut output)
        .map_err(|error| CoreError::io(format!("写入 Windows exe 失败: {error}")))?;
    verify_executable_identity(&output, identity)?;
    Ok(output)
}

fn default_version_info() -> VersionInfo {
    VersionInfo {
        strings: vec![default_string_table()],
        vars: vec![VersionU16 {
            major: 0x0409,
            minor: 1200,
        }],
        ..VersionInfo::default()
    }
}

fn default_string_table() -> VersionStringTable {
    VersionStringTable {
        key: "040904B0".to_owned(),
        ..VersionStringTable::default()
    }
}

fn fixed_version(value: &str) -> CoreResult<VersionU32> {
    let numeric = value
        .split(['-', '+'])
        .next()
        .unwrap_or(value)
        .split('.')
        .map(|part| part.parse::<u16>())
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| CoreError::invalid("Windows 版本号不能转换为数值版本"))?;
    if numeric.len() < 2 || numeric.len() > 4 {
        return Err(CoreError::invalid("Windows 版本号必须包含 2-4 段"));
    }
    let mut parts = [0_u16; 4];
    for (index, value) in numeric.into_iter().enumerate() {
        parts[index] = value;
    }
    Ok(VersionU32 {
        major: (u32::from(parts[0]) << 16) | u32::from(parts[1]),
        minor: (u32::from(parts[2]) << 16) | u32::from(parts[3]),
    })
}

fn verify_executable_identity(bytes: &[u8], identity: &RuntimeIdentity) -> CoreResult<()> {
    let image = Image::parse(bytes.to_vec())
        .map_err(|error| CoreError::parse(format!("读回 Windows exe 失败: {error}")))?;
    let resources = image
        .resource_directory()
        .ok_or_else(|| CoreError::parse("读回 Windows exe 缺少资源目录"))?;
    let version = resources
        .get_version_info()
        .map_err(|error| CoreError::parse(format!("读回 Windows exe 版本失败: {error}")))?
        .ok_or_else(|| CoreError::parse("读回 Windows exe 缺少版本信息"))?;
    let valid = version.strings.iter().any(|table| {
        table.strings.get("ProductName") == Some(&identity.display_name)
            && table.strings.get("FileDescription") == Some(&identity.display_name)
            && table.strings.get("FileVersion") == Some(&identity.version_name)
            && table.strings.get("OriginalFilename")
                == Some(&format!("{}.exe", identity.windows_exe_name))
    });
    if !valid {
        return Err(CoreError::parse("Windows exe 身份写入后读回不一致"));
    }
    Ok(())
}

fn verify_windows_payload(
    path: &std::path::Path,
    runtime: &Value,
    identity: &RuntimeIdentity,
    exe_name: &str,
) -> CoreResult<()> {
    let mut entries = read_archive(path)?;
    if entries.iter().any(|entry| {
        entry.name.eq_ignore_ascii_case(PLACEHOLDER_EXE)
            && !entry.name.eq_ignore_ascii_case(exe_name)
    }) {
        return Err(CoreError::parse("Windows 占位 exe 未被移除"));
    }
    let actual: Value = serde_json::from_slice(&entry_mut(&mut entries, RUNTIME_PATH)?.data)
        .map_err(|_| CoreError::parse("Windows 运行时配置读回失败"))?;
    if &actual != runtime {
        return Err(CoreError::parse("Windows 运行时配置读回不一致"));
    }
    let executable = entries
        .iter()
        .find(|entry| entry.name == exe_name && !entry.is_dir)
        .ok_or_else(|| CoreError::parse("Windows 目标 exe 读回失败"))?;
    verify_executable_identity(&executable.data, identity)
}

#[cfg(all(test, windows))]
mod tests {
    use std::{fs::File, io::Write, path::Path};

    use tempfile::tempdir;
    use zip::{write::SimpleFileOptions, CompressionMethod, ZipArchive, ZipWriter};

    use super::*;

    fn runtime() -> Value {
        serde_json::json!({
            "schemaVersion": 1,
            "identity": {
                "projectId": "offline_library",
                "displayName": "离线软件库",
                "applicationId": "cc.nkbr.offline",
                "versionName": "1.2.3",
                "versionCode": 3,
                "windowsExeName": "offline-library"
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
        })
    }

    fn write_directory_zip(root: &Path, path: &Path) {
        let mut files = Vec::new();
        let mut pending = vec![root.to_path_buf()];
        while let Some(directory) = pending.pop() {
            for entry in fs::read_dir(directory).unwrap() {
                let entry = entry.unwrap();
                let path = entry.path();
                if path.is_dir() {
                    pending.push(path);
                } else if path.is_file() {
                    files.push(path);
                }
            }
        }
        files.sort();

        let mut writer = ZipWriter::new(File::create(path).unwrap());
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
        for file in files {
            let name = file
                .strip_prefix(root)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            writer.start_file(name, options).unwrap();
            writer.write_all(&fs::read(file).unwrap()).unwrap();
        }
        writer.finish().unwrap();
    }

    #[test]
    fn test_windows_zip_roundtrip_rewrites_config_exe_and_version() {
        let temp = tempdir().unwrap();
        let template = temp.path().join("template.zip");
        let output = temp.path().join("output.zip");
        let mut writer = ZipWriter::new(File::create(&template).unwrap());
        let options = SimpleFileOptions::default();
        writer.start_file(PLACEHOLDER_EXE, options).unwrap();
        writer
            .write_all(&fs::read(std::env::current_exe().unwrap()).unwrap())
            .unwrap();
        writer.start_file(RUNTIME_PATH, options).unwrap();
        writer.write_all(b"{}").unwrap();
        writer.start_file(LOGO_PATH, options).unwrap();
        writer.write_all(b"logo").unwrap();
        writer.finish().unwrap();

        let result = repackage_windows(WindowsRepackageRequest {
            template_path: template.to_string_lossy().into_owned(),
            output_path: output.to_string_lossy().into_owned(),
            runtime_config: runtime(),
            icon_path: None,
        })
        .unwrap();
        assert_eq!(result.exe_name, "offline-library.exe");
        assert_eq!(result.sha256.len(), 64);
        let mut archive = ZipArchive::new(File::open(output).unwrap()).unwrap();
        assert!(archive.by_name(PLACEHOLDER_EXE).is_err());
        assert!(archive.by_name("offline-library.exe").is_ok());
    }

    #[test]
    fn test_real_library_shell_windows_repackages_when_build_fixture_exists() {
        let shell = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../LanzouLibraryShell");
        let release = shell.join("build/windows/x64/runner/Release");
        let placeholder = release.join(PLACEHOLDER_EXE);
        let runtime_asset = release.join(RUNTIME_PATH.replace('/', "\\"));
        let logo = shell.join("assets/runtime/logo.png");
        if !placeholder.is_file() || !runtime_asset.is_file() || !logo.is_file() {
            return;
        }

        let temp = tempdir().unwrap();
        let template = temp.path().join("real-shell-template.zip");
        let output = temp.path().join("real-shell-custom.zip");
        write_directory_zip(&release, &template);
        let result = repackage_windows(WindowsRepackageRequest {
            template_path: template.to_string_lossy().into_owned(),
            output_path: output.to_string_lossy().into_owned(),
            runtime_config: runtime(),
            icon_path: Some(logo.to_string_lossy().into_owned()),
        })
        .unwrap();

        assert_eq!(result.exe_name, "offline-library.exe");
        let mut archive = ZipArchive::new(File::open(output).unwrap()).unwrap();
        assert!(archive.by_name(PLACEHOLDER_EXE).is_err());
        assert!(archive.by_name("offline-library.exe").is_ok());
        assert!(archive.by_name(RUNTIME_PATH).is_ok());
        assert!(archive.by_name(LOGO_PATH).is_ok());
    }
}
