use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::io;
use std::path::Path;

fn main() {
    let out_dir = env::var("OUT_DIR").unwrap();
    let dest_path = Path::new(&out_dir).join("locales.rs");

    // Read the YAML file
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let repo_root = Path::new(&manifest_dir).parent().unwrap().parent().unwrap();
    let yaml_path = repo_root.join("resources/locales/i18n.yml");
    let yaml_content =
        fs::read_to_string(&yaml_path).unwrap_or_else(|_| panic!("Failed to read {yaml_path:?}"));

    let locales = parse_yaml(&yaml_content);

    let generated_code = generate_locale_code(&locales);

    fs::write(&dest_path, generated_code).expect("Failed to write generated locales.");

    println!("cargo:rerun-if-changed={}", yaml_path.display());

    let rl_path = repo_root.join("resources/RL_VERSION");
    let suffix = fs::read_to_string(&rl_path)
        .unwrap_or_else(|_| panic!("Failed to read {rl_path:?}"))
        .trim()
        .to_string();
    let pkg = env::var("CARGO_PKG_VERSION").expect("CARGO_PKG_VERSION");
    println!("cargo:rustc-env=MAILIAM_VERSION={pkg}-{suffix}");
    println!("cargo:rustc-env=STALWART_VERSION={pkg}-{suffix}");
    println!("cargo:rerun-if-changed={}", rl_path.display());

    embed_webui(repo_root, Path::new(&out_dir));
}

fn embed_webui(repo_root: &Path, out_dir: &Path) {
    let zip_path = repo_root.join("resources/webui.zip");
    println!("cargo:rerun-if-changed={}", zip_path.display());

    let file = fs::File::open(&zip_path).unwrap_or_else(|err| panic!("open {zip_path:?}: {err}"));
    let mut archive =
        zip::ZipArchive::new(file).unwrap_or_else(|err| panic!("webui.zip: {err}"));

    let dest = out_dir.join("webui");
    let _ = fs::remove_dir_all(&dest);
    fs::create_dir_all(&dest).expect("mkdir webui embed");

    let mut files: Vec<(String, String)> = Vec::new();
    for i in 0..archive.len() {
        let mut file = archive.by_index(i).expect("zip entry");
        if file.is_dir() {
            continue;
        }
        let name = file.name().replace('\\', "/");
        if name.split('/').any(|s| s == "..") {
            panic!("unsafe zip path {name}");
        }
        let name = name.trim_start_matches('/');
        if name.is_empty() {
            continue;
        }

        let disk = dest.join(name);
        if let Some(parent) = disk.parent() {
            fs::create_dir_all(parent).expect("mkdir embed parent");
        }
        let mut out = fs::File::create(&disk).unwrap_or_else(|err| panic!("write {disk:?}: {err}"));
        io::copy(&mut file, &mut out).expect("copy zip entry");
        files.push((name.to_string(), disk.display().to_string()));
    }
    files.sort_unstable();

    let mut code = String::from(
        "pub fn lookup(path: &str) -> Option<(&'static [u8], &'static str)> {\n    match path {\n",
    );
    for (name, disk) in &files {
        let ct = webui_content_type(name);
        code.push_str(&format!(
            "        {name:?} => Some((include_bytes!({disk:?}), {ct:?})),\n"
        ));
    }
    code.push_str("        _ => None,\n    }\n}\n");
    fs::write(out_dir.join("webui_embed.rs"), code).expect("write webui_embed.rs");
}

fn webui_content_type(name: &str) -> &'static str {
    match name.rsplit_once('.').map(|(_, ext)| ext).unwrap_or("") {
        "html" => "text/html",
        "css" => "text/css",
        "wasm" => "application/wasm",
        "js" => "application/javascript",
        "json" => "application/json",
        "png" => "image/png",
        "svg" => "image/svg+xml",
        "ico" => "image/x-icon",
        _ => "application/octet-stream",
    }
}

fn parse_yaml(content: &str) -> HashMap<String, HashMap<String, String>> {
    let mut result: HashMap<String, HashMap<String, String>> = HashMap::new();
    let mut current_key = None;

    for line in content.lines() {
        if let Some((key, value)) = line.split_once(':') {
            let is_translation = key
                .as_bytes()
                .first()
                .is_some_and(|&b| b.is_ascii_whitespace());
            let key = key.trim();
            if !key.starts_with('#') && !key.is_empty() {
                if !is_translation {
                    current_key = result.entry(key.replace('.', "_")).or_default().into();
                } else {
                    current_key
                        .as_mut()
                        .unwrap()
                        .insert(key.to_string(), value.trim().trim_matches('"').to_string());
                }
            }
        }
    }

    result
}

fn const_name(language: &str) -> String {
    language.to_uppercase().replace('-', "_")
}

const PLURAL_CATEGORIES: [&str; 6] = ["zero", "one", "two", "few", "many", "other"];

const RTL_LANGUAGES: [&str; 10] = ["ar", "ckb", "dv", "fa", "he", "ps", "sd", "ug", "ur", "yi"];

fn direction(language: &str) -> &'static str {
    let tag = language.split(['-', '_']).next().unwrap_or(language);
    if RTL_LANGUAGES.contains(&tag) {
        "rtl"
    } else {
        "ltr"
    }
}

