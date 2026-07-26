mod acw;
mod compat;
mod directory_upload;
mod dispatch;
mod error;
mod ffi;
mod http_client;
mod icon;
mod library;
mod model;
mod operation;
mod parser;
mod replace;
mod session;
mod transfer;
mod validation;

pub use dispatch::dispatch_json;
pub use ffi::{lanzouyou_dispatch, lanzouyou_free};

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
