use crate::models::{ContextBreakdown, NativeProject, SessionTelemetry, ToolUsageStat};
use crate::paths::{home_dir, CorePaths};
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::UNIX_EPOCH;

extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}
const LOCK_SH: i32 = 1;
const LOCK_NB: i32 = 4;
const LOCK_UN: i32 = 8;

#[derive(Debug, Clone)]
struct RawSummaryRow {
    id: String,
    title: String,
    preview: String,
    cwd: String,
    workspace_paths: Vec<String>,
    step_count: u32,
    status: String,
    project_id: String,
    last_modified: String,
    subagent_count: u32,
    not_fully_idle: bool,
    killed: bool,
}

#[derive(Debug, Clone, Default)]
pub struct ParsedAnnotation {
    pub title: Option<String>,
    pub pinned: bool,
    pub archived: bool,
    pub starred: bool,
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeDbTelemetry {
    pub model: String,
    pub models_used: Vec<String>,
    pub ctx_used_tokens: u64,
    pub ctx_limit_tokens: u64,
    pub last_input_tokens: u64,
    pub last_cache_read_tokens: u64,
    pub last_output_tokens: u64,
    pub total_input_tokens: u64,
    pub total_cache_read_tokens: u64,
    pub total_output_tokens: u64,
    pub total_thinking_tokens: u64,
    pub llm_turns: u32,
    pub user_turns: u32,
    pub assistant_turns: u32,
    pub tool_call_count: u32,
    pub checkpoint_count: u32,
    pub total_steps_in_db: u32,
    pub has_gen_metadata: bool,
    #[serde(default)]
    pub is_compacted_pending_turn: bool,
    #[serde(default)]
    pub pending_compact_est_tokens: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TranscriptSupplement {
    model: String,
    models_used: Vec<String>,
    ctx_used_tokens: u64,
    last_input_tokens: u64,
    last_cache_read_tokens: u64,
    last_output_tokens: u64,
    total_input_tokens: u64,
    total_cache_read_tokens: u64,
    total_output_tokens: u64,
    user_turns: u32,
    assistant_turns: u32,
    tool_call_count: u32,
    top_tools: Vec<ToolUsageStat>,
    checkpoint_count: u32,
    last_user_prompt: String,
    created_at: String,
    has_data: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DbFileFingerprint {
    file_len: u64,
    mtime_ns: u64,
    wal_len: u64,
    wal_mtime_ns: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TxFileFingerprint {
    file_len: u64,
    mtime_ns: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CachedDbTelemetry {
    fp: DbFileFingerprint,
    telemetry: NativeDbTelemetry,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CachedTranscript {
    fp: TxFileFingerprint,
    supplement: TranscriptSupplement,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistentTelemetryCache {
    version: u32,
    #[serde(default)]
    db_entries: HashMap<String, CachedDbTelemetry>,
    #[serde(default)]
    tx_entries: HashMap<String, CachedTranscript>,
}

const TELEMETRY_CACHE_VERSION: u32 = 2;

static TELEMETRY_CACHE_STORE: OnceLock<Mutex<HashMap<String, PersistentTelemetryCache>>> =
    OnceLock::new();

fn telemetry_cache_store() -> &'static Mutex<HashMap<String, PersistentTelemetryCache>> {
    TELEMETRY_CACHE_STORE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn ensure_cache_loaded(paths: &CorePaths) -> String {
    let store_key = paths.telemetry_cache_path().to_string_lossy().to_string();
    let mut guard = match telemetry_cache_store().lock() {
        Ok(g) => g,
        Err(_) => return store_key,
    };
    if !guard.contains_key(&store_key) {
        let loaded = fs::read_to_string(paths.telemetry_cache_path())
            .ok()
            .and_then(|raw| serde_json::from_str::<PersistentTelemetryCache>(&raw).ok())
            .filter(|c| c.version == TELEMETRY_CACHE_VERSION)
            .unwrap_or(PersistentTelemetryCache {
                version: TELEMETRY_CACHE_VERSION,
                db_entries: HashMap::new(),
                tx_entries: HashMap::new(),
            });
        guard.insert(store_key.clone(), loaded);
    }
    store_key
}

fn save_telemetry_cache_to_disk(paths: &CorePaths, cache: &PersistentTelemetryCache) {
    let target = paths.telemetry_cache_path();
    if paths.assert_safe_write_target(&target).is_err() {
        return;
    }
    if let Some(parent) = target.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let Ok(bytes) = serde_json::to_vec(cache) else {
        return;
    };
    let tmp = target.with_extension("json.tmp");
    if let Ok(mut f) = File::create(&tmp) {
        if f.write_all(&bytes).is_ok() {
            let _ = fs::rename(&tmp, &target);
        } else {
            let _ = fs::remove_file(&tmp);
        }
    }
}

fn file_mtime_ns(meta: &fs::Metadata) -> u64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

fn db_fingerprint(db_path: &Path) -> Option<DbFileFingerprint> {
    let meta = fs::metadata(db_path).ok()?;
    let mut wal_os = db_path.as_os_str().to_os_string();
    wal_os.push("-wal");
    let wal_meta = fs::metadata(PathBuf::from(wal_os)).ok();
    Some(DbFileFingerprint {
        file_len: meta.len(),
        mtime_ns: file_mtime_ns(&meta),
        wal_len: wal_meta.as_ref().map(|m| m.len()).unwrap_or(0),
        wal_mtime_ns: wal_meta.as_ref().map(file_mtime_ns).unwrap_or(0),
    })
}

fn tx_fingerprint(tx_path: &Path) -> Option<TxFileFingerprint> {
    let meta = fs::metadata(tx_path).ok()?;
    Some(TxFileFingerprint {
        file_len: meta.len(),
        mtime_ns: file_mtime_ns(&meta),
    })
}

/// Check if a specific session's DB & transcript are already cached and unchanged on disk.
pub fn is_session_cache_fresh(paths: &CorePaths, session_id: &str) -> bool {
    let store_key = ensure_cache_loaded(paths);
    let db_path = paths.conversations_dir().join(format!("{}.db", session_id));
    let tx_path = paths
        .brain_dir()
        .join(session_id)
        .join(".system_generated")
        .join("logs")
        .join("transcript.jsonl");
    let db_fp = db_fingerprint(&db_path);
    let tx_fp = tx_fingerprint(&tx_path);

    let Ok(guard) = telemetry_cache_store().lock() else {
        return false;
    };
    let Some(cache) = guard.get(&store_key) else {
        return false;
    };

    if let Some(fp) = db_fp {
        let key = db_path.to_string_lossy();
        match cache.db_entries.get(key.as_ref()) {
            Some(entry) if entry.fp == fp => {}
            _ => return false,
        }
    }
    if let Some(fp) = tx_fp {
        let key = tx_path.to_string_lossy();
        match cache.tx_entries.get(key.as_ref()) {
            Some(entry) if entry.fp == fp => {}
            _ => return false,
        }
    }
    true
}

/// Fast & WAL-safe read-only SQLite open:
/// - If a live non-empty `-wal` file exists, NEVER fall back to `immutable=1` (which ignores WAL frames
///   and would return stale pre-WAL context tokens!). Instead wait up to 1.5s via `busy_timeout`.
/// - Only use `immutable=1` when `-wal` is absent or empty (e.g. archived WAL DB without `-shm`).
pub fn open_sqlite_readonly(db_path: &Path) -> Result<Connection, String> {
    let mut shm_os = db_path.as_os_str().to_os_string();
    shm_os.push("-shm");
    let mut wal_os = db_path.as_os_str().to_os_string();
    wal_os.push("-wal");
    let wal_path = PathBuf::from(&wal_os);
    let has_live_wal = fs::metadata(&wal_path).map(|m| m.len() > 0).unwrap_or(false);

    let mut prefer_immutable = false;
    if !has_live_wal {
        if let Ok(mut f) = File::open(db_path) {
            let mut hdr = [0u8; 20];
            if f.read_exact(&mut hdr).is_ok() && hdr[18] == 2 && !Path::new(&shm_os).exists() {
                prefer_immutable = true;
            }
        }
    }

    if !prefer_immutable {
        let ro_flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        if let Ok(conn) = Connection::open_with_flags(db_path, ro_flags) {
            let _ = conn.busy_timeout(std::time::Duration::from_millis(1500));
            if conn.execute_batch("PRAGMA query_only = ON;").is_ok() {
                return Ok(conn);
            }
        }
        if has_live_wal {
            return Err(format!(
                "Live WAL database {:?} temporarily busy; refusing stale immutable fallback",
                db_path
            ));
        }
    }

    let encoded_path = db_path
        .to_string_lossy()
        .replace('%', "%25")
        .replace('?', "%3F")
        .replace('#', "%23");
    let uri = format!("file:{}?mode=ro&immutable=1", encoded_path);
    let uri_flags =
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let conn = Connection::open_with_flags(&uri, uri_flags)
        .map_err(|e| format!("Failed to open {:?} read-only: {}", db_path, e))?;
    let _ = conn.busy_timeout(std::time::Duration::from_millis(800));
    let _ = conn.execute_batch("PRAGMA query_only = ON;");
    Ok(conn)
}

/// Scan ONLY Antigravity Desktop native projects and sessions (`~/.gemini/antigravity/`)
/// strictly in READ-ONLY mode, using WAL-aware persistent disk cache + parallel cold hydration.
pub fn scan_antigravity_desktop(
    paths: &CorePaths,
    _focus_session_id: Option<&str>,
    show_archived_sessions: bool,
) -> (Vec<NativeProject>, Vec<SessionTelemetry>) {
    let store_key = ensure_cache_loaded(paths);
    let project_defs = load_native_projects_readonly(paths);
    let project_name_map: HashMap<String, String> = project_defs
        .iter()
        .map(|p| (p.id.clone(), p.name.clone()))
        .collect();

    let raw_rows = read_desktop_summary_rows_readonly(paths);

    // Pre-check disk cache for every session and hydrate all cache misses in parallel!
    let mut db_results: HashMap<String, Option<NativeDbTelemetry>> =
        HashMap::with_capacity(raw_rows.len());
    let mut tx_results: HashMap<String, TranscriptSupplement> =
        HashMap::with_capacity(raw_rows.len());
    let mut db_misses: Vec<(String, PathBuf, DbFileFingerprint)> = Vec::new();
    let mut tx_misses: Vec<(String, PathBuf, TxFileFingerprint)> = Vec::new();

    {
        let guard = telemetry_cache_store().lock().ok();
        let cache = guard.as_ref().and_then(|g| g.get(&store_key));

        for raw in &raw_rows {
            let db_path = paths.conversations_dir().join(format!("{}.db", raw.id));
            if let Some(fp) = db_fingerprint(&db_path) {
                let key = db_path.to_string_lossy().to_string();
                if let Some(entry) = cache.and_then(|c| c.db_entries.get(&key)) {
                    if entry.fp == fp {
                        db_results.insert(raw.id.clone(), Some(entry.telemetry.clone()));
                    } else {
                        db_misses.push((raw.id.clone(), db_path, fp));
                    }
                } else {
                    db_misses.push((raw.id.clone(), db_path, fp));
                }
            } else {
                db_results.insert(raw.id.clone(), None);
            }

            let tx_path = paths
                .brain_dir()
                .join(&raw.id)
                .join(".system_generated")
                .join("logs")
                .join("transcript.jsonl");
            if let Some(fp) = tx_fingerprint(&tx_path) {
                let key = tx_path.to_string_lossy().to_string();
                if let Some(entry) = cache.and_then(|c| c.tx_entries.get(&key)) {
                    if entry.fp == fp {
                        tx_results.insert(raw.id.clone(), entry.supplement.clone());
                    } else {
                        tx_misses.push((raw.id.clone(), tx_path, fp));
                    }
                } else {
                    tx_misses.push((raw.id.clone(), tx_path, fp));
                }
            } else {
                tx_results.insert(raw.id.clone(), TranscriptSupplement::default());
            }
        }
    }

    // Parallel cold parsing when >= 2 files need parsing
    let mut cache_dirty = false;
    let mut parsed_dbs: Vec<(String, String, DbFileFingerprint, Option<NativeDbTelemetry>)> =
        Vec::with_capacity(db_misses.len());
    let mut parsed_txs: Vec<(String, String, TxFileFingerprint, TranscriptSupplement)> =
        Vec::with_capacity(tx_misses.len());

    if db_misses.len() + tx_misses.len() >= 2 {
        std::thread::scope(|s| {
            let mut db_handles = Vec::with_capacity(db_misses.len());
            for (sid, path, fp) in db_misses {
                db_handles.push(s.spawn(move || {
                    let key = path.to_string_lossy().to_string();
                    let parsed = parse_conv_db_telemetry(&path);
                    (sid, key, fp, parsed)
                }));
            }
            let mut tx_handles = Vec::with_capacity(tx_misses.len());
            for (sid, path, fp) in tx_misses {
                tx_handles.push(s.spawn(move || {
                    let key = path.to_string_lossy().to_string();
                    let parsed = parse_transcript_full(&path);
                    (sid, key, fp, parsed)
                }));
            }
            for h in db_handles {
                if let Ok(item) = h.join() {
                    parsed_dbs.push(item);
                }
            }
            for h in tx_handles {
                if let Ok(item) = h.join() {
                    parsed_txs.push(item);
                }
            }
        });
    } else {
        for (sid, path, fp) in db_misses {
            let key = path.to_string_lossy().to_string();
            let parsed = parse_conv_db_telemetry(&path);
            parsed_dbs.push((sid, key, fp, parsed));
        }
        for (sid, path, fp) in tx_misses {
            let key = path.to_string_lossy().to_string();
            let parsed = parse_transcript_full(&path);
            parsed_txs.push((sid, key, fp, parsed));
        }
    }

    if !parsed_dbs.is_empty() || !parsed_txs.is_empty() {
        let mut snapshot_to_save: Option<PersistentTelemetryCache> = None;
        if let Ok(mut guard) = telemetry_cache_store().lock() {
            let cache = guard
                .entry(store_key.clone())
                .or_insert_with(|| PersistentTelemetryCache {
                    version: TELEMETRY_CACHE_VERSION,
                    db_entries: HashMap::new(),
                    tx_entries: HashMap::new(),
                });
            for (sid, key, fp, tel) in parsed_dbs {
                if let Some(ref parsed) = tel {
                    cache.db_entries.insert(
                        key,
                        CachedDbTelemetry {
                            fp,
                            telemetry: parsed.clone(),
                        },
                    );
                    cache_dirty = true;
                }
                db_results.insert(sid, tel);
            }
            for (sid, key, fp, supp) in parsed_txs {
                cache.tx_entries.insert(
                    key,
                    CachedTranscript {
                        fp,
                        supplement: supp.clone(),
                    },
                );
                cache_dirty = true;
                tx_results.insert(sid, supp);
            }
            if cache_dirty {
                // Keep cache bounded by pruning deleted files
                cache.db_entries.retain(|k, _| Path::new(k).exists());
                cache.tx_entries.retain(|k, _| Path::new(k).exists());
                snapshot_to_save = Some(cache.clone());
            }
        }
        if let Some(cache_snap) = snapshot_to_save {
            save_telemetry_cache_to_disk(paths, &cache_snap);
        }
    }

    let mut branch_cache: HashMap<String, String> = HashMap::new();
    let mut rules_cache: HashMap<String, Vec<String>> = HashMap::new();
    let now_ns = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let mut scored_sessions: Vec<(bool, u64, SessionTelemetry)> = Vec::with_capacity(raw_rows.len());

    for raw in raw_rows {
        let ann = read_annotation_readonly(paths, &raw.id);
        if ann.archived && !show_archived_sessions {
            continue;
        }
        let is_pinned = ann.pinned;
        let is_starred = ann.starred;
        let is_archived = ann.archived;
        let tags = ann.tags;
        let title = if let Some(t) = ann.title.filter(|s| !s.trim().is_empty()) {
            t
        } else if !raw.title.trim().is_empty() {
            raw.title.trim().to_string()
        } else if !raw.preview.trim().is_empty() {
            clean_snippet(&raw.preview, 48)
        } else {
            format!("会话 {}", &raw.id.chars().take(8).collect::<String>())
        };

        let db_tel = db_results.remove(&raw.id).flatten();
        let tx_tel = tx_results.remove(&raw.id).unwrap_or_default();

        let effective_pid =
            if !raw.project_id.is_empty() && project_name_map.contains_key(&raw.project_id) {
                raw.project_id.clone()
            } else {
                match_project_by_cwd(&raw.cwd, &project_defs)
            };
        let project_name = project_name_map
            .get(&effective_pid)
            .cloned()
            .unwrap_or_else(|| "默认工作区".to_string());

        let (
            model,
            models_used,
            ctx_used_tokens,
            ctx_limit_tokens,
            total_input_tokens,
            total_cache_read_tokens,
            total_output_tokens,
            total_thinking_tokens,
            llm_turns,
            user_turns,
            assistant_turns,
            tool_call_count,
            checkpoint_count,
            last_in,
            last_cache,
            last_out,
            telemetry_origin,
        ) = if let Some(ref dt) = db_tel {
            if dt.has_gen_metadata {
                let model = if !dt.model.is_empty() {
                    dt.model.clone()
                } else if !tx_tel.model.is_empty() {
                    tx_tel.model.clone()
                } else {
                    "Gemini 4 Neon".to_string()
                };
                let mut models = dt.models_used.clone();
                if models.is_empty() {
                    models.push(model.clone());
                }
                let (ctx_used, last_in_eff, last_cache_eff, last_out_eff, origin) =
                    if dt.is_compacted_pending_turn {
                        let est = dt.pending_compact_est_tokens.max(18_000);
                        (est, est.saturating_sub(12_000), 0u64, 0u64, "compacted-pending".to_string())
                    } else {
                        let used = if dt.ctx_used_tokens > 0 {
                            dt.ctx_used_tokens
                        } else {
                            dt.last_input_tokens + dt.last_cache_read_tokens
                        };
                        (
                            used,
                            dt.last_input_tokens,
                            dt.last_cache_read_tokens,
                            dt.last_output_tokens,
                            "db+gen_metadata".to_string(),
                        )
                    };
                let ctx_limit = if dt.ctx_limit_tokens > 0 {
                    dt.ctx_limit_tokens
                } else {
                    default_context_limit_tokens(&model)
                };
                let tools = tx_tel.tool_call_count.max(dt.tool_call_count);
                (
                    model,
                    models,
                    ctx_used,
                    ctx_limit,
                    dt.total_input_tokens,
                    dt.total_cache_read_tokens,
                    dt.total_output_tokens,
                    dt.total_thinking_tokens,
                    dt.llm_turns,
                    dt.user_turns.max(tx_tel.user_turns),
                    dt.assistant_turns.max(dt.llm_turns),
                    tools,
                    dt.checkpoint_count.max(tx_tel.checkpoint_count),
                    last_in_eff,
                    last_cache_eff,
                    last_out_eff,
                    origin,
                )
            } else if tx_tel.has_data {
                let model = if !tx_tel.model.is_empty() {
                    tx_tel.model.clone()
                } else {
                    "Gemini 4 Neon".to_string()
                };
                let ctx_limit = default_context_limit_tokens(&model);
                (
                    model.clone(),
                    if tx_tel.models_used.is_empty() {
                        vec![model]
                    } else {
                        tx_tel.models_used.clone()
                    },
                    tx_tel.ctx_used_tokens,
                    ctx_limit,
                    tx_tel.total_input_tokens,
                    tx_tel.total_cache_read_tokens,
                    tx_tel.total_output_tokens,
                    0,
                    tx_tel.assistant_turns,
                    tx_tel.user_turns,
                    tx_tel.assistant_turns,
                    tx_tel.tool_call_count,
                    tx_tel.checkpoint_count,
                    tx_tel.last_input_tokens,
                    tx_tel.last_cache_read_tokens,
                    tx_tel.last_output_tokens,
                    "transcript.jsonl".to_string(),
                )
            } else {
                (
                    "Gemini 4 Neon".to_string(),
                    vec!["Gemini 4 Neon".to_string()],
                    0,
                    512_000,
                    0,
                    0,
                    0,
                    0,
                    0,
                    dt.user_turns,
                    dt.assistant_turns,
                    dt.tool_call_count,
                    dt.checkpoint_count,
                    0,
                    0,
                    0,
                    "db-steps".to_string(),
                )
            }
        } else if tx_tel.has_data {
            let model = if !tx_tel.model.is_empty() {
                tx_tel.model.clone()
            } else {
                "Gemini 4 Neon".to_string()
            };
            let ctx_limit = default_context_limit_tokens(&model);
            (
                model.clone(),
                if tx_tel.models_used.is_empty() {
                    vec![model]
                } else {
                    tx_tel.models_used.clone()
                },
                tx_tel.ctx_used_tokens,
                ctx_limit,
                tx_tel.total_input_tokens,
                tx_tel.total_cache_read_tokens,
                tx_tel.total_output_tokens,
                0,
                tx_tel.assistant_turns,
                tx_tel.user_turns,
                tx_tel.assistant_turns,
                tx_tel.tool_call_count,
                tx_tel.checkpoint_count,
                tx_tel.last_input_tokens,
                tx_tel.last_cache_read_tokens,
                tx_tel.last_output_tokens,
                "transcript.jsonl".to_string(),
            )
        } else {
            (
                "Gemini 4 Neon".to_string(),
                vec!["Gemini 4 Neon".to_string()],
                0,
                512_000,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                "summary-only".to_string(),
            )
        };

        let ctx_used_k = ((ctx_used_tokens as f64) / 1000.0).round() as u32;
        let ctx_total_k = ((ctx_limit_tokens.max(1000) as f64) / 1000.0).round() as u32;
        let ctx_pct = if ctx_limit_tokens > 0 && ctx_used_tokens > 0 {
            (((ctx_used_tokens as f64) / (ctx_limit_tokens as f64)) * 100.0)
                .round()
                .clamp(1.0, 100.0) as u32
        } else {
            0
        };

        let rules_k = if ctx_used_k > 0 {
            12u32.min(ctx_used_k)
        } else {
            0
        };
        let cache_k = (((last_cache as f64) / 1000.0).round() as u32)
            .saturating_sub(rules_k)
            .min(ctx_used_k.saturating_sub(rules_k));
        let fresh_input_k = (((last_in as f64) / 1000.0).round() as u32)
            .min(ctx_used_k.saturating_sub(rules_k + cache_k));
        let output_k = (((last_out as f64) / 1000.0).round() as u32)
            .min(ctx_total_k.saturating_sub(rules_k + cache_k + fresh_input_k));
        let occupied = rules_k + cache_k + fresh_input_k + output_k;
        let free_k = ctx_total_k.saturating_sub(occupied.max(ctx_used_k));

        let total_prompt = total_input_tokens + total_cache_read_tokens;
        let cache_hit_pct = if total_prompt > 0 {
            (((total_cache_read_tokens as f64) / (total_prompt as f64)) * 100.0)
                .round()
                .clamp(0.0, 100.0) as u32
        } else {
            0
        };

        let cost_usd = estimate_reference_cost_usd(
            &model,
            total_input_tokens,
            total_cache_read_tokens,
            total_output_tokens,
        );

        let branch = if raw.cwd.is_empty() {
            "-".to_string()
        } else {
            branch_cache
                .entry(raw.cwd.clone())
                .or_insert_with(|| read_git_branch_readonly(Path::new(&raw.cwd)))
                .clone()
        };
        let workspace_rule_files = if raw.cwd.is_empty() {
            vec![]
        } else {
            rules_cache
                .entry(raw.cwd.clone())
                .or_insert_with(|| detect_workspace_rule_files(Path::new(&raw.cwd)))
                .clone()
        };
        let artifact_files = list_brain_artifacts_readonly(paths, &raw.id);
        let (is_locked, lock_mtime_ns) = inspect_session_lock_readonly(paths, &raw.id);
        let db_path = paths.conversations_dir().join(format!("{}.db", raw.id));
        let db_fp = db_fingerprint(&db_path);
        let disk_db_ns = db_fp
            .as_ref()
            .map(|f| f.mtime_ns.max(f.wal_mtime_ns))
            .unwrap_or(0);
        let recent_db_write =
            disk_db_ns > 0 && now_ns.saturating_sub(disk_db_ns) <= 90_000_000_000;
        let is_live_active = !raw.killed
            && (is_locked
                || recent_db_write
                || raw.not_fully_idle
                || raw.status.contains("RUNNING")
                || raw.status.contains("ACTIVE"));
        let activity_ns = disk_db_ns.max(lock_mtime_ns);

        let clean_preview = clean_snippet(&raw.preview, 200);
        let last_user_prompt = if !tx_tel.last_user_prompt.is_empty() {
            tx_tel.last_user_prompt.clone()
        } else {
            clean_preview.clone()
        };
        let step_count = raw
            .step_count
            .max(db_tel.as_ref().map(|d| d.total_steps_in_db).unwrap_or(0));

        let short_id = raw.id.chars().take(8).collect::<String>();
        let short_path = shorten_home_path(&raw.cwd);

        let session_obj = SessionTelemetry {
            id: raw.id,
            short_id,
            project_id: effective_pid,
            project_name,
            cwd: raw.cwd,
            short_path,
            workspace_paths: raw.workspace_paths,
            title,
            preview: clean_preview,
            last_user_prompt,
            is_pinned,
            is_starred,
            is_archived,
            tags,
            status: normalize_status(&raw.status, is_live_active),
            is_live_active,
            branch,
            workspace_rule_files,
            artifact_files,
            model,
            models_used,
            ctx_used_tokens,
            ctx_limit_tokens,
            ctx_used_k,
            ctx_total_k,
            ctx_pct,
            breakdown: ContextBreakdown {
                rules_k,
                cache_k,
                fresh_input_k,
                output_k,
                free_k,
            },
            total_input_tokens,
            total_cache_read_tokens,
            total_output_tokens,
            total_thinking_tokens,
            cache_hit_pct,
            cost_usd,
            step_count,
            llm_turns,
            user_turns,
            assistant_turns,
            tool_call_count,
            top_tools: tx_tel.top_tools,
            checkpoint_count,
            subagent_count: raw.subagent_count,
            is_compacted_pending_turn: db_tel
                .as_ref()
                .map(|d| d.is_compacted_pending_turn)
                .unwrap_or(false),
            telemetry_origin,
            created_at: tx_tel.created_at,
            last_modified: format_display_timestamp(&raw.last_modified),
        };
        scored_sessions.push((is_locked, activity_ns, session_obj));
    }

    // Strict active-session ordering:
    // 1. Actively locked by Antigravity.app (`presence/*.lock` flock held)
    // 2. Live active (recent DB/WAL write <= 90s or RUNNING status)
    // 3. Most recently touched on disk (db_mtime / wal_mtime / lock_mtime)
    // 4. Summary last_modified timestamp
    scored_sessions.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| b.2.is_live_active.cmp(&a.2.is_live_active))
            .then_with(|| b.1.cmp(&a.1))
            .then_with(|| b.2.last_modified.cmp(&a.2.last_modified))
            .then_with(|| a.2.title.cmp(&b.2.title))
    });
    let sessions: Vec<SessionTelemetry> = scored_sessions.into_iter().map(|(_, _, s)| s).collect();

    let mut projects = project_defs;
    let mut seen_pids: HashSet<String> = projects.iter().map(|p| p.id.clone()).collect();
    for s in &sessions {
        if !seen_pids.contains(&s.project_id) {
            seen_pids.insert(s.project_id.clone());
            projects.push(NativeProject {
                id: s.project_id.clone(),
                name: s.project_name.clone(),
                folder_path: if s.cwd.is_empty() {
                    None
                } else {
                    Some(s.cwd.clone())
                },
                session_count: 0,
                total_steps: 0,
                last_modified: String::new(),
            });
        }
    }

    for p in &mut projects {
        let mut count = 0usize;
        let mut steps = 0u32;
        let mut latest = String::new();
        for s in &sessions {
            if s.project_id == p.id {
                count += 1;
                steps = steps.saturating_add(s.step_count);
                if s.last_modified > latest {
                    latest = s.last_modified.clone();
                }
            }
        }
        p.session_count = count;
        p.total_steps = steps;
        p.last_modified = latest;
    }

    projects.retain(|p| !(p.id == "default-cli-project" && p.session_count == 0));

    (projects, sessions)
}

fn load_native_projects_readonly(paths: &CorePaths) -> Vec<NativeProject> {
    let mut order_map: HashMap<String, usize> = HashMap::new();
    if let Ok(raw) = fs::read_to_string(&paths.app_storage_path) {
        if let Ok(val) = serde_json::from_str::<Value>(&raw) {
            if let Some(order_str) = val.get("projectsOrder").and_then(Value::as_str) {
                if let Ok(arr) = serde_json::from_str::<Vec<String>>(order_str) {
                    for (idx, pid) in arr.into_iter().enumerate() {
                        order_map.insert(pid, idx);
                    }
                }
            }
        }
    }

    let mut out = Vec::new();
    if let Ok(entries) = fs::read_dir(&paths.gemini_projects_dir) {
        for e in entries.flatten() {
            let p = e.path();
            if p.extension().and_then(|x| x.to_str()) != Some("json") {
                continue;
            }
            let Ok(raw) = fs::read_to_string(&p) else {
                continue;
            };
            let Ok(val) = serde_json::from_str::<Value>(&raw) else {
                continue;
            };
            if val.get("sidecar").is_some() && !val.get("sidecar").unwrap().is_null() {
                continue;
            }
            let id = val
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string();
            if id.is_empty() {
                continue;
            }
            let name = val
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or(&id)
                .trim()
                .to_string();
            let folder_path = val
                .get("projectResources")
                .and_then(|pr| pr.get("resources"))
                .and_then(Value::as_array)
                .and_then(|arr| arr.first())
                .and_then(|r| r.get("folderUri"))
                .and_then(Value::as_str)
                .and_then(file_uri_to_path);

            out.push(NativeProject {
                id,
                name,
                folder_path,
                session_count: 0,
                total_steps: 0,
                last_modified: String::new(),
            });
        }
    }

    out.sort_by(|a, b| {
        let oa = order_map.get(&a.id).copied().unwrap_or(9999);
        let ob = order_map.get(&b.id).copied().unwrap_or(9999);
        oa.cmp(&ob)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    out
}

fn match_project_by_cwd(cwd: &str, projects: &[NativeProject]) -> String {
    let norm = cwd.trim_end_matches('/');
    if norm.is_empty() {
        return "default".to_string();
    }
    let mut best: Option<(usize, &str)> = None;
    for p in projects {
        if let Some(ref fp) = p.folder_path {
            let base = fp.trim_end_matches('/');
            if norm == base || norm.starts_with(&format!("{}/", base)) {
                let len = base.len();
                if best.map(|(bl, _)| len > bl).unwrap_or(true) {
                    best = Some((len, p.id.as_str()));
                }
            }
        }
    }
    best.map(|(_, id)| id.to_string())
        .unwrap_or_else(|| "default".to_string())
}

fn read_desktop_summary_rows_readonly(paths: &CorePaths) -> Vec<RawSummaryRow> {
    let mut map: HashMap<String, RawSummaryRow> = HashMap::new();
    let mut known_skip_ids: HashSet<String> = HashSet::new();
    let db_path = paths.summaries_db_path();

    if db_path.is_file() {
        if let Ok(conn) = open_sqlite_readonly(&db_path) {
            let mut subagent_counts: HashMap<String, u32> = HashMap::new();
            // Collect child conversation IDs & CLI conversation IDs in 1 pass so we NEVER open
            // their .db files redundantly during the unindexed-file fallback scan below!
            if let Ok(mut stmt) = conn.prepare(
                "SELECT conversation_id, parent_conversation_id
                 FROM conversation_summaries
                 WHERE parent_conversation_id != '' OR source = 'CORTEX_TRAJECTORY_SOURCE_CLI'",
            ) {
                if let Ok(iter) = stmt.query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    ))
                }) {
                    for (cid, pid) in iter.flatten() {
                        known_skip_ids.insert(cid);
                        if !pid.is_empty() {
                            *subagent_counts.entry(pid).or_insert(0) += 1;
                        }
                    }
                }
            }

            // Inspect available columns once so we support v2.35.0 (`not_fully_idle`, `killed`)
            // while remaining 100% compatible with older DB schemas.
            let mut has_v235_runtime_cols = false;
            if let Ok(mut info_stmt) = conn.prepare("PRAGMA table_info(conversation_summaries)") {
                if let Ok(iter) = info_stmt.query_map([], |row| row.get::<_, String>(1)) {
                    let cols: HashSet<String> = iter.flatten().collect();
                    has_v235_runtime_cols =
                        cols.contains("not_fully_idle") && cols.contains("killed");
                }
            }

            // v2.35.0 enables unlimited local conversation history -> no LIMIT 1000 cap.
            let sql = if has_v235_runtime_cols {
                "SELECT conversation_id, title, preview, step_count, last_modified_time,
                        workspace_uris, status, source, project_id, parent_conversation_id,
                        COALESCE(not_fully_idle, 0), COALESCE(killed, 0)
                 FROM conversation_summaries
                 WHERE COALESCE(parent_conversation_id, '') = ''
                   AND COALESCE(source, '') != 'CORTEX_TRAJECTORY_SOURCE_CLI'
                 ORDER BY last_modified_time DESC"
            } else {
                "SELECT conversation_id, title, preview, step_count, last_modified_time,
                        workspace_uris, status, source, project_id, parent_conversation_id,
                        0, 0
                 FROM conversation_summaries
                 WHERE COALESCE(parent_conversation_id, '') = ''
                   AND COALESCE(source, '') != 'CORTEX_TRAJECTORY_SOURCE_CLI'
                 ORDER BY last_modified_time DESC"
            };
            if let Ok(mut stmt) = conn.prepare(sql) {
                let rows = stmt.query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                        row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                        row.get::<_, Option<i64>>(3)?.unwrap_or(0).max(0) as u32,
                        row.get::<_, Option<String>>(4)?.unwrap_or_default(),
                        row.get::<_, Option<String>>(5)?.unwrap_or_default(),
                        row.get::<_, Option<String>>(6)?.unwrap_or_default(),
                        row.get::<_, Option<String>>(7)?.unwrap_or_default(),
                        row.get::<_, Option<String>>(8)?.unwrap_or_default(),
                        row.get::<_, Option<String>>(9)?.unwrap_or_default(),
                        row.get::<_, Option<i64>>(10)?.unwrap_or(0) != 0,
                        row.get::<_, Option<i64>>(11)?.unwrap_or(0) != 0,
                    ))
                });
                if let Ok(iter) = rows {
                    for (
                        id,
                        title,
                        preview,
                        steps,
                        lmt,
                        uris,
                        status,
                        row_source,
                        project_id,
                        parent_id,
                        not_fully_idle,
                        killed,
                    ) in iter.flatten()
                    {
                        if !parent_id.trim().is_empty() || row_source == "CORTEX_TRAJECTORY_SOURCE_CLI" {
                            known_skip_ids.insert(id);
                            continue;
                        }
                        if steps == 0
                            && title.trim().is_empty()
                            && preview.trim().is_empty()
                            && lmt.starts_with("0001-")
                        {
                            known_skip_ids.insert(id);
                            continue;
                        }
                        let ws_paths = parse_all_workspace_uris(&uris);
                        let cwd = ws_paths.first().cloned().unwrap_or_default();
                        let sub_cnt = subagent_counts.get(&id).copied().unwrap_or(0);
                        map.insert(
                            id.clone(),
                            RawSummaryRow {
                                id,
                                title,
                                preview,
                                cwd,
                                workspace_paths: ws_paths,
                                step_count: steps,
                                status,
                                project_id,
                                last_modified: lmt,
                                subagent_count: sub_cnt,
                                not_fully_idle,
                                killed,
                            },
                        );
                    }
                }
            }
        }
    }

    if let Ok(entries) = fs::read_dir(paths.conversations_dir()) {
        for e in entries.flatten() {
            let p = e.path();
            if p.extension().and_then(|x| x.to_str()) != Some("db") {
                continue;
            }
            let Some(stem) = p.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if stem.starts_with('.') || map.contains_key(stem) || known_skip_ids.contains(stem) {
                continue;
            }
            if let Some((is_child, cwd, proj_id, steps)) = inspect_unindexed_conv_db_readonly(&p) {
                if is_child || steps == 0 {
                    continue;
                }
                let mt = e
                    .metadata()
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                    .map(|d| crate::quota::format_unix_display(d.as_secs() as i64))
                    .unwrap_or_default();
                map.insert(
                    stem.to_string(),
                    RawSummaryRow {
                        id: stem.to_string(),
                        title: String::new(),
                        preview: String::new(),
                        cwd: cwd.clone(),
                        workspace_paths: if cwd.is_empty() { vec![] } else { vec![cwd] },
                        step_count: steps,
                        status: "CASCADE_RUN_STATUS_IDLE".to_string(),
                        project_id: proj_id,
                        last_modified: mt,
                        subagent_count: 0,
                        not_fully_idle: false,
                        killed: false,
                    },
                );
            }
        }
    }

    map.into_values().collect()
}

