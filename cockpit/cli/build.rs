//! Bakes the build flavor (debug/release) into the binary.
//!
//! Sockets are namespaced by flavor (`status.sock` vs `status-debug.sock`)
//! to allow dev and installed builds to run side-by-side.

fn main() {
    println!("cargo:rerun-if-env-changed=COCKPIT_FLAVOR");
}
