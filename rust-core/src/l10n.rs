use crate::models::{AppPreferences, L10nStatus};
use crate::paths::CorePaths;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::Duration;

pub const STE_STC_STANDARD: &str = "STE-STC";
pub const ANTIGRAVITY_ASAR_PATH: &str = "/Applications/Antigravity.app/Contents/Resources/app.asar";
const PATCH_MARKER_START: &str = "// === AGY_HIGHER_STC_PATCH_START ===";
const MAX_CUSTOM_BYTES: u64 = 64 * 1024;
const MAX_CUSTOM_ENTRIES: usize = 2000;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct L10nManifestFile {
    version: Option<String>,
    phrase_count: Option<usize>,
    sha256: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AsarPatchOutput {
    #[serde(default)]
    ok: bool,
    #[serde(default)]
    patched: bool,
    #[serde(default)]
    patch_version: String,
    #[serde(default)]
    restored_from_backup: bool,
    #[serde(default)]
    error: Option<String>,
}

/// Parse `~/.config/agy-higher/custom-translations.txt` using Antigravity-Hans rules:
/// - Blank lines and `#` comments are ignored
/// - `Source` (without `=`) => keep original English (`target == ""`)
/// - `Source = 译文` => custom override (last duplicate wins)
/// - Enforces 64 KB size limit and 2000 entry cap
pub fn parse_custom_translations(raw: &str) -> Vec<(String, String)> {
    let mut entries: Vec<(String, String)> = Vec::new();
    let mut seen: HashMap<String, usize> = HashMap::new();

    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let (src, dst) = match trimmed.find('=') {
            Some(idx) => (trimmed[..idx].trim(), trimmed[idx + 1..].trim()),
            None => (trimmed, ""),
        };
        if src.is_empty() {
            continue;
        }
        let key = src.to_lowercase();
        if let Some(&pos) = seen.get(&key) {
            entries[pos] = (src.to_string(), dst.to_string());
        } else {
            if entries.len() >= MAX_CUSTOM_ENTRIES {
                break;
            }
            seen.insert(key, entries.len());
            entries.push((src.to_string(), dst.to_string()));
        }
    }
    entries
}

pub fn load_custom_translations(path: &Path) -> Vec<(String, String)> {
    let Ok(meta) = fs::metadata(path) else {
        return Vec::new();
    };
    if !meta.is_file() || meta.len() > MAX_CUSTOM_BYTES {
        return Vec::new();
    }
    match fs::read_to_string(path) {
        Ok(raw) => parse_custom_translations(&raw),
        Err(_) => Vec::new(),
    }
}

/// Read installed Antigravity.app `CFBundleShortVersionString` (strictly read-only).
pub fn read_installed_antigravity_version() -> String {
    let plist_path = Path::new("/Applications/Antigravity.app/Contents/Info.plist");
    if !plist_path.is_file() {
        return "未安装".to_string();
    }
    if let Ok(raw) = fs::read_to_string(plist_path) {
        if let Some(ver) = extract_plist_string(&raw, "CFBundleShortVersionString") {
            return ver;
        }
    }
    if let Ok(out) = Command::new("/usr/libexec/PlistBuddy")
        .args([
            "-c",
            "Print :CFBundleShortVersionString",
            "/Applications/Antigravity.app/Contents/Info.plist",
        ])
        .output()
    {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !s.is_empty() {
                return s;
            }
        }
    }
    "未知".to_string()
}

fn extract_plist_string(xml: &str, key: &str) -> Option<String> {
    let marker = format!("<key>{}</key>", key);
    let idx = xml.find(&marker)?;
    let rest = &xml[idx + marker.len()..];
    let s_start = rest.find("<string>")? + "<string>".len();
    let after = &rest[s_start..];
    let s_end = after.find("</string>")?;
    let val = after[..s_end].trim();
    if val.is_empty() {
        None
    } else {
        Some(val.to_string())
    }
}

