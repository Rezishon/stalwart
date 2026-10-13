use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn main() {
    let manifest = env::var("CARGO_MANIFEST_DIR").unwrap();
    let assets = Path::new(&manifest).join("assets");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    println!("cargo:rerun-if-changed={}", assets.display());

    let mut files: Vec<(String, PathBuf)> = Vec::new();
    walk(&assets, &assets, &mut files);
    files.sort_unstable_by(|a, b| a.0.cmp(&b.0));

    let mut code = String::from(
        "pub fn lookup(path: &str) -> Option<(&'static [u8], &'static str)> {\n    match path {\n",
    );
    for (name, disk) in &files {
        let ct = content_type(name);
        code.push_str(&format!(
            "        {name:?} => Some((include_bytes!({disk:?}), {ct:?})),\n"
        ));
    }
    code.push_str("        _ => None,\n    }\n}\n");
    fs::write(out.join("relay_embed.rs"), code).expect("write relay_embed.rs");
}

fn walk(root: &Path, dir: &Path, out: &mut Vec<(String, PathBuf)>) {
    for entry in fs::read_dir(dir).unwrap_or_else(|err| panic!("read {dir:?}: {err}")) {
        let entry = entry.expect("dirent");
        let path = entry.path();
        let name = entry.file_name();
        if name == "RELAY_REV" {
            continue;
        }
        if path.is_dir() {
            walk(root, &path, out);
            continue;
        }
        let rel = path
            .strip_prefix(root)
            .expect("asset under root")
            .to_string_lossy()
            .replace('\\', "/");
        out.push((rel, path));
    }
}

fn content_type(name: &str) -> &'static str {
    match name.rsplit_once('.').map(|(_, ext)| ext).unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" => "application/javascript; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "ico" => "image/x-icon",
        "json" => "application/json",
        "woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
}
