// This crate exists to develop and test `pairing.rs` on its own. For iOS,
// `build-rust.sh` compiles `pairing.rs` (and `device.rs` and `appleid.rs`,
// which need idevice-ffi's handles and crates) as modules of idevice-ffi
// instead, so one idevice serves the install path, pairing and isideload.
// Keep `pairing.rs` free of anything idevice-ffi doesn't also depend on.
mod pairing;
pub use pairing::*;

#[cfg(test)]
mod tests;