/// Sub-millisecond native Rust inspection of `/Applications/Antigravity.app/Contents/Resources/app.asar`.
/// Reads ONLY the ASAR header + `dist/main.js` bytes (no subprocess, no full file read).
pub fn inspect_asar_patch_fast(paths: &CorePaths, version: &str) -> (bool, String, bool) {
    if paths.sandbox_mode {
        return (false, String::new(), false);
    }
    let backup_dir = paths.config_dir.join("backups");
    let safe_ver: String = version
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let exact_backup = backup_dir.join(format!("app.asar.{}.orig", safe_ver));
    let backup_exists = exact_backup.is_file()
        || fs::read_dir(&backup_dir)
            .ok()
            .map(|rd| {
                rd.flatten().any(|e| {
                    e.file_name()
                        .to_str()
                        .map(|n| n.starts_with("app.asar.") && n.ends_with(".orig"))
                        .unwrap_or(false)
                })
            })
            .unwrap_or(false);

    let asar_path = Path::new(ANTIGRAVITY_ASAR_PATH);
    let Ok(mut f) = File::open(asar_path) else {
        return (false, String::new(), backup_exists);
    };
    let mut hdr = [0u8; 16];
    if f.read_exact(&mut hdr).is_err() {
        return (false, String::new(), backup_exists);
    }
    let header_size = u32::from_le_bytes([hdr[4], hdr[5], hdr[6], hdr[7]]) as u64;
    let json_len = u32::from_le_bytes([hdr[12], hdr[13], hdr[14], hdr[15]]) as usize;
    if json_len == 0 || json_len > 8 * 1024 * 1024 {
        return (false, String::new(), backup_exists);
    }
    let mut json_buf = vec![0u8; json_len];
    if f.read_exact(&mut json_buf).is_err() {
        return (false, String::new(), backup_exists);
    }
    let Ok(tree) = serde_json::from_slice::<serde_json::Value>(&json_buf) else {
        return (false, String::new(), backup_exists);
    };
    let Some(entry) = tree
        .get("files")
        .and_then(|v| v.get("dist"))
        .and_then(|v| v.get("files"))
        .and_then(|v| v.get("main.js"))
    else {
        return (false, String::new(), backup_exists);
    };
    let Some(offset_str) = entry.get("offset").and_then(|v| v.as_str()) else {
        return (false, String::new(), backup_exists);
    };
    let Ok(offset) = offset_str.parse::<u64>() else {
        return (false, String::new(), backup_exists);
    };
    let size = entry.get("size").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
    if size == 0 || size > 4 * 1024 * 1024 {
        return (false, String::new(), backup_exists);
    }
    if f.seek(SeekFrom::Start(8 + header_size + offset)).is_err() {
        return (false, String::new(), backup_exists);
    }
    let mut main_buf = vec![0u8; size];
    if f.read_exact(&mut main_buf).is_err() {
        return (false, String::new(), backup_exists);
    }
    let main_txt = String::from_utf8_lossy(&main_buf);
    let patched = main_txt.contains(PATCH_MARKER_START);
    let patch_version = if patched {
        if let Some(pos) = main_txt.find("AgyHigher STE-STC Main Process Loader (") {
            let after = &main_txt[pos + "AgyHigher STE-STC Main Process Loader (".len()..];
            after.split(')').next().unwrap_or("v2").to_string()
        } else {
            "v2".to_string()
        }
    } else {
        String::new()
    };
    (patched, patch_version, backup_exists)
}

pub fn ensure_custom_translations_template(paths: &CorePaths) -> Result<PathBuf, String> {
    let target = paths.custom_translations_path();
    paths.assert_safe_write_target(&target)?;
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    if !target.exists() {
        let template = "\
# AgyHigher STE-STC 自定义词条覆盖文件
# 规则（兼容 Antigravity-Hans 格式）：
# 1. 以 # 开头的行为注释，空行自动忽略
# 2. 仅写英文原文（不含 =）表示保留英文不翻译，例如：
# Context window
# 3. 使用 原文 = 译文 覆盖默认 STE-STC 翻译，例如：
# New Conversation = 创建新对话
# 4. 修改后在面板点击「同步词库」即可热更新生效（上限 64KB / 2000 条）
";
        fs::write(&target, template).map_err(|e| format!("写入自定义词条模板失败: {}", e))?;
    }
    Ok(target)
}

fn find_node_binary() -> Option<PathBuf> {
    let candidates = [
        "/opt/homebrew/bin/node",
        "/usr/local/bin/node",
        "/usr/bin/node",
    ];
    for c in &candidates {
        let p = Path::new(c);
        if p.is_file() {
            return Some(p.to_path_buf());
        }
    }
    if let Ok(path_env) = std::env::var("PATH") {
        for dir in path_env.split(':') {
            let p = Path::new(dir).join("node");
            if p.is_file() {
                return Some(p);
            }
        }
    }
    None
}

