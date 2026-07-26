use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::Read,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

use image::{
    codecs::png::{CompressionType, FilterType, PngEncoder},
    imageops, DynamicImage, ExtendedColorType, ImageEncoder, ImageFormat, RgbaImage,
};
use serde_json::{json, Value};
use zip::ZipArchive;

use crate::error::{CoreError, CoreResult};
use crate::{
    http_client::merge_cookie_headers,
    parser,
    session::{map, SessionClient},
};

const MAX_ICON_BYTES: u64 = 100_000;
const MAX_ICON_SIDE: u32 = 144;
const MAX_ARCHIVE_ENTRY_BYTES: u64 = 8 * 1024 * 1024;
static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

struct IconPolicy {
    host: String,
    policy: String,
    access_id: String,
    signature: String,
    callback: String,
    directory: String,
}

#[derive(Debug)]
pub(crate) struct IconUpload {
    pub path: PathBuf,
    pub extension: &'static str,
    pub media_type: &'static str,
}

pub(crate) fn prepare_icon(source_path: &str, output_path: Option<&str>) -> CoreResult<Value> {
    let source = checked_file(source_path)?;
    let extension = source
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let (image, source_kind) = match extension.as_str() {
        "apk" => (extract_apk_launcher(&source)?, "apk"),
        "exe" => (extract_exe_icon(&source)?, "exe"),
        _ => (load_direct_image(&source)?, "image"),
    };
    let (encoded, width, height) = normalize_png(image)?;
    if encoded.len() as u64 >= MAX_ICON_BYTES {
        return Err(CoreError::invalid("处理后的图标必须严格小于 100KB"));
    }

    let destination = destination_path(output_path)?;
    if destination
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| !value.eq_ignore_ascii_case("png"))
        .unwrap_or(true)
    {
        return Err(CoreError::invalid("outputPath 必须使用 .png 扩展名"));
    }
    if let Some(parent) = destination.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)?;
        }
    }
    fs::write(&destination, &encoded)?;
    let path = absolute_path(&destination)?;
    Ok(json!({
        "path": path.to_string_lossy(),
        "mediaType": "image/png",
        "bytes": encoded.len(),
        "width": width,
        "height": height,
        "sourceKind": source_kind,
    }))
}

pub(crate) fn validate_icon_upload(path: &str) -> CoreResult<IconUpload> {
    let path = checked_file(path)?;
    let bytes = fs::read(&path)?;
    if bytes.is_empty() || bytes.len() as u64 >= MAX_ICON_BYTES {
        return Err(CoreError::invalid("图标必须非空且严格小于 100KB"));
    }
    let format = image::guess_format(&bytes)
        .map_err(|_| CoreError::invalid("图标格式必须为 PNG/JPG/GIF/BMP"))?;
    let (extension, media_type) = match format {
        ImageFormat::Png => ("png", "image/png"),
        ImageFormat::Jpeg => ("jpg", "image/jpeg"),
        ImageFormat::Gif => ("gif", "image/gif"),
        ImageFormat::Bmp => ("bmp", "image/bmp"),
        _ => return Err(CoreError::invalid("图标格式必须为 PNG/JPG/GIF/BMP")),
    };
    let decoded = image::load_from_memory_with_format(&bytes, format)
        .map_err(|_| CoreError::invalid("图标文件已损坏或无法解码"))?;
    if decoded.width() == 0 || decoded.height() == 0 {
        return Err(CoreError::invalid("图标尺寸无效"));
    }
    Ok(IconUpload {
        path,
        extension,
        media_type,
    })
}

