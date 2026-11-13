fn main() {
    let files = [
        "callbacks.c", "compress.c", "host.c", "list.c", "packet.c",
        "peer.c", "protocol.c", "unix.c",
    ];
    let mut b = cc::Build::new();
    b.include("vendor/enet/include").warnings(false);
    b.define("HAS_GETADDRINFO", None);
    for f in files {
        b.file(format!("vendor/enet/{f}"));
    }
    b.file("vendor/enet_shim.c");
    b.compile("enet_shim");
    println!("cargo:rerun-if-changed=vendor/enet");
    println!("cargo:rerun-if-changed=vendor/enet_shim.c");
    println!("cargo:rerun-if-changed=build.rs");
}
