use std::{
    ffi::{CStr, CString},
    os::raw::c_char,
    panic::{catch_unwind, AssertUnwindSafe},
};

use crate::{
    dispatch::dispatch_json,
    error::{CoreError, Envelope},
};

#[no_mangle]
/// Dispatches one UTF-8 JSON command and returns an owned UTF-8 JSON response.
///
/// # Safety
///
/// `request` must be null or point to a valid NUL-terminated byte string for the
/// duration of this call. The returned pointer must be released exactly once by
/// [`lanzouyou_free`].
pub unsafe extern "C" fn lanzouyou_dispatch(request: *const c_char) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if request.is_null() {
            return failure_json(CoreError::new("invalid_request", "请求指针为空", false));
        }
        let request = unsafe { CStr::from_ptr(request) };
        match request.to_str() {
            Ok(text) => dispatch_json(text),
            Err(_) => failure_json(CoreError::new("invalid_request", "请求不是 UTF-8", false)),
        }
    }))
    .unwrap_or_else(|_| {
        failure_json(CoreError::new(
            "internal_error",
            "Rust 核心发生未处理异常",
            false,
        ))
    });
    CString::new(result)
        .expect("JSON response must not contain interior NUL bytes")
        .into_raw()
}

#[no_mangle]
/// Releases a response allocated by [`lanzouyou_dispatch`].
///
/// # Safety
///
/// `pointer` must be null or a pointer returned by `lanzouyou_dispatch` that has
/// not already been released.
pub unsafe extern "C" fn lanzouyou_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(CString::from_raw(pointer));
    }
}

fn failure_json(error: CoreError) -> String {
    serde_json::to_string(&Envelope::failure(error))
        .expect("failure envelope serialization must succeed")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call_ffi(request: &str) -> serde_json::Value {
        let request = CString::new(request).unwrap();
        let pointer = unsafe { lanzouyou_dispatch(request.as_ptr()) };
        assert!(!pointer.is_null());
        let text = unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .unwrap()
            .to_owned();
        unsafe { lanzouyou_free(pointer) };
        serde_json::from_str(&text).unwrap()
    }

    #[test]
    fn test_ffi_null_pointer_returns_owned_error_string() {
        let pointer = unsafe { lanzouyou_dispatch(std::ptr::null()) };
        assert!(!pointer.is_null());
        let text = unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .unwrap()
            .to_owned();
        unsafe { lanzouyou_free(pointer) };
        assert!(text.contains("invalid_request"));
    }

    #[test]
    fn test_ffi_can_query_and_cancel_an_operation_from_another_thread() {
        let operation = crate::operation::begin(
            Some("ffi-concurrent-cancel-test"),
            crate::operation::OperationKind::Download,
        )
        .unwrap()
        .unwrap();
        let worker_operation = operation.clone();
        let worker = std::thread::spawn(move || -> crate::error::CoreResult<()> {
            loop {
                if let Err(error) = worker_operation.check_cancelled() {
                    let result = Err(error);
                    worker_operation.finish_result(&result);
                    return result;
                }
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
        });

        let status =
            call_ffi(r#"{"op":"operation_status","operationId":"ffi-concurrent-cancel-test"}"#);
        assert_eq!(status["data"]["state"], "running");
        let cancelling =
            call_ffi(r#"{"op":"operation_cancel","operationId":"ffi-concurrent-cancel-test"}"#);
        assert_eq!(cancelling["data"]["state"], "cancelling");
        assert_eq!(worker.join().unwrap().unwrap_err().code, "cancelled");
        let cancelled =
            call_ffi(r#"{"op":"operation_status","operationId":"ffi-concurrent-cancel-test"}"#);
        assert_eq!(cancelled["data"]["state"], "cancelled");
        assert_eq!(
            call_ffi(r#"{"op":"operation_forget","operationId":"ffi-concurrent-cancel-test"}"#,)
                ["data"]["forgotten"],
            true
        );
    }
}