impl SessionClient {
    pub fn set_icon(&self, file_id: &str, path: &str) -> CoreResult<Value> {
        self.require_session()?;
        crate::validation::id(file_id, "fileId")?;
        let upload = validate_icon_upload(path)?;
        let binding_form = map(&[("task", "41"), ("file_id", file_id)]);
        let initial = self.task_raw_with_cookie(binding_form.clone(), &self.cookie)?;
        let (token, previous_url) = binding_info(&initial, false)?;
        let binding_cookie = format!("file_id_ico={}", js_escape(&token));
        let cookie = merge_cookie_headers(&self.cookie, &binding_cookie);

        let policy_url = format!("{}/upimg/php/get.php", self.http.bases.pc);
        let response =
            self.http
                .get(&policy_url, &cookie, &[("type".to_owned(), "2".to_owned())])?;
        let policy_value: Value = serde_json::from_str(response.text()?)
            .map_err(|_| CoreError::parse("图标上传策略返回了无效 JSON"))?;
        let policy = parse_icon_policy(&policy_value)?;
        self.http.validate_icon_oss_url(&policy.host)?;
        let object_key = object_key(&policy.directory, upload.extension)?;
        let fields = BTreeMap::from([
            ("key".to_owned(), object_key.clone()),
            ("policy".to_owned(), policy.policy),
            ("OSSAccessKeyId".to_owned(), policy.access_id),
            ("success_action_status".to_owned(), "200".to_owned()),
            ("callback".to_owned(), policy.callback),
            ("signature".to_owned(), policy.signature),
        ]);
        self.http.upload_icon_oss(
            &policy.host,
            &fields,
            &upload.path,
            upload.extension,
            upload.media_type,
        )?;

        let task38 = self.task_with_cookie(
            map(&[("task", "38"), ("img", &object_key), ("type", "2")]),
            &cookie,
        );
        if let Err(error) = task38 {
            if error.code == "ambiguous_result" {
                let readback = self.task_raw_with_cookie(binding_form, &cookie)?;
                if binding_info(&readback, true)
                    .ok()
                    .and_then(|(_, url)| url)
                    .filter(|url| previous_url.as_deref() != Some(url.as_str()))
                    .is_some()
                {
                    return Ok(json!({"fileId": file_id}));
                }
            }
            return Err(error);
        }

        let readback = self.task_raw_with_cookie(binding_form, &cookie)?;
        binding_info(&readback, true)?;
        Ok(json!({"fileId": file_id}))
    }
}

fn parse_icon_policy(value: &Value) -> CoreResult<IconPolicy> {
    let field = |name: &str| -> CoreResult<String> {
        value
            .get(name)
            .and_then(Value::as_str)
            .filter(|item| {
                !item.is_empty() && item.len() <= 16 * 1024 && !item.contains(['\0', '\r', '\n'])
            })
            .map(ToOwned::to_owned)
            .ok_or_else(|| CoreError::parse(format!("图标上传策略缺少 {name}")))
    };
    if value
        .get("expire")
        .and_then(parser::value_as_i64)
        .filter(|expire| *expire > 0)
        .is_none()
    {
        return Err(CoreError::parse("图标上传策略缺少 expire"));
    }
    let directory = field("dir")?;
    if directory.contains("..") || directory.starts_with(['/', '\\']) {
        return Err(CoreError::parse("图标上传目录无效"));
    }
    Ok(IconPolicy {
        host: field("host")?,
        policy: field("policy")?,
        access_id: field("accessid")?,
        signature: field("signature")?,
        callback: field("callback")?,
        directory,
    })
}

fn binding_info(value: &Value, require_icon: bool) -> CoreResult<(String, Option<String>)> {
    let status = value
        .get("zt")
        .and_then(parser::value_as_i64)
        .ok_or_else(|| CoreError::parse("图标绑定状态缺少 zt"))?;
    if !matches!(status, 0 | 1) || (require_icon && status != 1) {
        return Err(CoreError::remote("图标绑定回读未确认成功", false));
    }
    let info = value
        .get("info")
        .and_then(Value::as_array)
        .ok_or_else(|| CoreError::parse("图标绑定状态缺少 info"))?;
    let token = info
        .first()
        .and_then(Value::as_str)
        .filter(|value| {
            !value.is_empty() && value.len() <= 512 && !value.contains(['\0', '\r', '\n'])
        })
        .map(ToOwned::to_owned)
        .ok_or_else(|| CoreError::parse("图标绑定 token 无效"))?;
    let icon_url = info
        .get(1)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .and_then(trusted_icon_readback_url);
    if require_icon && icon_url.is_none() {
        return Err(CoreError::remote("图标绑定回读地址无效", false));
    }
    Ok((token, icon_url))
}

fn trusted_icon_readback_url(value: &str) -> Option<String> {
    let url = reqwest::Url::parse(value).ok()?;
    if url.scheme() != "https"
        || url.host_str() != Some("image.dmpdmp.com")
        || !url.username().is_empty()
        || url.password().is_some()
        || !matches!(url.port(), None | Some(443))
    {
        return None;
    }
    Some(value.to_owned())
}

fn object_key(directory: &str, extension: &str) -> CoreResult<String> {
    if directory.is_empty()
        || directory.len() > 2_048
        || directory.contains(['\0', '\r', '\n'])
        || directory.contains("..")
    {
        return Err(CoreError::parse("图标上传目录无效"));
    }
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos() as u64)
        .unwrap_or_default()
        ^ TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    let first = seed % 8 + 1;
    let second = (seed / 8) % 8 + 1;
    Ok(format!("{directory}{first}{second}.{extension}"))
}

