use std::{
    borrow::Cow,
    collections::BTreeSet,
    fs::{self, File, OpenOptions},
    io::{Cursor, Read, Write},
    path::{Path, PathBuf},
};

use apksig::{Algorithms, Apk};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use image::{
    codecs::png::{CompressionType, FilterType, PngEncoder},
    imageops, DynamicImage, ExtendedColorType, ImageEncoder, ImageReader, RgbaImage,
};
use rand::rngs::OsRng;
use rcgen::{
    date_time_ymd, CertificateParams, DistinguishedName, DnType, IsCa, KeyPair, KeyUsagePurpose,
};
use resand::{
    defs::ResTypeValue,
    res_value::{ResValue, ResValueType},
    table::{ResTable, ResTableEntryValue},
    xmltree::XMLTree,
};
use rsa::{
    pkcs8::{DecodePrivateKey, EncodePrivateKey, EncodePublicKey},
    traits::PublicKeyParts,
    RsaPrivateKey,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use x509_cert::{
    der::{Decode, Encode},
    Certificate,
};

use crate::error::{CoreError, CoreResult};

use super::repackage_common::{
    canonical_runtime_json, commit_file, ensure_distinct, entry_mut, read_archive,
    response_output_path, temp_sibling, validate_runtime, write_archive, ArchiveEntry,
    RuntimeIdentity,
};

const MANIFEST_PATH: &str = "AndroidManifest.xml";
const RUNTIME_PATH: &str = "assets/flutter_assets/assets/runtime/library.json";
const LOGO_PATH: &str = "assets/flutter_assets/assets/runtime/logo.png";
const MAX_ICON_FILE_BYTES: u64 = 32 * 1024 * 1024;
const MAX_ICON_PIXELS: u64 = 64 * 1024 * 1024;
const SIGNING_IDENTITY_VERSION: u32 = 1;

const EXPECTED_LAUNCHER_SIZES: [u32; 5] = [48, 72, 96, 144, 192];

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AndroidRepackageRequest {
    pub(crate) template_path: String,
    pub(crate) output_path: String,
    pub(crate) runtime_config: Value,
    #[serde(default)]
    pub(crate) icon_path: Option<String>,
    pub(crate) signing_identity_path: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AndroidRepackageResult {
    apk_path: String,
    bytes: u64,
    signing_verified: bool,
    package_name: String,
    version_name: String,
    version_code: u32,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredSigningIdentity {
    version: u32,
    private_key_pkcs8: String,
    certificate_der: String,
}

struct SigningIdentity {
    private_key: RsaPrivateKey,
    certificate_der: Vec<u8>,
}

#[derive(PartialEq, Eq)]
struct ManifestIdentity {
    package_name: String,
    display_name: String,
    version_name: String,
    version_code: u32,
    min_sdk: u32,
}

struct LauncherIcon {
    path: String,
    side: u32,
}

pub(crate) fn repackage_android(
    request: AndroidRepackageRequest,
) -> CoreResult<AndroidRepackageResult> {
    let template = PathBuf::from(&request.template_path);
    let output = PathBuf::from(&request.output_path);
    let signing_identity_path = PathBuf::from(&request.signing_identity_path);
    ensure_distinct(&template, &output)?;
    ensure_identity_path_distinct(&template, &output, &signing_identity_path)?;
    let identity = validate_runtime(&request.runtime_config)?;
    let runtime_json = canonical_runtime_json(&request.runtime_config)?;

    let unsigned = temp_sibling(&output, "unsigned")?;
    let signed = temp_sibling(&output, "signed")?;
    let result = (|| {
        let mut entries = read_archive(&template)?;
        entries.retain(|entry| !is_v1_signature_entry(&entry.name));
        validate_apk_layout(&entries)?;

        entry_mut(&mut entries, RUNTIME_PATH)?.data = runtime_json;
        let manifest = entry_mut(&mut entries, MANIFEST_PATH)?;
        manifest.data = rewrite_manifest(&manifest.data, &identity)?;
        let resources = entry_mut(&mut entries, "resources.arsc")?;
        let (rewritten_resources, launcher_paths) =
            rewrite_resources(&resources.data, &identity.application_id)?;
        resources.data = rewritten_resources;
        let launcher_icons = validate_launcher_entries(&entries, &launcher_paths)?;

        if let Some(icon_path) = request
            .icon_path
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            replace_icons(&mut entries, Path::new(icon_path), &launcher_icons)?;
        }
        write_archive(&unsigned, &entries, true)?;

        let signing_identity = load_or_create_identity(&signing_identity_path)?;
        let mut apk = Apk::new_raw(unsigned.clone()).map_err(CoreError::io)?;
        apk.sign_v2(
            &Algorithms::RSASSA_PKCS1_v1_5_256,
            &signing_identity.certificate_der,
            signing_identity.private_key,
        )
        .map_err(|error| {
            CoreError::new("signing_error", format!("APK v2 签名失败: {error}"), false)
        })?;
        let mut signed_file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&signed)
            .map_err(CoreError::io)?;
        apk.write_with_signature(&mut signed_file)
            .map_err(|error| {
                CoreError::new(
                    "signing_error",
                    format!("写入 APK 签名失败: {error}"),
                    false,
                )
            })?;
        signed_file.sync_all().map_err(CoreError::io)?;

        Apk::new(signed.clone())
            .map_err(CoreError::io)?
            .verify()
            .map_err(|error| {
                CoreError::new(
                    "signing_error",
                    format!("APK v2 签名结构验证失败: {error}"),
                    false,
                )
            })?;
        verify_signed_payload(&signed, &identity, &request.runtime_config)?;

        let bytes = fs::metadata(&signed).map_err(CoreError::io)?.len();
        commit_file(&signed, &output)?;
        let apk_path = response_output_path(&output)?;
        Ok(AndroidRepackageResult {
            apk_path,
            bytes,
            signing_verified: true,
            package_name: identity.application_id.clone(),
            version_name: identity.version_name.clone(),
            version_code: identity.version_code,
        })
    })();
    let _ = fs::remove_file(&unsigned);
    if result.is_err() {
        let _ = fs::remove_file(&signed);
    }
    result
}

fn validate_apk_layout(entries: &[ArchiveEntry]) -> CoreResult<()> {
    let resources = entries
        .iter()
        .find(|entry| entry.name == "resources.arsc" && !entry.is_dir)
        .ok_or_else(|| CoreError::invalid("Android 壳模板缺少 resources.arsc"))?;
    if resources.compression != zip::CompressionMethod::Stored {
        return Err(CoreError::invalid(
            "Android 壳模板 resources.arsc 必须保持未压缩",
        ));
    }
    for name in [MANIFEST_PATH, RUNTIME_PATH, LOGO_PATH] {
        if !entries
            .iter()
            .any(|entry| entry.name == name && !entry.is_dir)
        {
            return Err(CoreError::invalid(format!(
                "Android 壳模板缺少固定条目 {name}"
            )));
        }
    }
    Ok(())
}

fn rewrite_resources(bytes: &[u8], application_id: &str) -> CoreResult<(Vec<u8>, Vec<String>)> {
    let mut table = ResTable::try_from(bytes)
        .map_err(|error| CoreError::parse(format!("解析 resources.arsc 失败: {error}")))?;
    let packages = table.packages.as_packages();
    if packages.len() != 1 {
        return Err(CoreError::invalid(
            "Android 壳模板 resources.arsc 必须且只能包含一个应用资源包",
        ));
    }
    let paths = launcher_paths(&table)?;
    table
        .packages
        .first_mut()
        .ok_or_else(|| CoreError::parse("resources.arsc 缺少应用资源包"))?
        .name = application_id.to_owned();
    let encoded = Vec::<u8>::try_from(table)
        .map_err(|error| CoreError::parse(format!("写入 resources.arsc 失败: {error}")))?;

    let readback = ResTable::try_from(encoded.as_slice())
        .map_err(|error| CoreError::parse(format!("读回 resources.arsc 失败: {error}")))?;
    if readback
        .packages
        .first()
        .map(|package| package.name.as_str())
        != Some(application_id)
        || launcher_paths(&readback)? != paths
    {
        return Err(CoreError::parse("resources.arsc 写入后读回不一致"));
    }
    Ok((encoded, paths))
}

fn launcher_paths(table: &ResTable) -> CoreResult<Vec<String>> {
    static SAFE_RESOURCE_PATH: once_cell::sync::Lazy<regex::Regex> =
        once_cell::sync::Lazy::new(|| {
            regex::Regex::new(
                r"^res/(?:[A-Za-z0-9_-][A-Za-z0-9._-]*/)*[A-Za-z0-9_-][A-Za-z0-9._-]*\.png$",
            )
            .expect("resource path regex is valid")
        });
    let package = table
        .packages
        .first()
        .ok_or_else(|| CoreError::parse("resources.arsc 缺少应用资源包"))?;
    let mut paths = BTreeSet::new();
    for chunk in &package.chunks {
        let ResTypeValue::TableType(table_type) = &chunk.data else {
            continue;
        };
        if table_type.id == 0 {
            return Err(CoreError::parse("resources.arsc 包含无效的资源类型编号"));
        }
        if package.string_pool_type.resolve((table_type.id - 1).into()) != Some("mipmap") {
            continue;
        }
        for (_, entry) in &table_type.entries {
            let Some(entry) = entry else { continue };
            let ResTableEntryValue::ResValue(value) = &entry.data else {
                continue;
            };
            if value.key.resolve(&package.string_pool_key) != Some("ic_launcher") {
                continue;
            }
            let ResValueType::String(reference) = value.data.data else {
                continue;
            };
            let path = reference
                .resolve(&table.string_pool)
                .ok_or_else(|| CoreError::parse("ic_launcher 资源路径字符串无效"))?;
            if path.ends_with(".png") {
                if !SAFE_RESOURCE_PATH.is_match(path) {
                    return Err(CoreError::invalid("ic_launcher 指向了不安全的资源路径"));
                }
                paths.insert(path.to_owned());
            }
        }
    }
    if paths.len() != 5 {
        return Err(CoreError::invalid(
            "Android 壳模板 mipmap/ic_launcher 必须恰好包含 5 个 PNG 密度资源",
        ));
    }
    Ok(paths.into_iter().collect())
}

fn validate_launcher_entries(
    entries: &[ArchiveEntry],
    paths: &[String],
) -> CoreResult<Vec<LauncherIcon>> {
    let mut sizes = BTreeSet::new();
    let mut icons = Vec::with_capacity(paths.len());
    for path in paths {
        let entry = entries
            .iter()
            .find(|entry| entry.name == *path && !entry.is_dir)
            .ok_or_else(|| CoreError::invalid("resources.arsc 指向了不存在的启动图标"))?;
        let image = image::load_from_memory(&entry.data)
            .map_err(|_| CoreError::invalid("Android 壳模板启动图标已损坏"))?;
        if image.width() != image.height() || !EXPECTED_LAUNCHER_SIZES.contains(&image.width()) {
            return Err(CoreError::invalid("Android 壳模板启动图标尺寸无效"));
        }
        if !sizes.insert(image.width()) {
            return Err(CoreError::invalid("Android 壳模板启动图标密度尺寸重复"));
        }
        icons.push(LauncherIcon {
            path: path.clone(),
            side: image.width(),
        });
    }
    if sizes.iter().copied().collect::<Vec<_>>() != EXPECTED_LAUNCHER_SIZES {
        return Err(CoreError::invalid("Android 壳模板启动图标密度不完整"));
    }
    Ok(icons)
}

fn is_v1_signature_entry(name: &str) -> bool {
    let upper = name.to_ascii_uppercase();
    let Some(file_name) = upper.strip_prefix("META-INF/") else {
        return false;
    };
    !file_name.contains('/')
        && (file_name == "MANIFEST.MF"
            || file_name.starts_with("SIG-")
            || [".SF", ".RSA", ".DSA", ".EC"]
                .iter()
                .any(|suffix| file_name.ends_with(suffix)))
}

fn rewrite_manifest(bytes: &[u8], identity: &RuntimeIdentity) -> CoreResult<Vec<u8>> {
    let mut cursor = Cursor::new(bytes);
    let mut tree = XMLTree::read(&mut cursor)
        .map_err(|error| CoreError::parse(format!("解析二进制 AndroidManifest 失败: {error}")))?;
    let old_package = tree
        .root
        .get_element(&["manifest"], &tree.string_pool)
        .ok_or_else(|| CoreError::parse("AndroidManifest 缺少 manifest 节点"))
        .and_then(|manifest| attribute_string(manifest, "package", &tree.string_pool))?;
    let component_names = component_class_names(&tree);
    let lookup = tree.string_pool.clone();
    let (root, strings) = (&mut tree.root, &mut tree.string_pool);
    {
        let manifest = root
            .get_element_mut(&["manifest"], &lookup)
            .ok_or_else(|| CoreError::parse("AndroidManifest 缺少 manifest 节点"))?;
        manifest
            .get_attribute_mut("package", &lookup)
            .ok_or_else(|| CoreError::parse("AndroidManifest 缺少 package 属性"))?
            .write_string(Cow::Borrowed(&identity.application_id), strings);
        manifest
            .get_attribute_mut("versionName", &lookup)
            .ok_or_else(|| CoreError::parse("AndroidManifest 缺少 versionName 属性"))?
            .write_string(Cow::Borrowed(&identity.version_name), strings);
        manifest
            .get_attribute_mut("versionCode", &lookup)
            .ok_or_else(|| CoreError::parse("AndroidManifest 缺少 versionCode 属性"))?
            .set_value(ResValue::new(ResValueType::IntDec(identity.version_code)));
    }
    let application = root
        .get_element_mut(&["manifest", "application"], &lookup)
        .ok_or_else(|| CoreError::parse("AndroidManifest 缺少 application 节点"))?;
    application
        .get_attribute_mut("label", &lookup)
        .ok_or_else(|| CoreError::parse("AndroidManifest 缺少 application label 属性"))?
        .write_string(Cow::Borrowed(&identity.display_name), strings);
    rewrite_package_derived_attributes(
        root,
        &lookup,
        strings,
        &old_package,
        &identity.application_id,
    );

    let mut output = Cursor::new(Vec::new());
    tree.write(&mut output)
        .map_err(|error| CoreError::parse(format!("写入二进制 AndroidManifest 失败: {error}")))?;
    let output = output.into_inner();
    let actual = read_manifest_identity(&output)?;
    let expected = ManifestIdentity {
        package_name: identity.application_id.clone(),
        display_name: identity.display_name.clone(),
        version_name: identity.version_name.clone(),
        version_code: identity.version_code,
        min_sdk: actual.min_sdk,
    };
    if actual != expected {
        return Err(CoreError::parse("AndroidManifest 身份写入后读回不一致"));
    }
    let readback_tree = XMLTree::read(&mut Cursor::new(&output))
        .map_err(|error| CoreError::parse(format!("读回 AndroidManifest 失败: {error}")))?;
    if component_class_names(&readback_tree) != component_names {
        return Err(CoreError::parse("AndroidManifest 组件类名被意外修改"));
    }
    if has_old_package_derived_value(&readback_tree, &old_package) {
        return Err(CoreError::parse(
            "AndroidManifest 仍包含旧 applicationId 派生权限或 authority",
        ));
    }
    if actual.min_sdk < 24 {
        return Err(CoreError::invalid(
            "Android 壳模板 minSdk 必须至少为 24（产物使用 APK Signature Scheme v2）",
        ));
    }
    Ok(output)
}

fn rewrite_package_derived_attributes(
    node: &mut resand::xmltree::XMLTreeNode,
    lookup: &resand::string_pool::StringPoolHandler,
    strings: &mut resand::string_pool::StringPoolHandler,
    old_package: &str,
    new_package: &str,
) {
    let node_name = node.element.name.resolve(lookup).unwrap_or_default();
    for attribute in &mut node.element.attributes {
        let attribute_name = attribute.name.resolve(lookup).unwrap_or_default();
        if !is_package_derived_attribute(node_name, attribute_name) {
            continue;
        }
        let ResValueType::String(reference) = attribute.typed_value.data else {
            continue;
        };
        let Some(value) = reference.resolve(lookup) else {
            continue;
        };
        if let Some(rewritten) = replace_package_segments(value, old_package, new_package) {
            attribute.write_string(Cow::Owned(rewritten), strings);
        }
    }
    for child in &mut node.children {
        rewrite_package_derived_attributes(child, lookup, strings, old_package, new_package);
    }
}

fn is_package_derived_attribute(node_name: &str, attribute_name: &str) -> bool {
    ((node_name == "permission" || node_name == "uses-permission") && attribute_name == "name")
        || matches!(
            attribute_name,
            "authorities" | "permission" | "readPermission" | "writePermission"
        )
}

fn replace_package_segments(value: &str, old_package: &str, new_package: &str) -> Option<String> {
    let mut changed = false;
    let values = value
        .split(';')
        .map(|segment| {
            if segment == old_package {
                changed = true;
                new_package.to_owned()
            } else if let Some(suffix) = segment
                .strip_prefix(old_package)
                .and_then(|value| value.strip_prefix('.'))
            {
                changed = true;
                format!("{new_package}.{suffix}")
            } else {
                segment.to_owned()
            }
        })
        .collect::<Vec<_>>();
    changed.then(|| values.join(";"))
}

fn component_class_names(tree: &XMLTree) -> Vec<(String, String)> {
    fn visit(
        node: &resand::xmltree::XMLTreeNode,
        strings: &resand::string_pool::StringPoolHandler,
        output: &mut Vec<(String, String)>,
    ) {
        let node_name = node.element.name.resolve(strings).unwrap_or_default();
        if matches!(
            node_name,
            "application" | "activity" | "activity-alias" | "service" | "receiver" | "provider"
        ) {
            if let Some(attribute) = node.get_attribute("name", strings) {
                if let ResValueType::String(reference) = attribute.typed_value.data {
                    if let Some(value) = reference.resolve(strings) {
                        output.push((node_name.to_owned(), value.to_owned()));
                    }
                }
            }
        }
        for child in &node.children {
            visit(child, strings, output);
        }
    }
    let mut output = Vec::new();
    visit(&tree.root, &tree.string_pool, &mut output);
    output
}

fn has_old_package_derived_value(tree: &XMLTree, old_package: &str) -> bool {
    fn visit(
        node: &resand::xmltree::XMLTreeNode,
        strings: &resand::string_pool::StringPoolHandler,
        old_package: &str,
    ) -> bool {
        let node_name = node.element.name.resolve(strings).unwrap_or_default();
        for attribute in &node.element.attributes {
            let attribute_name = attribute.name.resolve(strings).unwrap_or_default();
            if !is_package_derived_attribute(node_name, attribute_name) {
                continue;
            }
            if let ResValueType::String(reference) = attribute.typed_value.data {
                if reference.resolve(strings).is_some_and(|value| {
                    value.split(';').any(|segment| {
                        segment == old_package
                            || segment
                                .strip_prefix(old_package)
                                .is_some_and(|suffix| suffix.starts_with('.'))
                    })
                }) {
                    return true;
                }
            }
        }
        node.children
            .iter()
            .any(|child| visit(child, strings, old_package))
    }
    visit(&tree.root, &tree.string_pool, old_package)
}

fn read_manifest_identity(bytes: &[u8]) -> CoreResult<ManifestIdentity> {
    let mut cursor = Cursor::new(bytes);
    let tree = XMLTree::read(&mut cursor)
        .map_err(|error| CoreError::parse(format!("读回二进制 AndroidManifest 失败: {error}")))?;
    let strings = &tree.string_pool;
    let manifest = tree
        .root
        .get_element(&["manifest"], strings)
        .ok_or_else(|| CoreError::parse("AndroidManifest 缺少 manifest 节点"))?;
    let application = tree
        .root
        .get_element(&["manifest", "application"], strings)
        .ok_or_else(|| CoreError::parse("AndroidManifest 缺少 application 节点"))?;
    let uses_sdk = tree
        .root
        .get_element(&["manifest", "uses-sdk"], strings)
        .ok_or_else(|| CoreError::parse("AndroidManifest 缺少 uses-sdk 节点"))?;
    Ok(ManifestIdentity {
        package_name: attribute_string(manifest, "package", strings)?,
        display_name: attribute_string(application, "label", strings)?,
        version_name: attribute_string(manifest, "versionName", strings)?,
        version_code: attribute_u32(manifest, "versionCode", strings)?,
        min_sdk: attribute_u32(uses_sdk, "minSdkVersion", strings)?,
    })
}

fn attribute_string(
    node: &resand::xmltree::XMLTreeNode,
    name: &str,
    strings: &resand::string_pool::StringPoolHandler,
) -> CoreResult<String> {
    let attribute = node
        .get_attribute(name, strings)
        .ok_or_else(|| CoreError::parse(format!("AndroidManifest 缺少 {name} 属性")))?;
    match attribute.typed_value.data {
        ResValueType::String(reference) => reference
            .resolve(strings)
            .map(str::to_owned)
            .ok_or_else(|| CoreError::parse(format!("AndroidManifest {name} 字符串无效"))),
        _ => Err(CoreError::parse(format!(
            "AndroidManifest {name} 不是字符串"
        ))),
    }
}

fn attribute_u32(
    node: &resand::xmltree::XMLTreeNode,
    name: &str,
    strings: &resand::string_pool::StringPoolHandler,
) -> CoreResult<u32> {
    let attribute = node
        .get_attribute(name, strings)
        .ok_or_else(|| CoreError::parse(format!("AndroidManifest 缺少 {name} 属性")))?;
    match attribute.typed_value.data {
        ResValueType::IntDec(value) | ResValueType::IntHex(value) => Ok(value),
        _ => Err(CoreError::parse(format!("AndroidManifest {name} 不是整数"))),
    }
}

fn replace_icons(
    entries: &mut [ArchiveEntry],
    path: &Path,
    launcher_icons: &[LauncherIcon],
) -> CoreResult<()> {
    let image = load_icon(path)?;
    entry_mut(entries, LOGO_PATH)?.data = encode_square_png(&image, 512)?;
    for launcher in launcher_icons {
        entry_mut(entries, &launcher.path)?.data = encode_square_png(&image, launcher.side)?;
    }
    Ok(())
}

pub(crate) fn load_icon(path: &Path) -> CoreResult<DynamicImage> {
    let metadata = fs::metadata(path).map_err(CoreError::io)?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_ICON_FILE_BYTES {
        return Err(CoreError::invalid("自定义图标文件大小无效"));
    }
    let bytes = fs::read(path).map_err(CoreError::io)?;
    let reader = ImageReader::new(Cursor::new(&bytes))
        .with_guessed_format()
        .map_err(|_| CoreError::invalid("无法识别自定义图标格式"))?;
    let (width, height) = reader
        .into_dimensions()
        .map_err(|_| CoreError::invalid("无法读取自定义图标尺寸"))?;
    if width == 0
        || height == 0
        || u64::from(width).saturating_mul(u64::from(height)) > MAX_ICON_PIXELS
    {
        return Err(CoreError::invalid("自定义图标尺寸过大或无效"));
    }
    image::load_from_memory(&bytes).map_err(|_| CoreError::invalid("自定义图标已损坏"))
}

pub(crate) fn encode_square_png(image: &DynamicImage, side: u32) -> CoreResult<Vec<u8>> {
    let source = image.to_rgba8();
    let scale =
        (side as f64 / f64::from(source.width())).min(side as f64 / f64::from(source.height()));
    let width = (f64::from(source.width()) * scale).round().max(1.0) as u32;
    let height = (f64::from(source.height()) * scale).round().max(1.0) as u32;
    let resized = imageops::resize(&source, width, height, imageops::FilterType::Lanczos3);
    let mut square = RgbaImage::new(side, side);
    imageops::overlay(
        &mut square,
        &resized,
        i64::from((side - resized.width()) / 2),
        i64::from((side - resized.height()) / 2),
    );
    let mut encoded = Vec::new();
    PngEncoder::new_with_quality(&mut encoded, CompressionType::Best, FilterType::Adaptive)
        .write_image(&square, side, side, ExtendedColorType::Rgba8)
        .map_err(|_| CoreError::new("image_error", "编码自定义图标失败", false))?;
    Ok(encoded)
}

fn verify_signed_payload(
    path: &Path,
    identity: &RuntimeIdentity,
    runtime: &Value,
) -> CoreResult<()> {
    let mut entries = read_archive(path)?;
    let manifest = read_manifest_identity(&entry_mut(&mut entries, MANIFEST_PATH)?.data)?;
    if manifest.package_name != identity.application_id
        || manifest.display_name != identity.display_name
        || manifest.version_name != identity.version_name
        || manifest.version_code != identity.version_code
        || manifest.min_sdk < 24
    {
        return Err(CoreError::parse("签名后 AndroidManifest 身份校验失败"));
    }
    let actual: Value = serde_json::from_slice(&entry_mut(&mut entries, RUNTIME_PATH)?.data)
        .map_err(|_| CoreError::parse("签名后运行时配置已损坏"))?;
    if &actual != runtime {
        return Err(CoreError::parse("签名后运行时配置读回不一致"));
    }
    let resources = entry_mut(&mut entries, "resources.arsc")?;
    let table = ResTable::try_from(resources.data.as_slice())
        .map_err(|error| CoreError::parse(format!("签名后 resources.arsc 无效: {error}")))?;
    if table.packages.first().map(|package| package.name.as_str())
        != Some(identity.application_id.as_str())
        || launcher_paths(&table)?.len() != 5
    {
        return Err(CoreError::parse("签名后 resources.arsc 身份校验失败"));
    }
    Ok(())
}

fn load_or_create_identity(path: &Path) -> CoreResult<SigningIdentity> {
    if path.exists() {
        return load_identity(path);
    }
    let parent = path
        .parent()
        .filter(|value| !value.as_os_str().is_empty())
        .ok_or_else(|| CoreError::invalid("签名身份路径缺少父目录"))?;
    fs::create_dir_all(parent).map_err(CoreError::io)?;

    let private_key = RsaPrivateKey::new(&mut OsRng, 2048)
        .map_err(|_| CoreError::new("signing_error", "生成 RSA-2048 签名私钥失败", false))?;
    let pkcs8 = private_key
        .to_pkcs8_der()
        .map_err(|_| CoreError::new("signing_error", "编码签名私钥失败", false))?;
    let key_pair = KeyPair::try_from(pkcs8.as_bytes())
        .map_err(|_| CoreError::new("signing_error", "加载 RSA 签名私钥失败", false))?;
    let mut params = CertificateParams::default();
    params.not_before = date_time_ymd(2024, 1, 1);
    params.not_after = date_time_ymd(2124, 1, 1);
    params.is_ca = IsCa::NoCa;
    params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    let mut name = DistinguishedName::new();
    name.push(DnType::CommonName, "LanzouYOU Custom Library");
    params.distinguished_name = name;
    let certificate_der = params
        .self_signed(&key_pair)
        .map_err(|_| CoreError::new("signing_error", "生成自签名证书失败", false))?
        .der()
        .to_vec();
    let stored = StoredSigningIdentity {
        version: SIGNING_IDENTITY_VERSION,
        private_key_pkcs8: BASE64.encode(pkcs8.as_bytes()),
        certificate_der: BASE64.encode(&certificate_der),
    };
    let bytes = serde_json::to_vec(&stored)
        .map_err(|_| CoreError::new("signing_error", "编码签名身份失败", false))?;
    let temp = super::repackage_common::temp_sibling(path, "identity")?;
    let write_result = write_private_identity(&temp, &bytes);
    if let Err(error) = write_result {
        let _ = fs::remove_file(&temp);
        return Err(error);
    }
    match super::repackage_common::commit_file(&temp, path) {
        Ok(()) => {}
        Err(_) if path.exists() => {
            let _ = fs::remove_file(&temp);
            return load_identity(path);
        }
        Err(error) => {
            let _ = fs::remove_file(&temp);
            return Err(error);
        }
    }
    validate_identity(private_key, certificate_der)
}

fn write_private_identity(path: &Path, bytes: &[u8]) -> CoreResult<()> {
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path).map_err(CoreError::io)?;
    file.write_all(bytes).map_err(CoreError::io)?;
    file.sync_all().map_err(CoreError::io)
}

