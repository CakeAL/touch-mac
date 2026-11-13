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
    // 音频：Sunshine 发 Opus，直接在桥里用 libopus 解成 PCM，省掉安卓侧 MediaCodec。
    let opus_dir = "/opt/homebrew/lib";
    println!("cargo:rustc-link-search=native={opus_dir}");
    println!("cargo:rustc-link-lib=static=opus");
    println!("cargo:rerun-if-changed=build.rs");
}