fn js_escape(value: &str) -> String {
    let mut escaped = String::new();
    for unit in value.encode_utf16() {
        if unit <= 0x7f {
            let byte = unit as u8;
            if byte.is_ascii_alphanumeric() || b"@*_+-./".contains(&byte) {
                escaped.push(byte as char);
            } else {
                escaped.push_str(&format!("%{byte:02X}"));
            }
        } else if unit <= 0xff {
            escaped.push_str(&format!("%{unit:02X}"));
        } else {
            escaped.push_str(&format!("%u{unit:04X}"));
        }
    }
    escaped
}

#[cfg(any(windows, test))]
fn compose_color_icon(bgra: &[u8], and_mask: &[u8]) -> CoreResult<Vec<u8>> {
    if bgra.len() != and_mask.len() || !bgra.len().is_multiple_of(4) {
        return Err(CoreError::parse("EXE 图标颜色或遮罩数据长度无效"));
    }
    let source_has_alpha = bgra.chunks_exact(4).any(|pixel| pixel[3] != 0);
    let mut rgba = Vec::with_capacity(bgra.len());
    for (pixel, mask) in bgra.chunks_exact(4).zip(and_mask.chunks_exact(4)) {
        let masked = mask[0] != 0 || mask[1] != 0 || mask[2] != 0;
        rgba.extend_from_slice(&[
            pixel[2],
            pixel[1],
            pixel[0],
            if masked {
                0
            } else if source_has_alpha {
                pixel[3]
            } else {
                255
            },
        ]);
    }
    Ok(rgba)
}

#[cfg(any(windows, test))]
fn compose_monochrome_icon(and_mask: &[u8], xor_mask: &[u8]) -> CoreResult<Vec<u8>> {
    if and_mask.len() != xor_mask.len() || !and_mask.len().is_multiple_of(4) {
        return Err(CoreError::parse("EXE 单色图标遮罩数据长度无效"));
    }
    let mut rgba = Vec::with_capacity(and_mask.len());
    for (and_pixel, xor_pixel) in and_mask.chunks_exact(4).zip(xor_mask.chunks_exact(4)) {
        let and_bit = and_pixel[0] != 0 || and_pixel[1] != 0 || and_pixel[2] != 0;
        let xor_bit = xor_pixel[0] != 0 || xor_pixel[1] != 0 || xor_pixel[2] != 0;
        let pixel = match (and_bit, xor_bit) {
            (true, false) => [0, 0, 0, 0],
            (false, false) => [0, 0, 0, 255],
            (false, true) => [255, 255, 255, 255],
            // (AND=1, XOR=1) means invert the destination. RGBA cannot encode
            // that raster operation, so transparent is the deterministic fit.
            (true, true) => [0, 0, 0, 0],
        };
        rgba.extend_from_slice(&pixel);
    }
    Ok(rgba)
}

#[cfg(not(windows))]
fn extract_exe_icon(_path: &Path) -> CoreResult<DynamicImage> {
    Err(CoreError::new(
        "unsupported_platform",
        "EXE 图标提取仅在 Windows 客户端可用",
        false,
    ))
}

#[cfg(windows)]
fn extract_exe_icon(path: &Path) -> CoreResult<DynamicImage> {
    windows_exe::extract(path)
}

#[cfg(windows)]
mod windows_exe {
    use std::{
        ffi::c_void,
        mem::{size_of, zeroed},
        os::windows::ffi::OsStrExt,
        path::Path,
        ptr::null_mut,
    };

    use image::{DynamicImage, RgbaImage};
    use windows_sys::Win32::{
        Foundation::S_OK,
        Graphics::Gdi::{
            CreateCompatibleDC, DeleteDC, DeleteObject, GetDIBits, GetObjectW, BITMAP, BITMAPINFO,
            BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBITMAP, HDC,
        },
        UI::{
            Shell::{ExtractIconExW, SHDefExtractIconW},
            WindowsAndMessaging::{DestroyIcon, GetIconInfo, HICON, ICONINFO},
        },
    };

    use super::{compose_color_icon, compose_monochrome_icon};
    use crate::error::{CoreError, CoreResult};

    struct OwnedIcon(HICON);

