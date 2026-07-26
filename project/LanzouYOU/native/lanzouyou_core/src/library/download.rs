use std::{
    fs::{self},
    path::{Path, PathBuf},
    sync::Arc,
};

use crate::{
    error::{CoreError, CoreResult},
    operation::OperationHandle,
    validation,
};

use super::{
    direct_link::{self, DirectLinkLease, ResolvePriority, ResolvedDirectLink},
    model::LibraryDownloadResult,
    resolve,
    transfer::{RangeRequest, TransferMetadata, TransferPaths},
    url::{normalize_public_share_url, SecurityPolicy},
};

pub(crate) fn download(
    source_id: &str,
    share_url: &str,
    password: &str,
    destination_directory: &str,
    policy: SecurityPolicy,
    exchange_delays: resolve::DirectExchangeDelays,
    operation: Option<&OperationHandle>,
) -> CoreResult<LibraryDownloadResult> {
    if let Some(operation) = operation {
        operation.check_cancelled()?;
        operation.set_total_units(1);
    }
    let directory = validate_destination_directory(destination_directory)?;
    let canonical_share_url = normalize_public_share_url(share_url, &policy)?;
    let mut lease = resolve_cached(
        source_id,
        &canonical_share_url,
        password,
        &policy,
        exchange_delays,
        operation,
    )?;
    validation::safe_filename(lease.file_name())?;
    let file_name = lease.file_name().to_owned();
    let final_path = directory.join(&file_name);
    if final_path.exists() {
        return Err(already_exists());
    }
    let paths =
        TransferPaths::for_identity(&directory, source_id, &canonical_share_url, &file_name)?;
    let mut part_file = paths.open_part()?;
    let mut metadata = paths.load_or_new(&file_name, 0, 0)?;
    if paths.repair_part(&mut part_file, &mut metadata)? || !paths.metadata.exists() {
        paths.write_metadata_atomic(&metadata)?;
    }

    let mut refreshed_direct = false;
    let mut completed = false;
    for _ in 0..128 {
        if let Some(operation) = operation {
            if let Err(error) = operation.check_cancelled() {
                drop(part_file);
                cleanup_cancelled_transfer(&paths)?;
                return Err(error);
            }
        }
        let range = RangeRequest {
            offset: metadata.committed_bytes,
            validator: metadata.validator(),
        };
        let transport = lease
            .transport()
            .ok_or_else(|| CoreError::new("internal_error", "直链缓存缺少下载会话", false))?;
        let transfer = transport.download_guarded_range_to(
            lease.direct_url(),
            &canonical_share_url,
            &mut part_file,
            &range,
            operation,
            None,
        );
        match transfer {
            Ok(result) => {
                metadata.committed_bytes = result.committed_bytes;
                metadata.set_validator(&result.validator);
                paths.write_metadata_atomic(&metadata)?;
                if result
                    .total_bytes
                    .is_none_or(|total| result.committed_bytes == total)
                {
                    completed = true;
                    break;
                }
                if result.response_bytes == 0 {
                    return Err(CoreError::new(
                        "range_invalid",
                        "Range 下载未取得进展",
                        true,
                    ));
                }
            }
            Err(error) => {
                part_file.sync_all()?;
                metadata.committed_bytes = part_file.metadata()?.len();
                paths.write_metadata_atomic(&metadata)?;
                if error.code == "cancelled" {
                    drop(part_file);
                    cleanup_cancelled_transfer(&paths)?;
                    return Err(error);
                }
                let invalidates_direct = matches!(
                    error.code,
                    "direct_link_stale" | "entity_changed" | "unexpected_payload"
                );
                if invalidates_direct && !refreshed_direct {
                    direct_link::process_cache().invalidate(&lease);
                    refreshed_direct = true;
                    if error.code == "entity_changed" {
                        part_file.set_len(0)?;
                        metadata = TransferMetadata::new(file_name.clone(), 0, 0);
                        paths.write_metadata_atomic(&metadata)?;
                    }
                    lease = match resolve_cached(
                        source_id,
                        &canonical_share_url,
                        password,
                        &policy,
                        exchange_delays,
                        operation,
                    ) {
                        Ok(lease) => lease,
                        Err(error) if error.code == "cancelled" => {
                            drop(part_file);
                            cleanup_cancelled_transfer(&paths)?;
                            return Err(error);
                        }
                        Err(error) => return Err(error),
                    };
                    if lease.file_name() != file_name {
                        return Err(CoreError::new(
                            "entity_changed",
                            "刷新直链后文件名发生变化，请重新开始下载",
                            true,
                        ));
                    }
                    continue;
                }
                return Err(error);
            }
        }
    }
    if !completed {
        return Err(CoreError::new(
            "range_invalid",
            "Range 分段次数超过安全上限",
            true,
        ));
    }

    if let Some(operation) = operation {
        if let Err(error) = operation.check_cancelled() {
            drop(part_file);
            cleanup_cancelled_transfer(&paths)?;
            return Err(error);
        }
    }
    part_file.sync_all()?;
    paths.verify_part_before_publish()?;
    drop(part_file);
    publish_no_clobber(&paths.part, &final_path)?;
    paths.remove_metadata()?;
    if let Some(operation) = operation {
        operation.complete_unit(0);
    }
    let path = final_path
        .to_str()
        .ok_or_else(|| CoreError::invalid("下载目录必须是有效的 UTF-8 路径"))?
        .to_owned();
    Ok(LibraryDownloadResult {
        path,
        file_name,
        bytes_written: metadata.committed_bytes,
    })
}