fn split_plural_forms(value: &str) -> Option<Vec<(&str, &str)>> {
    value
        .split(';')
        .map(|segment| {
            segment
                .split_once('=')
                .filter(|(name, _)| PLURAL_CATEGORIES.contains(name))
        })
        .collect()
}

fn plural_keys(locales: &HashMap<String, HashMap<String, String>>) -> HashSet<String> {
    let mut keys = HashSet::new();

    for (key, translations) in locales {
        if !translations
            .values()
            .any(|value| split_plural_forms(value).is_some())
        {
            continue;
        }

        for (language, value) in translations {
            let Some(forms) = split_plural_forms(value) else {
                panic!(
                    "{key}: {language} has no plural categories while other languages do: {value:?}"
                );
            };
            let mut seen = HashSet::new();
            for (name, _) in &forms {
                if !seen.insert(*name) {
                    panic!("{key}: {language} repeats the plural category {name:?}");
                }
            }
            if !seen.contains("other") {
                panic!("{key}: {language} is missing the required \"other\" plural category");
            }
        }

        keys.insert(key.clone());
    }

    keys
}

fn plural_forms_literal(value: &str) -> String {
    let forms = split_plural_forms(value).expect("validated above");
    let other = forms
        .iter()
        .find(|(name, _)| *name == "other")
        .map(|(_, text)| *text)
        .expect("validated above");

    let mut literal = String::from("PluralForms {");
    for category in PLURAL_CATEGORIES {
        let text = forms
            .iter()
            .find(|(name, _)| *name == category)
            .map_or(other, |(_, text)| *text);
        literal.push_str(&format!(" {category}: {text:?},"));
    }
    literal.push_str(" }");
    literal
}

fn generate_locale_code(locales: &HashMap<String, HashMap<String, String>>) -> String {
    let mut code = String::new();
    let plural = plural_keys(locales);

    code.push_str("#[derive(Debug, Clone, Copy)]\n");
    code.push_str("pub struct PluralForms {\n");
    for category in PLURAL_CATEGORIES {
        code.push_str(&format!("    pub {category}: &'static str,\n"));
    }
    code.push_str("}\n\n");

    code.push_str("#[derive(Debug, Clone)]\n");
    code.push_str("pub struct Locale {\n");
    code.push_str("    pub name: &'static str,\n");
    code.push_str("    pub direction: &'static str,\n");

    for key in locales.keys() {
        let field_type = if plural.contains(key) {
            "PluralForms"
        } else {
            "&'static str"
        };
        code.push_str(&format!("    pub {key}: {field_type},\n"));
    }

    code.push_str("}\n\n");

    let mut languages = std::collections::HashSet::new();
    for translations in locales.values() {
        for lang in translations.keys() {
            languages.insert(lang.clone());
        }
    }

    for lang in &languages {
        code.push_str(&format!(
            "pub static {}_LOCALES: Locale = Locale {{\n",
            const_name(lang)
        ));
        code.push_str(&format!("    name: {lang:?},\n"));
        code.push_str(&format!("    direction: {:?},\n", direction(lang)));

        for (key, translations) in locales {
            let value = translations
                .get(lang)
                .unwrap_or_else(|| panic!("Missing: {}", key));
            if plural.contains(key) {
                code.push_str(&format!("    {key}: {},\n", plural_forms_literal(value)));
            } else {
                code.push_str(&format!("    {key}: {value:?},\n"));
            }
        }

        code.push_str("};\n\n");
    }

    let mut sorted: Vec<&String> = languages.iter().collect();
    sorted.sort_unstable();
    code.push_str(&format!(
        "pub static ALL_LOCALES: [&Locale; {}] = [\n",
        sorted.len()
    ));
    for lang in &sorted {
        code.push_str(&format!("    &{}_LOCALES,\n", const_name(lang)));
    }
    code.push_str("];\n\n");

    code.push_str("pub fn locale(name: &str) -> Option<&'static Locale> {\n");
    code.push_str("    hashify::tiny_map_ignore_case!(name.as_bytes(),\n");
    for lang in &languages {
        code.push_str(&format!(
            "        \"{}\" => &{}_LOCALES,\n",
            lang,
            const_name(lang)
        ));
    }
    code.push_str("    )\n");
    code.push_str("}\n\n");

    // Maps a bare language tag onto the regional locale shipped for it
    let mut by_language: Vec<(&str, &str)> = languages
        .iter()
        .map(|lang| (lang.split('-').next().unwrap_or(lang), lang.as_str()))
        .collect();
    by_language.sort_unstable();
    by_language.dedup_by_key(|(language, _)| *language);

    code.push_str("pub fn locale_by_language(language: &str) -> Option<&'static Locale> {\n");
    code.push_str("    hashify::tiny_map_ignore_case!(language.as_bytes(),\n");
    for (language, lang) in by_language {
        code.push_str(&format!(
            "        \"{}\" => &{}_LOCALES,\n",
            language,
            const_name(lang)
        ));
    }
    code.push_str("    )\n");
    code.push_str("}\n");
    code
}