    impl Drop for OwnedIcon {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { DestroyIcon(self.0) };
            }
        }
    }

    struct OwnedBitmap(HBITMAP);

    impl Drop for OwnedBitmap {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { DeleteObject(self.0) };
            }
        }
    }

    struct OwnedDc(HDC);

    impl Drop for OwnedDc {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { DeleteDC(self.0) };
            }
        }
    }

    pub(super) fn extract(path: &Path) -> CoreResult<DynamicImage> {
        let wide: Vec<u16> = path
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let icon = extract_handle(&wide)?;
        icon_to_image(&icon)
    }

    fn extract_handle(path: &[u16]) -> CoreResult<OwnedIcon> {
        let mut large: HICON = null_mut();
        let mut small: HICON = null_mut();
        let size = 256_u32 | (256_u32 << 16);
        let result =
            unsafe { SHDefExtractIconW(path.as_ptr(), 0, 0, &mut large, &mut small, size) };
        let large = (!large.is_null()).then(|| OwnedIcon(large));
        let small = (!small.is_null()).then(|| OwnedIcon(small));
        if result == S_OK {
            if let Some(icon) = large {
                return Ok(icon);
            }
            if let Some(icon) = small {
                return Ok(icon);
            }
        }
        drop(large);
        drop(small);

        let mut large: HICON = null_mut();
        let mut small: HICON = null_mut();
        let count = unsafe { ExtractIconExW(path.as_ptr(), 0, &mut large, &mut small, 1) };
        let large = (!large.is_null()).then(|| OwnedIcon(large));
        let small = (!small.is_null()).then(|| OwnedIcon(small));
        if count == 0 || count == u32::MAX {
            return Err(CoreError::invalid("EXE 中没有可提取的应用图标"));
        }
        large
            .or(small)
            .ok_or_else(|| CoreError::invalid("EXE 图标句柄无效"))
    }

    fn icon_to_image(icon: &OwnedIcon) -> CoreResult<DynamicImage> {
        let mut info: ICONINFO = unsafe { zeroed() };
        if unsafe { GetIconInfo(icon.0, &mut info) } == 0 {
            return Err(CoreError::io("GetIconInfo 失败"));
        }
        let color = (!info.hbmColor.is_null()).then(|| OwnedBitmap(info.hbmColor));
        let mask = (!info.hbmMask.is_null()).then(|| OwnedBitmap(info.hbmMask));
        let mask = mask.ok_or_else(|| CoreError::parse("EXE 图标缺少遮罩位图"))?;

        let (width, height, monochrome) = if let Some(color) = color.as_ref() {
            let bitmap = bitmap_info(color.0)?;
            (
                checked_dimension(bitmap.bmWidth)?,
                checked_dimension(bitmap.bmHeight)?,
                false,
            )
        } else {
            let bitmap = bitmap_info(mask.0)?;
            let width = checked_dimension(bitmap.bmWidth)?;
            let full_height = checked_dimension(bitmap.bmHeight)?;
            if full_height % 2 != 0 {
                return Err(CoreError::parse("EXE 单色图标遮罩高度无效"));
            }
            (width, full_height / 2, true)
        };

        let rgba = if monochrome {
            let masks = read_bitmap(mask.0, width, height * 2)?;
            let row_bytes = usize::try_from(width)
                .ok()
                .and_then(|value| value.checked_mul(4))
                .ok_or_else(|| CoreError::parse("EXE 图标尺寸溢出"))?;
            let half = row_bytes
                .checked_mul(height as usize)
                .ok_or_else(|| CoreError::parse("EXE 图标尺寸溢出"))?;
            compose_monochrome_icon(&masks[..half], &masks[half..])?
        } else {
            let color_bytes = read_bitmap(color.as_ref().unwrap().0, width, height)?;
            let mask_bytes = read_bitmap(mask.0, width, height)?;
            compose_color_icon(&color_bytes, &mask_bytes)?
        };
        let image = RgbaImage::from_raw(width, height, rgba)
            .ok_or_else(|| CoreError::parse("EXE 图标 RGBA 数据长度无效"))?;
        Ok(DynamicImage::ImageRgba8(image))
    }

    fn bitmap_info(handle: HBITMAP) -> CoreResult<BITMAP> {
        let mut bitmap: BITMAP = unsafe { zeroed() };
        let copied = unsafe {
            GetObjectW(
                handle,
                size_of::<BITMAP>() as i32,
                &mut bitmap as *mut BITMAP as *mut c_void,
            )
        };
        if copied == 0 {
            Err(CoreError::io("GetObjectW 读取 EXE 图标失败"))
        } else {
            Ok(bitmap)
        }
    }

    fn checked_dimension(value: i32) -> CoreResult<u32> {
        let value = value.unsigned_abs();
        if (1..=4096).contains(&value) {
            Ok(value)
        } else {
            Err(CoreError::invalid("EXE 图标尺寸超出 1..4096"))
        }
    }

    fn read_bitmap(handle: HBITMAP, width: u32, height: u32) -> CoreResult<Vec<u8>> {
        let length = (width as usize)
            .checked_mul(height as usize)
            .and_then(|value| value.checked_mul(4))
            .ok_or_else(|| CoreError::parse("EXE 图标尺寸溢出"))?;
        let dc = OwnedDc(unsafe { CreateCompatibleDC(null_mut()) });
        if dc.0.is_null() {
            return Err(CoreError::io("CreateCompatibleDC 失败"));
        }
        let mut bitmap_info: BITMAPINFO = unsafe { zeroed() };
        bitmap_info.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
        bitmap_info.bmiHeader.biWidth = width as i32;
        bitmap_info.bmiHeader.biHeight = -(height as i32);
        bitmap_info.bmiHeader.biPlanes = 1;
        bitmap_info.bmiHeader.biBitCount = 32;
        bitmap_info.bmiHeader.biCompression = BI_RGB;
        let mut bytes = vec![0_u8; length];
        let lines = unsafe {
            GetDIBits(
                dc.0,
                handle,
                0,
                height,
                bytes.as_mut_ptr() as *mut c_void,
                &mut bitmap_info,
                DIB_RGB_COLORS,
            )
        };
        if lines != height as i32 {
            return Err(CoreError::io("GetDIBits 读取 EXE 图标失败"));
        }
        Ok(bytes)
    }
}