fn run_asar_patch_tool(paths: &CorePaths, args: &[&str]) -> Result<AsarPatchOutput, String> {
    let node_bin =
        find_node_binary().ok_or_else(|| "未找到 Node.js 运行时，无法执行补丁操作".to_string())?;
    let script = paths.repo_l10n_dir().join("tools").join("asar-patch.mjs");
    if !script.is_file() {
        return Err(format!("未找到补丁工具: {}", script.to_string_lossy()));
    }
    let out = Command::new(node_bin)
        .arg(&script)
        .args(args)
        .output()
        .map_err(|e| format!("执行补丁工具失败: {}", e))?;
    let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
    if let Ok(parsed) = serde_json::from_str::<AsarPatchOutput>(&stdout) {
        if parsed.ok {
            return Ok(parsed);
        }
        return Err(parsed.error.unwrap_or_else(|| "补丁操作失败".to_string()));
    }
    Err(if !stderr.is_empty() {
        stderr
    } else {
        format!("补丁工具返回异常: {}", stdout)
    })
}

/// Sync and rebuild `~/.config/agy-higher/l10n/antigravity-stc-overlay.js` + `manifest.json`.
/// Because the patched Antigravity main process watches `antigravity-stc-overlay.js`,
/// rebuilding automatically hot-reloads every open Antigravity window in ~150ms!
pub fn sync_and_rebuild_l10n(
    paths: &CorePaths,
    prefs: &AppPreferences,
) -> Result<(L10nStatus, String), String> {
    let out_dir = paths.l10n_dir();
    let overlay_target = paths.l10n_overlay_path();
    let manifest_target = paths.l10n_manifest_path();
    paths.assert_safe_write_target(&overlay_target)?;
    paths.assert_safe_write_target(&manifest_target)?;
    fs::create_dir_all(&out_dir).map_err(|e| format!("创建 l10n 目录失败: {}", e))?;

    let custom_path = paths.custom_translations_path();
    let repo_l10n = paths.repo_l10n_dir();
    let build_script = repo_l10n.join("tools").join("build-overlay.mjs");
    let lint_script = repo_l10n.join("tools").join("lint-l10n.mjs");
    let keep_flag = if prefs.l10n_keep_english_options {
        "true"
    } else {
        "false"
    };

    let mut rebuilt_via_node = false;
    if build_script.is_file() {
        if let Some(node_bin) = find_node_binary() {
            let mut cmd = Command::new(&node_bin);
            cmd.arg(&build_script)
                .arg("--out")
                .arg(&out_dir)
                .arg("--keep-english-options")
                .arg(keep_flag);
            if custom_path.is_file() {
                cmd.arg("--custom").arg(&custom_path);
            }
            let out = cmd
                .output()
                .map_err(|e| format!("执行 STE-STC 词库构建失败: {}", e))?;
            if !out.status.success() {
                let err_txt = String::from_utf8_lossy(&out.stderr).trim().to_string();
                return Err(format!("词库构建失败: {}", err_txt));
            }

            if lint_script.is_file()
                && repo_l10n.join("dist").join("antigravity-stc-overlay.js").is_file()
            {
                let lint_out = Command::new(&node_bin).arg(&lint_script).output();
                if let Ok(lo) = lint_out {
                    if !lo.status.success() {
                        let err_txt = String::from_utf8_lossy(&lo.stderr).trim().to_string();
                        return Err(format!("STE-STC 规范校验未通过: {}", err_txt));
                    }
                }
            }
            rebuilt_via_node = true;
        }
    }

    if !rebuilt_via_node {
        let prebuilt_overlay = repo_l10n.join("dist").join("antigravity-stc-overlay.js");
        let prebuilt_manifest = repo_l10n.join("dist").join("manifest.json");
        if !prebuilt_overlay.is_file() {
            return Err("未找到 l10n 词库源文件或预编译脚本".to_string());
        }
        let base_js = fs::read_to_string(&prebuilt_overlay).map_err(|e| e.to_string())?;
        let custom_entries = load_custom_translations(&custom_path);
        let custom_json =
            serde_json::to_string(&custom_entries).unwrap_or_else(|_| "[]".to_string());
        let prelude = format!(
            "window.__antigravityStcConfig = {{ keepEnglishOptionNames: {} }};\nwindow.__antigravityZhCustom = {};\n",
            keep_flag, custom_json
        );
        fs::write(&overlay_target, format!("{}{}", prelude, base_js))
            .map_err(|e| format!("写入 overlay 脚本失败: {}", e))?;
        if prebuilt_manifest.is_file() {
            let _ = fs::copy(&prebuilt_manifest, &manifest_target);
        }
    }

    let status = inspect_l10n_status(paths);
    let msg = if status.patch_installed && prefs.l10n_enabled {
        format!(
            "STE-STC 词库已同步并热推送（{} 条，自定义 {} 条）",
            status.phrase_count, status.custom_rule_count
        )
    } else {
        format!(
            "STE-STC 词库已同步（{} 条，自定义 {} 条）",
            status.phrase_count, status.custom_rule_count
        )
    };
    Ok((status, msg))
}