fn cleanup_cancelled_transfer(paths: &TransferPaths) -> CoreResult<()> {
    let part_result = match fs::remove_file(&paths.part) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(CoreError::io(error)),
    };
    let metadata_result = paths.remove_metadata();
    part_result?;
    metadata_result
}

fn resolve_cached(
    source_id: &str,
    canonical_share_url: &str,
    password: &str,
    policy: &SecurityPolicy,
    exchange_delays: resolve::DirectExchangeDelays,
    operation: Option<&OperationHandle>,
) -> CoreResult<DirectLinkLease> {
    direct_link::process_cache().resolve(
        canonical_share_url,
        password,
        policy,
        ResolvePriority::Confirmed,
        |share_url, _context| {
            let (transport, resolved) = resolve::resolve_with_transport(
                source_id,
                share_url,
                password,
                policy.clone(),
                exchange_delays,
                operation,
            )?;
            ResolvedDirectLink::with_transport(
                resolved.url,
                resolved.file_name,
                Arc::new(transport),
            )
        },
    )
}

fn validate_destination_directory(value: &str) -> CoreResult<PathBuf> {
    if value.trim().is_empty() || value.chars().any(char::is_control) {
        return Err(CoreError::invalid("destinationDirectory 格式无效"));
    }
    let directory = PathBuf::from(value);
    if !directory.is_absolute() {
        return Err(CoreError::invalid("destinationDirectory 必须是绝对路径"));
    }
    if directory.exists() && !directory.is_dir() {
        return Err(CoreError::invalid("destinationDirectory 不是目录"));
    }
    fs::create_dir_all(&directory)?;
    Ok(directory)
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn publish_no_clobber(part_path: &Path, final_path: &Path) -> CoreResult<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};

    let source = CString::new(part_path.as_os_str().as_bytes())
        .map_err(|_| CoreError::invalid("下载临时路径格式无效"))?;
    let destination = CString::new(final_path.as_os_str().as_bytes())
        .map_err(|_| CoreError::invalid("下载目标路径格式无效"))?;
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            destination.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        let error = std::io::Error::last_os_error();
        if matches!(
            error.raw_os_error(),
            Some(libc::ENOSYS) | Some(libc::EINVAL) | Some(libc::EOPNOTSUPP)
        ) {
            publish_via_hard_link_no_clobber(part_path, final_path)
        } else {
            Err(map_publish_error(final_path, error))
        }
    }
}

#[cfg(target_os = "windows")]
fn publish_no_clobber(part_path: &Path, final_path: &Path) -> CoreResult<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::MoveFileW;

    let source = part_path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let destination = final_path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let result = unsafe { MoveFileW(source.as_ptr(), destination.as_ptr()) };
    if result != 0 {
        Ok(())
    } else {
        let error = std::io::Error::last_os_error();
        if final_path.exists() {
            Err(already_exists())
        } else {
            Err(CoreError::io(error))
        }
    }
}