fn checked_file(path: &str) -> CoreResult<PathBuf> {
    if path.trim().is_empty() || path.contains(['\0', '\r', '\n']) {
        return Err(CoreError::invalid("本地文件路径无效"));
    }
    let path = PathBuf::from(path);
    if !path.is_file() {
        return Err(CoreError::invalid("本地文件不存在或不是普通文件"));
    }
    Ok(path)
}

fn load_direct_image(path: &Path) -> CoreResult<DynamicImage> {
    let metadata = path.metadata()?;
    if metadata.len() > 32 * 1024 * 1024 {
        return Err(CoreError::invalid("源图标文件不能超过 32MB"));
    }
    let bytes = fs::read(path)?;
    let format = image::guess_format(&bytes)
        .map_err(|_| CoreError::invalid("源图标格式必须为 PNG/JPG/GIF/BMP"))?;
    if !matches!(
        format,
        ImageFormat::Png | ImageFormat::Jpeg | ImageFormat::Gif | ImageFormat::Bmp
    ) {
        return Err(CoreError::invalid("源图标格式必须为 PNG/JPG/GIF/BMP"));
    }
    image::load_from_memory_with_format(&bytes, format)
        .map_err(|_| CoreError::invalid("源图标文件已损坏或无法解码"))
}

fn extract_apk_launcher(path: &Path) -> CoreResult<DynamicImage> {
    let file = File::open(path)?;
    let mut archive =
        ZipArchive::new(file).map_err(|_| CoreError::invalid("APK 不是有效的 ZIP 安装包"))?;
    let mut best: Option<(i32, u64, DynamicImage)> = None;
    let mut obfuscated_fallback: Option<(u64, DynamicImage)> = None;
    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|_| CoreError::invalid("APK 图标资源读取失败"))?;
        let name = entry.name().to_ascii_lowercase();
        if !is_apk_raster_resource(&name) {
            continue;
        }
        if entry.size() == 0 || entry.size() > MAX_ARCHIVE_ENTRY_BYTES {
            continue;
        }
        let mut bytes = Vec::with_capacity(entry.size() as usize);
        entry
            .read_to_end(&mut bytes)
            .map_err(|_| CoreError::invalid("APK 图标资源读取失败"))?;
        let format = match image::guess_format(&bytes) {
            Ok(ImageFormat::Png) => ImageFormat::Png,
            Ok(ImageFormat::WebP) => ImageFormat::WebP,
            Ok(ImageFormat::Jpeg) => ImageFormat::Jpeg,
            _ => continue,
        };
        let Ok(decoded) = image::load_from_memory_with_format(&bytes, format) else {
            continue;
        };
        let area = u64::from(decoded.width()) * u64::from(decoded.height());
        if let Some(score) = launcher_score(&name) {
            if best
                .as_ref()
                .map(|(best_score, best_area, _)| (score, area) > (*best_score, *best_area))
                .unwrap_or(true)
            {
                best = Some((score, area, decoded));
            }
        } else if is_near_square(&decoded)
            && obfuscated_fallback
                .as_ref()
                .map(|(best_area, _)| area > *best_area)
                .unwrap_or(true)
        {
            // Resource shrinking may replace the launcher filename with a short opaque
            // name (for example res/xE.jpg). A square in-APK raster is the safest
            // dependency-free fallback when no semantic launcher name survives.
            obfuscated_fallback = Some((area, decoded));
        }
    }
    best.map(|(_, _, image)| image)
        .or_else(|| obfuscated_fallback.map(|(_, image)| image))
        .ok_or_else(|| CoreError::invalid("APK 中没有可解码的 launcher PNG/WebP/JPEG 图标"))
}