fn inspect_unindexed_conv_db_readonly(db_path: &Path) -> Option<(bool, String, String, u32)> {
    let conn = open_sqlite_readonly(db_path).ok()?;
    let steps: i64 = conn
        .query_row("SELECT COUNT(*) FROM steps", [], |r| r.get(0))
        .unwrap_or(0);
    let blob: Vec<u8> = conn
        .query_row("SELECT data FROM trajectory_metadata_blob LIMIT 1", [], |r| {
            r.get(0)
        })
        .unwrap_or_default();
    let mut is_child = false;
    let mut cwd = String::new();
    let mut project_id = String::new();

    for_each_pb_len_field(&blob, |fn_num, payload| {
        if fn_num == 5 && !payload.is_empty() {
            is_child = true;
        } else if fn_num == 7 {
            if let Ok(uri) = std::str::from_utf8(payload) {
                if let Some(p) = file_uri_to_path(uri) {
                    cwd = p;
                }
            }
        } else if fn_num == 18 {
            if let Ok(pid) = std::str::from_utf8(payload) {
                project_id = pid.to_string();
            }
        }
    });
    Some((is_child, cwd, project_id, steps.max(0) as u32))
}

/// Zero-copy SQLite blob read + zero-allocation protobuf streaming extraction.
pub fn parse_conv_db_telemetry(db_path: &Path) -> Option<NativeDbTelemetry> {
    let conn = open_sqlite_readonly(db_path).ok()?;
    let mut out = NativeDbTelemetry::default();

    let mut max_planner_idx: i64 = -1;
    let mut max_checkpoint_idx: i64 = -1;
    if let Ok(mut stmt) =
        conn.prepare("SELECT step_type, COUNT(*), MAX(idx) FROM steps GROUP BY step_type")
    {
        if let Ok(iter) = stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?.max(0) as u32,
                r.get::<_, Option<i64>>(2)?.unwrap_or(-1),
            ))
        }) {
            for (st, cnt, max_idx) in iter.flatten() {
                out.total_steps_in_db = out.total_steps_in_db.saturating_add(cnt);
                match st {
                    14 => out.user_turns = out.user_turns.saturating_add(cnt),
                    15 => {
                        out.assistant_turns = out.assistant_turns.saturating_add(cnt);
                        if max_idx > max_planner_idx {
                            max_planner_idx = max_idx;
                        }
                    }
                    23 => {
                        out.checkpoint_count = out.checkpoint_count.saturating_add(cnt);
                        if max_idx > max_checkpoint_idx {
                            max_checkpoint_idx = max_idx;
                        }
                    }
                    5 | 6 | 7 | 8 | 9 | 13 | 21 | 25 | 31 | 33 | 38 | 47 | 51 | 52 | 60 | 73
                    | 86 | 87 | 92 | 127 | 132 | 136 | 138 | 140 => {
                        out.tool_call_count = out.tool_call_count.saturating_add(cnt);
                    }
                    _ => {}
                }
            }
        }
    }

    // Detect post-compaction state BEFORE next LLM turn has written a fresh gen_metadata row:
    // If the latest CHECKPOINT (step_type = 23) occurred AFTER the latest PLANNER_RESPONSE (step_type = 15),
    // the pre-compaction gen_metadata context is obsolete until the next turn commits.
    if max_checkpoint_idx >= 0 && max_checkpoint_idx > max_planner_idx {
        out.is_compacted_pending_turn = true;
        let payload_bytes: u64 = conn
            .query_row(
                "SELECT COALESCE(LENGTH(step_payload), 0) FROM steps WHERE idx = ?1",
                [max_checkpoint_idx],
                |r| r.get::<_, i64>(0),
            )
            .unwrap_or(0)
            .max(0) as u64;
        // System rules (~12k) + compressed checkpoint summary (~bytes / 3.5), clamped to realistic post-compact band
        let summary_tok = (payload_bytes / 3).max(16_000).min(48_000);
        out.pending_compact_est_tokens = 12_000 + summary_tok;
    }

    let mut seen_models: Vec<String> = Vec::new();
    if let Ok(mut stmt) = conn.prepare("SELECT data FROM gen_metadata ORDER BY idx ASC") {
        if let Ok(mut rows) = stmt.query([]) {
            while let Ok(Some(row)) = rows.next() {
                if let Ok(val_ref) = row.get_ref(0) {
                    if let Ok(blob) = val_ref.as_blob() {
                        if let Some(turn) = parse_gen_metadata_pb(blob) {
                            out.has_gen_metadata = true;
                            out.llm_turns = out.llm_turns.saturating_add(1);
                            out.total_input_tokens =
                                out.total_input_tokens.saturating_add(turn.input_tokens);
                            out.total_cache_read_tokens = out
                                .total_cache_read_tokens
                                .saturating_add(turn.cache_read_tokens);
                            out.total_output_tokens =
                                out.total_output_tokens.saturating_add(turn.output_tokens);
                            out.total_thinking_tokens = out
                                .total_thinking_tokens
                                .saturating_add(turn.thinking_tokens);

                            if turn.input_tokens > 0 || turn.cache_read_tokens > 0 {
                                out.last_input_tokens = turn.input_tokens;
                                out.last_cache_read_tokens = turn.cache_read_tokens;
                                out.last_output_tokens = turn.output_tokens;
                            }
                            if turn.ctx_used_tokens > 0 {
                                out.ctx_used_tokens = turn.ctx_used_tokens;
                            }
                            if turn.ctx_limit_tokens > 0 {
                                out.ctx_limit_tokens = turn.ctx_limit_tokens;
                            }
                            if !turn.model_label.is_empty() {
                                if out.model != turn.model_label {
                                    out.model = turn.model_label.clone();
                                }
                                if !seen_models.iter().any(|m| m == &turn.model_label) {
                                    seen_models.push(turn.model_label);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    out.models_used = seen_models;
    Some(out)
}

#[derive(Debug, Default)]
pub struct ParsedGenTurn {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub thinking_tokens: u64,
    pub ctx_used_tokens: u64,
    pub ctx_limit_tokens: u64,
    pub model_label: String,
}

/// Zero-allocation protobuf wire parser for Antigravity `gen_metadata` rows.
pub fn parse_gen_metadata_pb(buf: &[u8]) -> Option<ParsedGenTurn> {
    let mut turn = ParsedGenTurn::default();
    let mut found_f1 = false;
    let mut model_id_fallback: Option<&str> = None;
    let mut model_label_slice: Option<&str> = None;

    for_each_pb_len_field(buf, |fn_num, payload| {
        if fn_num != 1 {
            return;
        }
        found_f1 = true;
        for_each_pb_len_field(payload, |sfn, spayload| match sfn {
            4 => {
                for_each_pb_varint(spayload, |ufn, uval| match ufn {
                    2 => turn.input_tokens = uval,
                    3 => turn.output_tokens = uval,
                    5 => turn.cache_read_tokens = uval,
                    9 => turn.thinking_tokens = uval,
                    _ => {}
                });
            }
            9 => {
                for_each_pb_len_field(spayload, |cfn, cpayload| {
                    if cfn == 10 {
                        for_each_pb_varint(cpayload, |kfn, kval| match kfn {
                            1 => turn.ctx_used_tokens = kval,
                            4 => turn.ctx_limit_tokens = kval,
                            _ => {}
                        });
                    }
                });
            }
            19 => {
                if let Ok(s) = std::str::from_utf8(spayload) {
                    let t = s.trim();
                    if !t.is_empty() {
                        model_id_fallback = Some(t);
                    }
                }
            }
            21 => {
                if let Ok(s) = std::str::from_utf8(spayload) {
                    let t = s.trim();
                    if !t.is_empty() {
                        model_label_slice = Some(t);
                    }
                }
            }
            _ => {}
        });
    });

    if !found_f1 {
        return None;
    }
    if let Some(lbl) = model_label_slice {
        turn.model_label = lbl.to_string();
    } else if let Some(raw_id) = model_id_fallback {
        turn.model_label = format_model_name(raw_id);
    }
    if turn.input_tokens == 0
        && turn.cache_read_tokens == 0
        && turn.output_tokens == 0
        && turn.ctx_used_tokens == 0
        && turn.model_label.is_empty()
    {
        return None;
    }
    Some(turn)
}

#[inline]
fn decode_varint(buf: &[u8], mut pos: usize) -> Option<(u64, usize)> {
    let mut val = 0u64;
    let mut shift = 0u32;
    while pos < buf.len() && shift < 64 {
        let b = unsafe { *buf.get_unchecked(pos) };
        pos += 1;
        val |= ((b & 0x7F) as u64) << shift;
        if (b & 0x80) == 0 {
            return Some((val, pos));
        }
        shift += 7;
    }
    None
}

#[inline]
fn for_each_pb_len_field<'a, F>(buf: &'a [u8], mut f: F)
where
    F: FnMut(u32, &'a [u8]),
{
    let mut pos = 0usize;
    let len_total = buf.len();
    while pos < len_total {
        let Some((tag, next)) = decode_varint(buf, pos) else {
            break;
        };
        pos = next;
        let fn_num = (tag >> 3) as u32;
        match (tag & 7) as u8 {
            0 => {
                let Some((_, np)) = decode_varint(buf, pos) else {
                    break;
                };
                pos = np;
            }
            1 => {
                if pos + 8 > len_total {
                    break;
                }
                pos += 8;
            }
            2 => {
                let Some((slen, start)) = decode_varint(buf, pos) else {
                    break;
                };
                let end = start.saturating_add(slen as usize);
                if end > len_total {
                    break;
                }
                f(fn_num, &buf[start..end]);
                pos = end;
            }
            5 => {
                if pos + 4 > len_total {
                    break;
                }
                pos += 4;
            }
            _ => break,
        }
    }
}

#[inline]
fn for_each_pb_varint<F>(buf: &[u8], mut f: F)
where
    F: FnMut(u32, u64),
{
    let mut pos = 0usize;
    let len_total = buf.len();
    while pos < len_total {
        let Some((tag, next)) = decode_varint(buf, pos) else {
            break;
        };
        pos = next;
        let fn_num = (tag >> 3) as u32;
        match (tag & 7) as u8 {
            0 => {
                let Some((val, np)) = decode_varint(buf, pos) else {
                    break;
                };
                f(fn_num, val);
                pos = np;
            }
            1 => {
                if pos + 8 > len_total {
                    break;
                }
                pos += 8;
            }
            2 => {
                let Some((slen, start)) = decode_varint(buf, pos) else {
                    break;
                };
                let end = start.saturating_add(slen as usize);
                if end > len_total {
                    break;
                }
                pos = end;
            }
            5 => {
                if pos + 4 > len_total {
                    break;
                }
                pos += 4;
            }
            _ => break,
        }
    }
}

#[derive(Deserialize)]
struct RawToolCall<'a> {
    #[serde(borrow)]
    name: Option<Cow<'a, str>>,
}

/// Dedicated minimal struct for `USER_INPUT` lines (only ~2% of transcript lines).
#[derive(Deserialize)]
struct RawUserInputLine<'a> {
    #[serde(borrow)]
    created_at: Option<&'a str>,
    #[serde(borrow)]
    content: Option<Cow<'a, str>>,
}

/// Dedicated minimal struct for `PLANNER_RESPONSE` lines — deliberately OMITS `content` / `thinking`
/// so serde_json skips megabytes of escaped markdown responses without unescaping or allocating!
#[derive(Deserialize)]
struct RawPlannerLine<'a> {
    #[serde(borrow)]
    created_at: Option<&'a str>,
    #[serde(borrow)]
    model: Option<&'a str>,
    input_tokens: Option<u64>,
    cache_read_tokens: Option<u64>,
    output_tokens: Option<u64>,
    #[serde(borrow)]
    tool_calls: Option<Vec<RawToolCall<'a>>>,
}

/// High-speed typed & byte-pre-filtered transcript parser:
/// - Reusable line buffer with 64KB BufReader (zero per-line String alloc)
/// - Skips ~70% of lines / ~85% of bytes (`GENERIC`, `SYSTEM_MESSAGE`, `ERROR_MESSAGE`) before JSON parsing
/// - Splits `PLANNER_RESPONSE` (no `content` field!) from `USER_INPUT` so giant markdown responses
///   are never unescaped or allocated on the heap!
fn parse_transcript_full(path: &Path) -> TranscriptSupplement {
    let Ok(file) = File::open(path) else {
        return TranscriptSupplement::default();
    };
    let mut reader = BufReader::with_capacity(64 * 1024, file);
    let mut supp = TranscriptSupplement::default();
    let mut tool_counts: HashMap<String, u32> = HashMap::new();
    let mut line = String::with_capacity(4096);
    let mut line_index = 0usize;

    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => break,
        }
        line_index += 1;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        // Fast branch on exact JSON type substring (avoids full JSON parse on ~70% of lines)
        if trimmed.contains("\"type\":\"PLANNER_RESPONSE\"")
            || trimmed.contains("\"type\": \"PLANNER_RESPONSE\"")
        {
            let Ok(rec) = serde_json::from_str::<RawPlannerLine>(trimmed) else {
                continue;
            };
            supp.has_data = true;
            if supp.created_at.is_empty() {
                if let Some(ts) = rec.created_at {
                    supp.created_at = format_display_timestamp(ts);
                }
            }
            supp.assistant_turns += 1;
            if let Some(m) = rec.model {
                if !m.trim().is_empty() {
                    let formatted = format_model_name(m);
                    if supp.model != formatted {
                        supp.model = formatted.clone();
                    }
                    if !supp.models_used.iter().any(|x| x == &formatted) {
                        supp.models_used.push(formatted);
                    }
                }
            }
            let inp = rec.input_tokens.unwrap_or(0);
            let cache = rec.cache_read_tokens.unwrap_or(0);
            let out = rec.output_tokens.unwrap_or(0);
            supp.total_input_tokens = supp.total_input_tokens.saturating_add(inp);
            supp.total_cache_read_tokens = supp.total_cache_read_tokens.saturating_add(cache);
            supp.total_output_tokens = supp.total_output_tokens.saturating_add(out);
            if inp + cache > 0 {
                supp.ctx_used_tokens = inp + cache;
                supp.last_input_tokens = inp;
                supp.last_cache_read_tokens = cache;
                supp.last_output_tokens = out;
            }
            if let Some(calls) = rec.tool_calls {
                supp.tool_call_count = supp.tool_call_count.saturating_add(calls.len() as u32);
                for call in calls {
                    if let Some(name) = call.name {
                        if let Some(cnt) = tool_counts.get_mut(name.as_ref()) {
                            *cnt += 1;
                        } else {
                            tool_counts.insert(name.into_owned(), 1);
                        }
                    }
                }
            }
        } else if trimmed.contains("\"type\":\"USER_INPUT\"")
            || trimmed.contains("\"type\": \"USER_INPUT\"")
        {
            let Ok(rec) = serde_json::from_str::<RawUserInputLine>(trimmed) else {
                continue;
            };
            supp.has_data = true;
            if supp.created_at.is_empty() {
                if let Some(ts) = rec.created_at {
                    supp.created_at = format_display_timestamp(ts);
                }
            }
            supp.user_turns += 1;
            if let Some(c) = rec.content.as_deref() {
                let s = clean_snippet(c, 180);
                if !s.is_empty() {
                    supp.last_user_prompt = s;
                }
            }
        } else if trimmed.contains("\"type\":\"CHECKPOINT\"")
            || trimmed.contains("\"type\": \"CHECKPOINT\"")
        {
            supp.has_data = true;
            supp.checkpoint_count += 1;
        } else if line_index == 1 && supp.created_at.is_empty() {
            if let Some(pos) = trimmed.find("\"created_at\"") {
                let rest = &trimmed[pos + "\"created_at\"".len()..];
                if let Some(q1) = rest.find('"') {
                    let after = &rest[q1 + 1..];
                    if let Some(q2) = after.find('"') {
                        supp.created_at = format_display_timestamp(&after[..q2]);
                    }
                }
            }
        }
    }

    let mut top: Vec<ToolUsageStat> = tool_counts
        .into_iter()
        .map(|(name, count)| ToolUsageStat { name, count })
        .collect();
    top.sort_by(|a, b| b.count.cmp(&a.count).then_with(|| a.name.cmp(&b.name)));
    top.truncate(6);
    supp.top_tools = top;
    supp
}

fn parse_pbtxt_quoted_str(rest: &str) -> Option<(String, usize)> {
    let trimmed = rest.trim_start();
    let leading_ws = rest.len() - trimmed.len();
    if !trimmed.starts_with('"') {
        return None;
    }
    let bytes = trimmed.as_bytes();
    let mut end = 1usize;
    let mut escaped = false;
    while end < bytes.len() {
        if escaped {
            escaped = false;
        } else if bytes[end] == b'\\' {
            escaped = true;
        } else if bytes[end] == b'"' {
            end += 1;
            break;
        }
        end += 1;
    }
    if let Ok(Value::String(s)) = serde_json::from_str::<Value>(&trimmed[..end]) {
        return Some((s, leading_ws + end));
    }
    None
}

pub fn parse_annotation_pbtxt(content: &str) -> ParsedAnnotation {
    let mut ann = ParsedAnnotation::default();
    ann.pinned = content.contains("pinned:true") || content.contains("pinned: true");
    ann.archived = content.contains("archived:true") || content.contains("archived: true");
    ann.starred = content.contains("starred:true") || content.contains("starred: true");

    if let Some(idx) = content.find("title:") {
        if let Some((s, _)) = parse_pbtxt_quoted_str(&content[idx + "title:".len()..]) {
            if !s.trim().is_empty() {
                ann.title = Some(s.trim().to_string());
            }
        }
    }

    // Repeated v2.35.0 `tags: "..."` fields in protobuf text format
    let mut cursor = content;
    while let Some(idx) = cursor.find("tags:") {
        let after = &cursor[idx + "tags:".len()..];
        if let Some((tag, consumed)) = parse_pbtxt_quoted_str(after) {
            let clean = tag.trim();
            if !clean.is_empty() && !ann.tags.iter().any(|t| t == clean) {
                ann.tags.push(clean.to_string());
            }
            cursor = &after[consumed..];
        } else {
            cursor = after;
        }
    }
    ann
}

fn read_annotation_readonly(paths: &CorePaths, session_id: &str) -> ParsedAnnotation {
    let p = paths
        .annotations_dir()
        .join(format!("{}.pbtxt", session_id));
    let Ok(content) = fs::read_to_string(&p) else {
        return ParsedAnnotation::default();
    };
    parse_annotation_pbtxt(&content)
}

fn inspect_session_lock_readonly(paths: &CorePaths, session_id: &str) -> (bool, u64) {
    let lock_path = paths.presence_dir().join(format!("{}.lock", session_id));
    let Ok(meta) = fs::metadata(&lock_path) else {
        return (false, 0);
    };
    let mtime_ns = file_mtime_ns(&meta);
    let Ok(file) = File::open(&lock_path) else {
        return (false, mtime_ns);
    };
    let fd = file.as_raw_fd();
    let rc = unsafe { flock(fd, LOCK_SH | LOCK_NB) };
    if rc == 0 {
        unsafe {
            flock(fd, LOCK_UN);
        }
        (false, mtime_ns)
    } else {
        (true, mtime_ns)
    }
}

fn list_brain_artifacts_readonly(paths: &CorePaths, session_id: &str) -> Vec<String> {
    let dir = paths.brain_dir().join(session_id);
    let Ok(entries) = fs::read_dir(&dir) else {
        return vec![];
    };
    let mut files: Vec<String> = entries
        .flatten()
        .filter_map(|e| {
            let ft = e.file_type().ok()?;
            if !ft.is_file() {
                return None;
            }
            let name = e.file_name().to_str()?.to_string();
            if name.starts_with('.') || name.ends_with(".metadata.json") || name.contains(".resolved")
            {
                return None;
            }
            Some(name)
        })
        .collect();
    files.sort();
    files.truncate(8);
    files
}

fn detect_workspace_rule_files(cwd: &Path) -> Vec<String> {
    let candidates = [
        "GEMINI.md",
        "AGENTS.md",
        "CLAUDE.md",
        ".gemini/rules.md",
        ".cursorrules",
    ];
    candidates
        .iter()
        .filter(|rel| cwd.join(rel).is_file())
        .map(|s| s.to_string())
        .collect()
}

fn read_git_branch_readonly(cwd: &Path) -> String {
    let mut cur = Some(cwd);
    for _ in 0..4 {
        let Some(dir) = cur else { break };
        let head = dir.join(".git").join("HEAD");
        if head.is_file() {
            if let Ok(content) = fs::read_to_string(&head) {
                let line = content.trim();
                if let Some(branch) = line.strip_prefix("ref: refs/heads/") {
                    return branch.to_string();
                }
                if line.len() >= 7 {
                    return line[..7].to_string();
                }
            }
        }
        cur = dir.parent();
    }
    "-".to_string()
}

fn parse_all_workspace_uris(raw: &str) -> Vec<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return vec![];
    }
    if let Ok(Value::Array(items)) = serde_json::from_str::<Value>(trimmed) {
        let mut out = Vec::new();
        for item in items {
            if let Some(uri) = item.as_str() {
                if let Some(path) = file_uri_to_path(uri) {
                    let norm = path.trim_end_matches('/').to_string();
                    if !norm.is_empty() && !out.contains(&norm) {
                        out.push(norm);
                    }
                }
            }
        }
        return out;
    }
    file_uri_to_path(trimmed)
        .map(|p| vec![p.trim_end_matches('/').to_string()])
        .unwrap_or_default()
}