#[cfg(not(any(target_os = "android", target_os = "linux", target_os = "windows")))]
fn publish_no_clobber(part_path: &Path, final_path: &Path) -> CoreResult<()> {
    publish_via_hard_link_no_clobber(part_path, final_path)
}

#[cfg(any(not(target_os = "windows"), test))]
fn publish_via_hard_link_no_clobber(part_path: &Path, final_path: &Path) -> CoreResult<()> {
    fs::hard_link(part_path, final_path).map_err(|error| {
        if final_path.exists() {
            already_exists()
        } else if error.kind() == std::io::ErrorKind::Unsupported
            || error.kind() == std::io::ErrorKind::PermissionDenied
            || matches!(
                error.raw_os_error(),
                Some(libc::ENOSYS)
                    | Some(libc::EINVAL)
                    | Some(libc::EOPNOTSUPP)
                    | Some(libc::EPERM)
            )
        {
            CoreError::new(
                "atomic_publish_unsupported",
                "下载目录不支持安全原子落盘，请更换保存目录",
                false,
            )
        } else {
            CoreError::io(error)
        }
    })?;
    if let Err(error) = fs::remove_file(part_path) {
        let _ = fs::remove_file(final_path);
        return Err(CoreError::io(error));
    }
    Ok(())
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn map_publish_error(final_path: &Path, error: std::io::Error) -> CoreError {
    if error.kind() == std::io::ErrorKind::AlreadyExists || final_path.exists() {
        already_exists()
    } else {
        CoreError::io(error)
    }
}

fn already_exists() -> CoreError {
    CoreError::new("already_exists", "目标文件已存在", false)
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::{mpsc, Arc},
        thread,
        time::{Duration, Instant},
    };

    use super::*;

    #[test]
    fn test_destination_directory_must_be_absolute_and_directory_shaped() {
        assert!(validate_destination_directory("relative/downloads").is_err());
        assert!(validate_destination_directory("").is_err());

        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("not-a-directory");
        fs::write(&file, b"data").unwrap();
        assert!(validate_destination_directory(file.to_str().unwrap()).is_err());
    }

    #[test]
    fn test_publish_no_clobber_never_overwrites_existing_file() {
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join(".payload.part");
        let destination = directory.path().join("payload.apk");
        fs::write(&part, b"new").unwrap();
        fs::write(&destination, b"existing").unwrap();

        let error = publish_no_clobber(&part, &destination).unwrap_err();

        assert_eq!(error.code, "already_exists");
        assert_eq!(fs::read(destination).unwrap(), b"existing");
        assert_eq!(fs::read(part).unwrap(), b"new");
    }

    #[test]
    fn test_hard_link_fallback_is_atomic_no_clobber_and_removes_part() {
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join(".payload.part");
        let destination = directory.path().join("payload.apk");
        fs::write(&part, b"complete payload").unwrap();

        publish_via_hard_link_no_clobber(&part, &destination).unwrap();

        assert!(!part.exists());
        assert_eq!(fs::read(destination).unwrap(), b"complete payload");
    }

    #[test]
    fn test_hard_link_fallback_reports_already_exists_without_overwrite() {
        let directory = tempfile::tempdir().unwrap();
        let part = directory.path().join(".payload.part");
        let destination = directory.path().join("payload.apk");
        fs::write(&part, b"new").unwrap();
        fs::write(&destination, b"existing").unwrap();

        let error = publish_via_hard_link_no_clobber(&part, &destination).unwrap_err();

        assert_eq!(error.code, "already_exists");
        assert_eq!(fs::read(destination).unwrap(), b"existing");
        assert_eq!(fs::read(part).unwrap(), b"new");
    }

    #[test]
    fn test_download_cancellation_interrupts_stalled_resolution_before_part_creation() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let (accepted_tx, accepted_rx) = mpsc::sync_channel(1);
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            accepted_tx.send(()).unwrap();
            thread::sleep(Duration::from_millis(700));
        });
        let directory = tempfile::tempdir().unwrap();
        let destination = directory.path().to_string_lossy().into_owned();
        let operation_id = "library-download-resolve-cancel-test";
        let operation = crate::operation::begin(
            Some(operation_id),
            crate::operation::OperationKind::Download,
        )
        .unwrap()
        .unwrap();
        let worker_operation = operation.clone();
        let worker_origin = origin.clone();
        let worker = thread::spawn(move || {
            download(
                "source-one",
                &format!("{worker_origin}/share"),
                "",
                &destination,
                SecurityPolicy::Test {
                    origin: worker_origin,
                },
                resolve::DirectExchangeDelays::ZERO,
                Some(&worker_operation),
            )
        });
        accepted_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let started = Instant::now();
        crate::operation::cancel(operation_id).unwrap();

        let error = worker.join().unwrap().unwrap_err();
        assert_eq!(error.code, "cancelled");
        assert!(started.elapsed() < Duration::from_millis(500));
        assert_eq!(directory.path().read_dir().unwrap().count(), 0);
        operation.finish_cancelled();
        crate::operation::forget(operation_id).unwrap();
        server.join().unwrap();
    }

    #[test]
    fn test_download_cancellation_after_part_creation_removes_part_and_metadata() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let (body_started_tx, body_started_rx) = mpsc::sync_channel(1);
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 4096];
            let count = stream.read(&mut request).unwrap();
            assert!(String::from_utf8_lossy(&request[..count]).starts_with("GET /cancel.apk "));
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 1024\r\nConnection: close\r\n\r\n",
                )
                .unwrap();
            stream.write_all(&vec![b'x'; 600]).unwrap();
            stream.flush().unwrap();
            body_started_tx.send(()).unwrap();
            thread::sleep(Duration::from_millis(700));
        });
        let policy = SecurityPolicy::Test {
            origin: origin.clone(),
        };
        let share_url = format!("{origin}/cancel-share");
        let transport =
            Arc::new(super::super::session::LibraryTransport::for_test(origin.clone()).unwrap());
        direct_link::process_cache()
            .resolve(
                &share_url,
                "",
                &policy,
                ResolvePriority::Confirmed,
                |_, _| {
                    ResolvedDirectLink::with_transport(
                        format!("{origin}/cancel.apk"),
                        "cancel.apk".to_owned(),
                        transport,
                    )
                },
            )
            .unwrap();
        let directory = tempfile::tempdir().unwrap();
        let destination = directory.path().to_string_lossy().into_owned();
        let operation_id = "library-download-body-cancel-test";
        let operation = crate::operation::begin(
            Some(operation_id),
            crate::operation::OperationKind::Download,
        )
        .unwrap()
        .unwrap();
        let worker_operation = operation.clone();
        let worker = thread::spawn(move || {
            download(
                "cancel-source",
                &share_url,
                "",
                &destination,
                policy,
                resolve::DirectExchangeDelays::ZERO,
                Some(&worker_operation),
            )
        });
        body_started_rx
            .recv_timeout(Duration::from_secs(1))
            .unwrap();
        assert!(directory.path().read_dir().unwrap().count() >= 2);
        let started = Instant::now();
        crate::operation::cancel(operation_id).unwrap();

        let error = worker.join().unwrap().unwrap_err();
        assert_eq!(error.code, "cancelled");
        assert!(started.elapsed() < Duration::from_millis(500));
        assert_eq!(directory.path().read_dir().unwrap().count(), 0);
        operation.finish_cancelled();
        crate::operation::forget(operation_id).unwrap();
        server.join().unwrap();
    }

    #[test]
    fn test_download_resumes_deterministic_part_with_range_and_cleans_metadata() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 4096];
            let count = stream.read(&mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..count]).to_ascii_lowercase();
            assert!(request.starts_with("get /file/resume.apk "));
            assert!(request.contains("range: bytes=4-"));
            assert!(request.contains("if-range: \"v1\""));
            stream
                .write_all(
                    b"HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 4-9/10\r\nContent-Length: 6\r\nETag: \"v1\"\r\nConnection: close\r\n\r\nefghij",
                )
                .unwrap();
        });
        let policy = SecurityPolicy::Test {
            origin: origin.clone(),
        };
        let share_url = format!("{origin}/share");
        let transport =
            Arc::new(super::super::session::LibraryTransport::for_test(origin.clone()).unwrap());
        direct_link::process_cache()
            .resolve(
                &share_url,
                "",
                &policy,
                ResolvePriority::Confirmed,
                |_, _| {
                    ResolvedDirectLink::with_transport(
                        format!("{origin}/file/resume.apk"),
                        "resume.apk".to_owned(),
                        transport,
                    )
                },
            )
            .unwrap();
        let directory = tempfile::tempdir().unwrap();
        let canonical = normalize_public_share_url(&share_url, &policy).unwrap();
        let paths = TransferPaths::for_identity(
            directory.path(),
            "resume-source",
            &canonical,
            "resume.apk",
        )
        .unwrap();
        let mut part = paths.open_part().unwrap();
        part.write_all(b"abcd").unwrap();
        part.sync_all().unwrap();
        drop(part);
        let mut metadata = TransferMetadata::new("resume.apk".to_owned(), 0, 0);
        metadata.committed_bytes = 4;
        metadata.total_bytes = Some(10);
        metadata.etag = Some("\"v1\"".to_owned());
        paths.write_metadata_atomic(&metadata).unwrap();

        let result = download(
            "resume-source",
            &share_url,
            "",
            directory.path().to_str().unwrap(),
            policy,
            resolve::DirectExchangeDelays::ZERO,
            None,
        )
        .unwrap();

        assert_eq!(result.bytes_written, 10);
        assert_eq!(
            fs::read(directory.path().join("resume.apk")).unwrap(),
            b"abcdefghij"
        );
        assert!(!paths.part.exists());
        assert!(!paths.metadata.exists());
        server.join().unwrap();
    }

    #[test]
    fn test_download_invalidates_stale_cached_direct_link_and_resolves_once_fresh() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server_origin = origin.clone();
        let server = thread::spawn(move || {
            for index in 0..4 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0_u8; 4096];
                let count = stream.read(&mut request).unwrap();
                let request_text = String::from_utf8_lossy(&request[..count]);
                let body = match index {
                    0 => {
                        assert!(request_text.starts_with("GET /stale "));
                        stream
                            .write_all(
                                b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                            )
                            .unwrap();
                        continue;
                    }
                    1 => {
                        assert!(request_text.starts_with("GET /share "));
                        r#"<title>fresh.apk - 蓝奏云</title><script>var ajaxdata='sig';</script>"#
                            .to_owned()
                    }
                    2 => {
                        assert!(request_text.starts_with("POST /ajaxm.php "));
                        format!(r#"{{"zt":1,"url":"{server_origin}/file/fresh.apk"}}"#)
                    }
                    _ => {
                        assert!(request_text.starts_with("GET /file/fresh.apk "));
                        "payload".to_owned()
                    }
                };
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        let policy = SecurityPolicy::Test {
            origin: origin.clone(),
        };
        let share_url = format!("{origin}/share");
        let transport =
            Arc::new(super::super::session::LibraryTransport::for_test(origin.clone()).unwrap());
        direct_link::process_cache()
            .resolve(
                &share_url,
                "",
                &policy,
                ResolvePriority::Confirmed,
                |_, _| {
                    ResolvedDirectLink::with_transport(
                        format!("{origin}/stale"),
                        "fresh.apk".to_owned(),
                        transport,
                    )
                },
            )
            .unwrap();
        let directory = tempfile::tempdir().unwrap();

        let result = download(
            "stale-source",
            &share_url,
            "",
            directory.path().to_str().unwrap(),
            policy,
            resolve::DirectExchangeDelays::ZERO,
            None,
        )
        .unwrap();

        assert_eq!(result.bytes_written, 7);
        assert_eq!(
            fs::read(directory.path().join("fresh.apk")).unwrap(),
            b"payload"
        );
        assert_eq!(directory.path().read_dir().unwrap().count(), 1);
        server.join().unwrap();
    }
}