fn is_apk_raster_resource(name: &str) -> bool {
    name.starts_with("res/")
        && (name.ends_with(".png")
            || name.ends_with(".webp")
            || name.ends_with(".jpg")
            || name.ends_with(".jpeg"))
}

fn is_near_square(image: &DynamicImage) -> bool {
    let shorter = image.width().min(image.height());
    let longer = image.width().max(image.height());
    shorter > 0 && u64::from(shorter) * 4 >= u64::from(longer) * 3
}

fn launcher_score(name: &str) -> Option<i32> {
    if !is_apk_raster_resource(name) {
        return None;
    }
    let mut score = if name.contains("ic_launcher") {
        1_000
    } else if name.contains("launcher") {
        850
    } else if name.contains("app_icon") {
        750
    } else if name.contains("icon") {
        400
    } else {
        return None;
    };
    if name.contains("mipmap") {
        score += 100;
    }
    score += if name.contains("xxxhdpi") {
        50
    } else if name.contains("xxhdpi") {
        40
    } else if name.contains("xhdpi") {
        30
    } else if name.contains("hdpi") {
        20
    } else {
        0
    };
    if name.contains("foreground") || name.contains("background") || name.contains("monochrome") {
        score -= 500;
    }
    Some(score)
}

fn normalize_png(image: DynamicImage) -> CoreResult<(Vec<u8>, u32, u32)> {
    if image.width() == 0 || image.height() == 0 {
        return Err(CoreError::invalid("源图标尺寸无效"));
    }
    let resized = image.thumbnail(MAX_ICON_SIDE, MAX_ICON_SIDE).to_rgba8();
    let side = resized.width().max(resized.height());
    let mut square = RgbaImage::new(side, side);
    let x = i64::from((side - resized.width()) / 2);
    let y = i64::from((side - resized.height()) / 2);
    imageops::overlay(&mut square, &resized, x, y);
    let mut encoded = Vec::new();
    PngEncoder::new_with_quality(&mut encoded, CompressionType::Best, FilterType::Adaptive)
        .write_image(
            square.as_raw(),
            square.width(),
            square.height(),
            ExtendedColorType::Rgba8,
        )
        .map_err(|_| CoreError::io("PNG 编码失败"))?;
    Ok((encoded, square.width(), square.height()))
}

fn destination_path(output_path: Option<&str>) -> CoreResult<PathBuf> {
    if let Some(path) = output_path {
        if path.trim().is_empty() || path.contains(['\0', '\r', '\n']) {
            return Err(CoreError::invalid("outputPath 无效"));
        }
        return Ok(PathBuf::from(path));
    }
    let directory = std::env::temp_dir().join("lanzouyou_icons");
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or_default();
    let count = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    Ok(directory.join(format!("prepared-{nanos}-{count}.png")))
}

fn absolute_path(path: &Path) -> CoreResult<PathBuf> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

#[cfg(test)]
mod tests {
    use std::{
        fs::File,
        io::{Read, Write},
        net::{TcpListener, TcpStream},
    };

    use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
    use zip::{write::SimpleFileOptions, ZipWriter};

    use super::{
        compose_color_icon, compose_monochrome_icon, js_escape, prepare_icon, validate_icon_upload,
    };
    use crate::session::SessionClient;

    fn png_bytes(width: u32, height: u32, color: Rgba<u8>) -> Vec<u8> {
        let image = DynamicImage::ImageRgba8(RgbaImage::from_pixel(width, height, color));
        let mut cursor = std::io::Cursor::new(Vec::new());
        image.write_to(&mut cursor, ImageFormat::Png).unwrap();
        cursor.into_inner()
    }

    fn jpeg_bytes(width: u32, height: u32, color: Rgba<u8>) -> Vec<u8> {
        let image = DynamicImage::ImageRgba8(RgbaImage::from_pixel(width, height, color));
        let mut cursor = std::io::Cursor::new(Vec::new());
        image.write_to(&mut cursor, ImageFormat::Jpeg).unwrap();
        cursor.into_inner()
    }