pub fn file_uri_to_path(uri: &str) -> Option<String> {
    let s = uri.trim();
    if s.is_empty() {
        return None;
    }
    let stripped = if let Some(rest) = s.strip_prefix("file://localhost") {
        rest
    } else if let Some(rest) = s.strip_prefix("file://") {
        rest
    } else if s.starts_with('/') {
        s
    } else {
        return None;
    };
    Some(percent_decode_utf8(stripped))
}

fn percent_decode_utf8(input: &str) -> String {
    if !input.as_bytes().contains(&b'%') {
        return input.to_string();
    }
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                out.push((hi << 4) | lo);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

#[inline]
fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn default_context_limit_tokens(model: &str) -> u64 {
    let m = model.to_lowercase();
    if m.contains("claude") {
        200_000
    } else if m.contains("gpt") {
        128_000
    } else {
        512_000
    }
}

fn estimate_reference_cost_usd(
    model: &str,
    input_tokens: u64,
    cache_read_tokens: u64,
    output_tokens: u64,
) -> f64 {
    let m = model.to_lowercase();
    let (in_rate, cache_rate, out_rate) = if m.contains("flash") {
        (0.30, 0.03, 2.50)
    } else if m.contains("claude") {
        (3.00, 0.30, 15.00)
    } else {
        (1.25, 0.125, 10.00)
    };
    let raw = (input_tokens as f64 * in_rate
        + cache_read_tokens as f64 * cache_rate
        + output_tokens as f64 * out_rate)
        / 1_000_000.0;
    (raw * 100.0).round() / 100.0
}

fn cached_home_prefix() -> &'static str {
    static PREFIX: OnceLock<String> = OnceLock::new();
    PREFIX
        .get_or_init(|| {
            home_dir()
                .to_string_lossy()
                .trim_end_matches('/')
                .to_string()
        })
        .as_str()
}