pub fn install_direct_patch(paths: &CorePaths, prefs: &AppPreferences) -> Result<String, String> {
    if paths.sandbox_mode {
        return Ok("沙盒模式跳过直接补丁安装".to_string());
    }
    sync_and_rebuild_l10n(paths, prefs)?;
    let ver = read_installed_antigravity_version();
    let backup_dir = paths.config_dir.join("backups");
    let backup_str = backup_dir.to_string_lossy().to_string();
    let res = run_asar_patch_tool(
        paths,
        &[
            "install",
            "--asar",
            ANTIGRAVITY_ASAR_PATH,
            "--backup-dir",
            &backup_str,
            "--version",
            &ver,
        ],
    )?;
    if !res.patched {
        return Err("补丁安装后未能确认生效".to_string());
    }
    Ok(format!(
        "已直接为 Antigravity {} 安装 STE-STC 补丁（原版已备份），重启 Antigravity 即生效",
        ver
    ))
}

pub fn uninstall_direct_patch(paths: &CorePaths) -> Result<String, String> {
    if paths.sandbox_mode {
        return Ok("沙盒模式跳过补丁卸载".to_string());
    }
    let ver = read_installed_antigravity_version();
    let backup_dir = paths.config_dir.join("backups");
    let backup_str = backup_dir.to_string_lossy().to_string();
    let res = run_asar_patch_tool(
        paths,
        &[
            "uninstall",
            "--asar",
            ANTIGRAVITY_ASAR_PATH,
            "--backup-dir",
            &backup_str,
            "--version",
            &ver,
        ],
    )?;
    if res.restored_from_backup {
        Ok("已从原版备份完整还原 Antigravity，重启后恢复原版英文".to_string())
    } else {
        Ok("已移除 Antigravity 补丁钩子，重启后恢复原版英文".to_string())
    }
}

/// Gracefully restart ONLY `/Applications/Antigravity.app` normally (no debug flags, never touches `agy` CLI).
pub fn restart_antigravity_normally(paths: &CorePaths) -> Result<String, String> {
    if paths.sandbox_mode {
        return Ok("沙盒模式跳过重启 Antigravity".to_string());
    }
    let _ = Command::new("/usr/bin/osascript")
        .args(["-e", r#"tell application "Antigravity" to quit"#])
        .output();

    // Wait up to 6s for Antigravity.app main process to exit cleanly
    for _ in 0..30 {
        let running = Command::new("/usr/bin/pgrep")
            .args(["-f", "/Applications/Antigravity.app/Contents/MacOS/Antigravity"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if !running {
            break;
        }
        thread::sleep(Duration::from_millis(200));
    }

    let status = Command::new("/usr/bin/open")
        .args(["-a", "/Applications/Antigravity.app"])
        .status()
        .map_err(|e| format!("启动 Antigravity 失败: {}", e))?;
    if !status.success() {
        return Err("未能正常启动 /Applications/Antigravity.app".to_string());
    }
    Ok("已正常重启 Antigravity（无需任何调试参数）".to_string())
}

pub fn inspect_l10n_status(paths: &CorePaths) -> L10nStatus {
    let antigravity_version = read_installed_antigravity_version();
    let overlay_path = paths.l10n_overlay_path();
    let custom_path = paths.custom_translations_path();
    let custom_rule_count = load_custom_translations(&custom_path).len();

    let manifest_candidates = [
        paths.l10n_manifest_path(),
        paths.repo_l10n_dir().join("dist").join("manifest.json"),
    ];
    let mut dict_version = "2.35.0".to_string();
    let mut phrase_count = 0usize;
    let mut sha256 = String::new();

    for cand in &manifest_candidates {
        if let Ok(raw) = fs::read_to_string(cand) {
            if let Ok(m) = serde_json::from_str::<L10nManifestFile>(&raw) {
                if let Some(v) = m.version {
                    dict_version = v;
                }
                if let Some(c) = m.phrase_count {
                    phrase_count = c;
                }
                if let Some(h) = m.sha256 {
                    sha256 = h.chars().take(12).collect();
                }
                break;
            }
        }
    }

    let (patch_installed, patch_version, backup_exists) =
        inspect_asar_patch_fast(paths, &antigravity_version);

    let overlay_ready = overlay_path.is_file();
    L10nStatus {
        antigravity_version,
        standard: STE_STC_STANDARD.to_string(),
        dictionary_version: dict_version,
        phrase_count,
        custom_rule_count,
        overlay_path: overlay_path.to_string_lossy().to_string(),
        custom_file_path: custom_path.to_string_lossy().to_string(),
        overlay_ready,
        bundle_sha_short: sha256,
        patch_installed,
        patch_version,
        backup_exists,
    }
}