    fn read_request(stream: &mut TcpStream) -> String {
        let mut data = Vec::new();
        let mut buffer = [0_u8; 4096];
        let mut expected = None;
        loop {
            let read = stream.read(&mut buffer).unwrap();
            if read == 0 {
                break;
            }
            data.extend_from_slice(&buffer[..read]);
            if expected.is_none() {
                if let Some(header_end) = data.windows(4).position(|part| part == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&data[..header_end]);
                    let content_length = headers
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length:")
                                .and_then(|value| value.trim().parse::<usize>().ok())
                        })
                        .unwrap_or(0);
                    expected = Some(header_end + 4 + content_length);
                }
            }
            if expected.map(|length| data.len() >= length).unwrap_or(false) {
                break;
            }
        }
        String::from_utf8_lossy(&data).to_string()
    }

    fn respond(stream: &mut TcpStream, status: u16, body: &str) {
        write!(
            stream,
            "HTTP/1.1 {status} Mock\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
        .unwrap();
    }

    #[test]
    fn test_prepare_icon_resizes_direct_image_under_limit() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("source.png");
        std::fs::write(&source, png_bytes(512, 320, Rgba([12, 80, 220, 255]))).unwrap();
        let destination = directory.path().join("prepared.png");

        let value = prepare_icon(
            source.to_str().unwrap(),
            Some(destination.to_str().unwrap()),
        )
        .unwrap();

        assert_eq!(value["sourceKind"], "image");
        assert_eq!(value["mediaType"], "image/png");
        assert!(value["bytes"].as_u64().unwrap() < 100_000);
        assert!(value["width"].as_u64().unwrap() <= 144);
        assert!(value["height"].as_u64().unwrap() <= 144);
        validate_icon_upload(destination.to_str().unwrap()).unwrap();
    }

    #[test]
    fn test_prepare_icon_extracts_high_density_apk_launcher() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("sample.apk");
        let file = File::create(&source).unwrap();
        let mut archive = ZipWriter::new(file);
        let options = SimpleFileOptions::default();
        archive
            .start_file("res/mipmap-mdpi/ic_launcher.png", options)
            .unwrap();
        archive
            .write_all(&png_bytes(48, 48, Rgba([220, 20, 20, 255])))
            .unwrap();
        archive
            .start_file("res/mipmap-xxxhdpi/ic_launcher.png", options)
            .unwrap();
        archive
            .write_all(&png_bytes(192, 192, Rgba([20, 180, 80, 255])))
            .unwrap();
        archive.finish().unwrap();
        let destination = directory.path().join("prepared.png");

        let value = prepare_icon(
            source.to_str().unwrap(),
            Some(destination.to_str().unwrap()),
        )
        .unwrap();
        let prepared = image::open(&destination).unwrap().to_rgba8();

        assert_eq!(value["sourceKind"], "apk");
        assert_eq!(prepared.get_pixel(72, 72), &Rgba([20, 180, 80, 255]));
    }

    #[test]
    fn test_prepare_icon_extracts_obfuscated_apk_jpeg_launcher() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("sample.apk");
        let file = File::create(&source).unwrap();
        let mut archive = ZipWriter::new(file);
        let options = SimpleFileOptions::default();
        archive.start_file("res/xE.jpg", options).unwrap();
        archive
            .write_all(&jpeg_bytes(235, 235, Rgba([40, 120, 220, 255])))
            .unwrap();
        archive.finish().unwrap();
        let destination = directory.path().join("prepared.png");

        let value = prepare_icon(
            source.to_str().unwrap(),
            Some(destination.to_str().unwrap()),
        )
        .unwrap();
        let prepared = image::open(&destination).unwrap().to_rgb8();
        let center = prepared.get_pixel(72, 72).0;

        assert_eq!(value["sourceKind"], "apk");
        assert!(value["bytes"].as_u64().unwrap() < 100_000);
        assert!(center[0].abs_diff(40) <= 3);
        assert!(center[1].abs_diff(120) <= 3);
        assert!(center[2].abs_diff(220) <= 3);
    }

    #[cfg(windows)]
    #[test]
    fn test_prepare_icon_extracts_system_exe_smoke() {
        let windows = std::env::var_os("WINDIR").unwrap();
        let source = std::path::PathBuf::from(windows)
            .join("System32")
            .join("notepad.exe");
        if !source.is_file() {
            return;
        }
        let directory = tempfile::tempdir().unwrap();
        let destination = directory.path().join("prepared.png");

        let value = prepare_icon(
            source.to_str().unwrap(),
            Some(destination.to_str().unwrap()),
        )
        .unwrap();

        assert_eq!(value["sourceKind"], "exe");
        assert!(value["bytes"].as_u64().unwrap() < 100_000);
        assert!(destination.is_file());
    }

    #[test]
    fn test_validate_icon_upload_rejects_size_at_limit() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("oversize.png");
        let mut bytes = png_bytes(1, 1, Rgba([0, 0, 0, 255]));
        bytes.resize(100_000, 0);
        std::fs::write(&source, bytes).unwrap();

        let error = validate_icon_upload(source.to_str().unwrap()).unwrap_err();
        assert_eq!(error.code, "invalid_argument");
    }

    #[test]
    fn test_js_escape_matches_browser_escape_cookie_semantics() {
        assert_eq!(js_escape("AZaz09@*_+-./"), "AZaz09@*_+-./");
        assert_eq!(js_escape("a b中"), "a%20b%u4E2D");
    }

    #[test]
    fn test_compose_color_icon_preserves_alpha_and_honors_and_mask() {
        let bgra = [10, 20, 30, 128, 40, 50, 60, 255];
        let mask = [0, 0, 0, 0, 255, 255, 255, 0];
        assert_eq!(
            compose_color_icon(&bgra, &mask).unwrap(),
            vec![30, 20, 10, 128, 60, 50, 40, 0]
        );
        let zero_alpha = [10, 20, 30, 0];
        assert_eq!(
            compose_color_icon(&zero_alpha, &[0, 0, 0, 0]).unwrap(),
            vec![30, 20, 10, 255]
        );
    }

    #[test]
    fn test_compose_monochrome_icon_uses_and_xor_truth_table() {
        let and_mask = [255, 255, 255, 0, 0, 0, 0, 0];
        let xor_mask = [0, 0, 0, 0, 255, 255, 255, 0];
        assert_eq!(
            compose_monochrome_icon(&and_mask, &xor_mask).unwrap(),
            vec![0, 0, 0, 0, 255, 255, 255, 255]
        );
    }

    #[test]
    fn test_set_icon_mock_runs_bound_cookie_oss_and_readback_sequence() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let base = format!("http://{address}");
        let policy_host = format!("{base}/oss");
        let server = std::thread::spawn(move || {
            for index in 0..5 {
                let (mut stream, _) = listener.accept().unwrap();
                let request = read_request(&mut stream);
                match index {
                    0 => {
                        assert!(request.starts_with("POST /doupload.php?"));
                        assert!(request.contains("file_id=7"));
                        assert!(request.contains("task=41"));
                        assert!(request.contains("session=ok"));
                        respond(&mut stream, 200, r#"{"zt":0,"info":["token value",""]}"#);
                    }
                    1 => {
                        assert!(request.starts_with("GET /upimg/php/get.php?type=2 "));
                        assert!(request.contains("file_id_ico=token%20value"));
                        assert!(request.contains("session=ok"));
                        respond(
                            &mut stream,
                            200,
                            &format!(
                                r#"{{"host":"{policy_host}","policy":"policy","accessid":"access","signature":"signature","callback":"callback","dir":"icons/","expire":9999999999}}"#
                            ),
                        );
                    }
                    2 => {
                        assert!(request.starts_with("POST /oss "));
                        for field in [
                            "key",
                            "policy",
                            "OSSAccessKeyId",
                            "success_action_status",
                            "callback",
                            "signature",
                            "file",
                        ] {
                            assert!(request.contains(&format!("name=\"{field}\"")));
                        }
                        assert!(
                            request.find("name=\"key\"").unwrap()
                                < request.find("name=\"file\"").unwrap(),
                            "OSS form fields must precede the file part"
                        );
                        assert!(request.contains("filename=\"icon.png\""));
                        assert!(request.contains("Content-Type: image/png"));
                        assert!(!request.contains("session=ok"));
                        respond(&mut stream, 200, "");
                    }
                    3 => {
                        assert!(request.contains("task=38"));
                        assert!(request.contains("type=2"));
                        assert!(request.contains("img=icons%2F"));
                        assert!(request.contains("file_id_ico=token%20value"));
                        respond(&mut stream, 200, r#"{"zt":1,"info":["ok",""]}"#);
                    }
                    _ => {
                        assert!(request.contains("task=41"));
                        respond(
                            &mut stream,
                            200,
                            r#"{"zt":1,"info":["token value","https://image.dmpdmp.com/icon.png?e=1&s=secret"]}"#,
                        );
                    }
                }
            }
        });
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("icon.png");
        std::fs::write(&source, png_bytes(64, 64, Rgba([20, 100, 220, 255]))).unwrap();
        let mut session = SessionClient::for_test(base).unwrap();
        session.cookie = "session=ok".to_owned();
        session.uid = "123".to_owned();
        session.vei = "456".to_owned();

        let value = session.set_icon("7", source.to_str().unwrap()).unwrap();

        assert_eq!(value["fileId"], "7");
        assert_eq!(value.as_object().unwrap().len(), 1);
        server.join().unwrap();
    }
}