fn shorten_home_path(path: &str) -> String {
    if path.is_empty() {
        return "~".to_string();
    }
    let home = cached_home_prefix();
    if path == home {
        "~".to_string()
    } else if let Some(rest) = path.strip_prefix(home).and_then(|r| r.strip_prefix('/')) {
        format!("~/{}", rest)
    } else {
        path.to_string()
    }
}

fn normalize_status(raw: &str, is_live_active: bool) -> String {
    if is_live_active || raw.contains("RUNNING") {
        "运行中".to_string()
    } else if raw.contains("WAITING") {
        "等待确认".to_string()
    } else {
        "空闲".to_string()
    }
}

fn format_display_timestamp(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let mut out = String::with_capacity(16);
    for ch in trimmed.chars().take(16) {
        out.push(if ch == 'T' { ' ' } else { ch });
    }
    out
}

fn clean_snippet(raw: &str, max_chars: usize) -> String {
    let mut s = raw.trim();
    if let Some(start) = s.find("<USER_REQUEST>") {
        let after = &s[start + "<USER_REQUEST>".len()..];
        s = after.split("</USER_REQUEST>").next().unwrap_or(after).trim();
    }
    let mut out = String::with_capacity(max_chars.min(s.len()) + 3);
    let mut count = 0usize;
    let mut in_ws = false;
    let mut truncated = false;
    for ch in s.chars() {
        if ch.is_whitespace() {
            if !in_ws && count > 0 {
                if count >= max_chars {
                    truncated = true;
                    break;
                }
                out.push(' ');
                count += 1;
                in_ws = true;
            }
        } else {
            if count >= max_chars {
                truncated = true;
                break;
            }
            out.push(ch);
            count += 1;
            in_ws = false;
        }
    }
    if truncated {
        out.push_str("...");
    }
    out
}