fn load_identity(path: &Path) -> CoreResult<SigningIdentity> {
    let metadata = fs::metadata(path).map_err(CoreError::io)?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > 65_536 {
        return Err(CoreError::new(
            "signing_error",
            "现有 Android 签名身份文件大小无效",
            false,
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    File::open(path)
        .and_then(|mut file| file.read_to_end(&mut bytes))
        .map_err(CoreError::io)?;
    let stored: StoredSigningIdentity = serde_json::from_slice(&bytes)
        .map_err(|_| CoreError::new("signing_error", "现有 Android 签名身份文件已损坏", false))?;
    if stored.version != SIGNING_IDENTITY_VERSION {
        return Err(CoreError::new(
            "signing_error",
            "现有 Android 签名身份版本不受支持",
            false,
        ));
    }
    let private_der = BASE64
        .decode(stored.private_key_pkcs8)
        .map_err(|_| CoreError::new("signing_error", "现有 Android 签名私钥编码无效", false))?;
    let certificate_der = BASE64
        .decode(stored.certificate_der)
        .map_err(|_| CoreError::new("signing_error", "现有 Android 签名证书编码无效", false))?;
    let private_key = RsaPrivateKey::from_pkcs8_der(&private_der)
        .map_err(|_| CoreError::new("signing_error", "现有 Android 签名私钥无效", false))?;
    validate_identity(private_key, certificate_der)
}

fn validate_identity(
    private_key: RsaPrivateKey,
    certificate_der: Vec<u8>,
) -> CoreResult<SigningIdentity> {
    if private_key.n().bits() != 2048 {
        return Err(CoreError::new(
            "signing_error",
            "Android 签名身份必须使用 RSA-2048",
            false,
        ));
    }
    let certificate = Certificate::from_der(&certificate_der)
        .map_err(|_| CoreError::new("signing_error", "Android 签名证书 DER 无效", false))?;
    let expected = private_key
        .to_public_key()
        .to_public_key_der()
        .map_err(|_| CoreError::new("signing_error", "编码签名公钥失败", false))?;
    let actual = certificate
        .tbs_certificate
        .subject_public_key_info
        .to_der()
        .map_err(|_| CoreError::new("signing_error", "读取签名证书公钥失败", false))?;
    if actual != expected.as_bytes() {
        return Err(CoreError::new(
            "signing_error",
            "Android 签名证书与私钥不匹配",
            false,
        ));
    }
    Ok(SigningIdentity {
        private_key,
        certificate_der,
    })
}

fn ensure_identity_path_distinct(
    template: &Path,
    output: &Path,
    identity: &Path,
) -> CoreResult<()> {
    if identity.as_os_str().is_empty() || identity == template || identity == output {
        return Err(CoreError::invalid("签名身份路径不能与壳模板或输出路径相同"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{collections::HashMap, fs::File, io::Write};

    use resand::{
        defs::ResTableRef,
        manifest::{
            Activity, AndroidManifest, Application, ContentProvider, Permission, UsesPermission,
            UsesSdk,
        },
        resources::{
            EntryHandle, ResourceEntry, ResourceEntryData, ResourcePackage, ResourceTable,
            ResourceType, ResourceValue,
        },
        table::ResTableConfig,
        traits::{IntoNode, Referenced},
    };
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
                "officialUrl": "https://example.com",
                "publisher": "测试发布者",
                "logoAsset": "assets/runtime/logo.png",
                "themeMode": "system"
            },
            "sources": [{
                "sourceId": "source-1",
                "title": "软件库",
                "shareUrl": "https://www.lanzouw.com/b123",
                "password": "secret",
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

    fn synthetic_manifest() -> Vec<u8> {
        let manifest = AndroidManifest {
            version_code: 1,
            version_name: Some("0.1.0".to_owned()),
            package: "cc.nkbr.template".to_owned(),
            uses_sdk: vec![UsesSdk {
                min_sdk_version: 24,
                target_sdk_version: 35,
                max_sdk_version: None,
            }],
            application: Application {
                label: Some(ResTableRef::new(0x7f01_0000)),
                activity: vec![Activity {
                    name: "cc.nkbr.template.MainActivity".to_owned(),
                    ..Activity::default()
                }],
                provider: vec![ContentProvider {
                    name: "androidx.startup.InitializationProvider".to_owned(),
                    authorities: Referenced::T("cc.nkbr.template.androidx-startup".to_owned()),
                    ..ContentProvider::default()
                }],
                ..Application::default()
            },
            permission: vec![Permission {
                name: Referenced::T(
                    "cc.nkbr.template.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION".to_owned(),
                ),
                ..Permission::default()
            }],
            uses_permission: vec![UsesPermission {
                name: Referenced::T(
                    "cc.nkbr.template.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION".to_owned(),
                ),
                max_sdk_version: None,
            }],
            ..AndroidManifest::default()
        };
        let tree = manifest.into_tree();
        let mut cursor = Cursor::new(Vec::new());
        tree.write(&mut cursor).unwrap();
        cursor.into_inner()
    }

    fn synthetic_resources() -> (Vec<u8>, Vec<(String, u32)>) {
        let paths = EXPECTED_LAUNCHER_SIZES
            .iter()
            .enumerate()
            .map(|(index, side)| (format!("res/i{index}.png"), *side))
            .collect::<Vec<_>>();
        let mut handle = EntryHandle::default();
        for (index, (path, _)) in paths.iter().enumerate() {
            let config = ResTableConfig {
                screen_type: Some((index + 1) as u32),
                ..ResTableConfig::default()
            };
            handle.entries.insert(
                (0, config),
                ResourceEntry {
                    flags: Default::default(),
                    data: ResourceEntryData::KeyPair {
                        key: "ic_launcher".to_owned(),
                        value: ResourceValue::String(path.clone()),
                    },
                },
            );
        }
        let table: ResTable = ResourceTable {
            packages: HashMap::from([(
                0x7f,
                ResourcePackage {
                    name: "cc.nkbr.template".to_owned(),
                    types: HashMap::from([(
                        1,
                        ResourceType {
                            name: "mipmap".to_owned(),
                            entries: HashMap::from([(0, handle)]),
                        },
                    )]),
                },
            )]),
        }
        .into();
        (Vec::<u8>::try_from(table).unwrap(), paths)
    }

    fn write_template(path: &Path) {
        let mut writer = ZipWriter::new(File::create(path).unwrap());
        let deflated = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
        let stored = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        writer.start_file(MANIFEST_PATH, deflated).unwrap();
        writer.write_all(&synthetic_manifest()).unwrap();
        let (resources, icons) = synthetic_resources();
        writer.start_file("resources.arsc", stored).unwrap();
        writer.write_all(&resources).unwrap();
        writer.start_file(RUNTIME_PATH, deflated).unwrap();
        writer.write_all(b"{}").unwrap();
        writer.start_file(LOGO_PATH, deflated).unwrap();
        writer.write_all(b"old logo").unwrap();
        for (path, side) in icons {
            writer.start_file(path, deflated).unwrap();
            writer
                .write_all(&encode_square_png(&DynamicImage::new_rgba8(side, side), side).unwrap())
                .unwrap();
        }
        writer
            .start_file("lib/arm64-v8a/libapp.so", stored)
            .unwrap();
        writer.write_all(b"native").unwrap();
        writer.start_file("META-INF/MANIFEST.MF", deflated).unwrap();
        writer.write_all(b"old signature").unwrap();
        writer
            .start_file("META-INF/services/keep.txt", deflated)
            .unwrap();
        writer.write_all(b"keep").unwrap();
        writer.finish().unwrap();
    }

    #[test]
    fn test_signing_identity_is_stable_and_never_serializes_in_result() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("identity.bin");
        let first = load_or_create_identity(&path).unwrap();
        let first_certificate = first.certificate_der.clone();
        let second = load_or_create_identity(&path).unwrap();
        assert_eq!(first_certificate, second.certificate_der);
        let response = AndroidRepackageResult {
            apk_path: "x.apk".to_owned(),
            bytes: 1,
            signing_verified: true,
            package_name: "cc.nkbr.library".to_owned(),
            version_name: "1.0.0".to_owned(),
            version_code: 1,
        };
        let json = serde_json::to_string(&response).unwrap();
        assert!(!json.contains("private"));
        assert!(!json.contains("pkcs8"));
    }

    #[test]
    fn test_icon_encoder_generates_exact_launcher_size() {
        let image = DynamicImage::new_rgba8(20, 10);
        let encoded = encode_square_png(&image, 72).unwrap();
        let decoded = image::load_from_memory(&encoded).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (72, 72));
    }

    #[test]
    fn test_android_repackage_roundtrip_rewrites_manifest_assets_aligns_and_signs() {
        let temp = tempdir().unwrap();
        let template = temp.path().join("template.apk");
        let output = temp.path().join("custom.apk");
        let icon = temp.path().join("icon.png");
        let identity = temp.path().join("private/identity.bin");
        write_template(&template);
        DynamicImage::new_rgba8(64, 32)
            .save_with_format(&icon, image::ImageFormat::Png)
            .unwrap();

        let result = repackage_android(AndroidRepackageRequest {
            template_path: template.to_string_lossy().into_owned(),
            output_path: output.to_string_lossy().into_owned(),
            runtime_config: runtime(),
            icon_path: Some(icon.to_string_lossy().into_owned()),
            signing_identity_path: identity.to_string_lossy().into_owned(),
        })
        .unwrap();
        assert_eq!(result.package_name, "cc.nkbr.offline");
        assert_eq!(result.version_name, "1.2.3");
        assert_eq!(result.version_code, 3);
        assert_eq!(result.bytes, fs::metadata(&output).unwrap().len());
        assert!(result.signing_verified);
        Apk::new(output.clone()).unwrap().verify().unwrap();

        let mut archive = ZipArchive::new(File::open(output).unwrap()).unwrap();
        assert!(archive.by_name("META-INF/MANIFEST.MF").is_err());
        assert!(archive.by_name("META-INF/services/keep.txt").is_ok());
        let mut manifest_bytes = Vec::new();
        archive
            .by_name(MANIFEST_PATH)
            .unwrap()
            .read_to_end(&mut manifest_bytes)
            .unwrap();
        let manifest_tree = XMLTree::read(&mut Cursor::new(&manifest_bytes)).unwrap();
        assert!(!has_old_package_derived_value(
            &manifest_tree,
            "cc.nkbr.template"
        ));
        assert!(component_class_names(&manifest_tree)
            .iter()
            .any(|(_, name)| { name == "cc.nkbr.template.MainActivity" }));
        let native_start = archive
            .by_name("lib/arm64-v8a/libapp.so")
            .unwrap()
            .data_start();
        assert_eq!(native_start % 16_384, 0);
        let resources_start = archive.by_name("resources.arsc").unwrap().data_start();
        assert_eq!(resources_start % 4, 0);
    }

    #[test]
    fn test_real_flutter_resources_roundtrip_when_build_fixture_exists() {
        let project = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let candidates = [
            project.join("build/app/outputs/apk/release/app-release.apk"),
            project.join("build/app/outputs/apk/debug/app-debug.apk"),
        ];
        let Some(apk) = candidates.iter().find(|path| path.is_file()) else {
            return;
        };
        let mut archive = ZipArchive::new(File::open(apk).unwrap()).unwrap();
        let mut bytes = Vec::new();
        archive
            .by_name("resources.arsc")
            .unwrap()
            .read_to_end(&mut bytes)
            .unwrap();
        let (rewritten, paths) = rewrite_resources(&bytes, "cc.nkbr.fixture").unwrap();
        assert_eq!(paths.len(), 5);
        assert!(!rewritten.is_empty());
        for path in paths {
            assert!(archive.by_name(&path).is_ok(), "missing {path}");
        }
    }

    #[test]
    fn test_real_library_shell_release_repackages_when_build_fixture_exists() {
        let shell = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../LanzouLibraryShell");
        let template = shell.join("build/app/outputs/flutter-apk/app-release.apk");
        let icon = shell.join("assets/runtime/logo.png");
        if !template.is_file() || !icon.is_file() {
            return;
        }

        let temp = tempdir().unwrap();
        let output = temp.path().join("real-shell-custom.apk");
        let identity = temp.path().join("private/android-signing.json");
        let result = repackage_android(AndroidRepackageRequest {
            template_path: template.to_string_lossy().into_owned(),
            output_path: output.to_string_lossy().into_owned(),
            runtime_config: runtime(),
            icon_path: Some(icon.to_string_lossy().into_owned()),
            signing_identity_path: identity.to_string_lossy().into_owned(),
        })
        .unwrap();

        assert_eq!(result.package_name, "cc.nkbr.offline");
        Apk::new(output.clone()).unwrap().verify().unwrap();
        let mut archive = ZipArchive::new(File::open(output).unwrap()).unwrap();
        assert!(archive.by_name(RUNTIME_PATH).is_ok());
        assert!(archive.by_name(LOGO_PATH).is_ok());
        for index in 0..archive.len() {
            let entry = archive.by_index(index).unwrap();
            if entry.name().starts_with("lib/")
                && entry.name().ends_with(".so")
                && entry.compression() == CompressionMethod::Stored
            {
                assert_eq!(entry.data_start() % 16_384, 0, "{}", entry.name());
            }
        }
    }
}