fn format_model_name(raw: &str) -> String {
    match raw.trim() {
        "gemini-4-neon-xhigh" => "Gemini 4 Neon (XHigh)".to_string(),
        "gemini-4-neon-high" => "Gemini 4 Neon (High)".to_string(),
        "gemini-4-neon-medium" => "Gemini 4 Neon (Medium)".to_string(),
        "gemini-4-neon-low" => "Gemini 4 Neon (Low)".to_string(),
        "gemini-4-neon" => "Gemini 4 Neon".to_string(),
        "gemini-4-argon-high" => "Gemini 4 Argon (High)".to_string(),
        "gemini-4-argon-medium" => "Gemini 4 Argon (Medium)".to_string(),
        "gemini-4-argon-low" => "Gemini 4 Argon (Low)".to_string(),
        "gemini-4-argon" => "Gemini 4 Argon".to_string(),
        "gemini-4-hydrogen-xhigh" => "Gemini 4 Hydrogen (XHigh)".to_string(),
        "gemini-4-hydrogen-high" => "Gemini 4 Hydrogen (High)".to_string(),
        "gemini-4-hydrogen-medium" => "Gemini 4 Hydrogen (Medium)".to_string(),
        "gemini-4-hydrogen-low" => "Gemini 4 Hydrogen (Low)".to_string(),
        "gemini-3.8-flash-high" => "Gemini 3.8 Flash (High)".to_string(),
        "gemini-3.8-flash-medium" => "Gemini 3.8 Flash (Medium)".to_string(),
        "gemini-3.8-flash-low" => "Gemini 3.8 Flash (Low)".to_string(),
        "claude-opus-5-5-high" => "Claude Opus 5.5 (High)".to_string(),
        "claude-opus-5-5-medium" => "Claude Opus 5.5 (Medium)".to_string(),
        "claude-sonnet-5-5-high" => "Claude Sonnet 5.5 (High)".to_string(),
        "gpt-oss-120b-medium" => "GPT-OSS 120B (Medium)".to_string(),
        other => other.to_string(),
    }
}
