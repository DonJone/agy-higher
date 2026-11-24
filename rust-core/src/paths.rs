use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// Default sandbox root inside the repository used during development and tests.
pub const DEFAULT_SANDBOX_ROOT: &str = "/Users/don/git/agy-higher/.dev-sandbox";

#[derive(Debug, Clone)]
pub struct CorePaths {
    /// Antigravity Desktop Hub data dir (`~/.gemini/antigravity`) — strictly READ-ONLY.
    pub antigravity_dir: PathBuf,
    /// Native Antigravity projects dir (`~/.gemini/config/projects`) — strictly READ-ONLY.
    pub gemini_projects_dir: PathBuf,
    /// Antigravity Desktop storage (`~/Library/Application Support/Antigravity/app_storage.json`) — READ-ONLY.
    pub app_storage_path: PathBuf,
    /// Antigravity Desktop language_server log (`~/Library/Logs/Antigravity/language_server.log`) — READ-ONLY.
    pub desktop_ls_log_path: PathBuf,
    /// Dedicated writable config/cache dir for agy-higher (`~/.config/agy-higher`).
    pub config_dir: PathBuf,
    pub sandbox_mode: bool,
    pub sandbox_root: Option<PathBuf>,
}

impl CorePaths {
    pub fn resolve(sandbox_mode: bool, sandbox_root_override: Option<&str>) -> Self {
        let env_sandbox = env::var("AGY_HIGHER_SANDBOX")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);

        let effective_sandbox = cfg!(test) || sandbox_mode || env_sandbox;

        if effective_sandbox {
            let sb_root = sandbox_root_override
                .map(PathBuf::from)
                .or_else(|| env::var("AGY_HIGHER_SANDBOX_DIR").ok().map(PathBuf::from))
                .unwrap_or_else(|| PathBuf::from(DEFAULT_SANDBOX_ROOT));

            Self {
                antigravity_dir: sb_root.join("v3").join("antigravity"),
                gemini_projects_dir: sb_root.join("v3").join("config").join("projects"),
                app_storage_path: sb_root.join("v3").join("app_storage.json"),
                desktop_ls_log_path: sb_root.join("v3").join("language_server.log"),
                config_dir: sb_root.join("v3").join("agy-higher-config"),
                sandbox_mode: true,
                sandbox_root: Some(sb_root),
            }
        } else {
            let home = home_dir();
            Self {
                antigravity_dir: home.join(".gemini").join("antigravity"),
                gemini_projects_dir: home.join(".gemini").join("config").join("projects"),
                app_storage_path: home
                    .join("Library")
                    .join("Application Support")
                    .join("Antigravity")
                    .join("app_storage.json"),
                desktop_ls_log_path: home
                    .join("Library")
                    .join("Logs")
                    .join("Antigravity")
                    .join("language_server.log"),
                config_dir: home.join(".config").join("agy-higher"),
                sandbox_mode: false,
                sandbox_root: None,
            }
        }
    }

    pub fn config_json_path(&self) -> PathBuf {
        self.config_dir.join("config.json")
    }

    pub fn accounts_json_path(&self) -> PathBuf {
        self.config_dir.join("accounts.json")
    }

    pub fn quota_cache_path(&self) -> PathBuf {
        self.config_dir.join("quota-cache.json")
    }

    pub fn telemetry_cache_path(&self) -> PathBuf {
        self.config_dir.join("telemetry-cache.json")
    }

    pub fn l10n_dir(&self) -> PathBuf {
        self.config_dir.join("l10n")
    }

    pub fn l10n_overlay_path(&self) -> PathBuf {
        self.l10n_dir().join("antigravity-stc-overlay.js")
    }

    pub fn l10n_manifest_path(&self) -> PathBuf {
        self.l10n_dir().join("manifest.json")
    }

    pub fn custom_translations_path(&self) -> PathBuf {
        self.config_dir.join("custom-translations.txt")
    }

    pub fn repo_l10n_dir(&self) -> PathBuf {
        if let Ok(env_dir) = env::var("AGY_HIGHER_L10N_DIR") {
            let p = PathBuf::from(env_dir);
            if p.is_dir() {
                return p;
            }
        }
        // Prefer bundled Resources/l10n inside AgyHigher.app for standalone DMG installs
        if let Ok(exe) = env::current_exe() {
            if let Some(res_l10n) = exe
                .parent()
                .and_then(|macos| macos.parent())
                .map(|contents| contents.join("Resources").join("l10n"))
            {
                if res_l10n.is_dir() {
                    return res_l10n;
                }
            }
        }
        let manifest_l10n = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .map(|p| p.join("l10n"))
            .unwrap_or_else(|| PathBuf::from("/Users/don/git/agy-higher/l10n"));
        if manifest_l10n.is_dir() {
            return manifest_l10n;
        }
        PathBuf::from("/Users/don/git/agy-higher/l10n")
    }

    pub fn summaries_db_path(&self) -> PathBuf {
        self.antigravity_dir.join("conversation_summaries.db")
    }

    pub fn conversations_dir(&self) -> PathBuf {
        self.antigravity_dir.join("conversations")
    }

    pub fn brain_dir(&self) -> PathBuf {
        self.antigravity_dir.join("brain")
    }

    pub fn annotations_dir(&self) -> PathBuf {
        self.antigravity_dir.join("annotations")
    }

    pub fn presence_dir(&self) -> PathBuf {
        self.antigravity_dir.join("presence")
    }

    /// Strict safety guard: agy-higher is 100% READ-ONLY against ~/.gemini and Antigravity.app.
    pub fn assert_safe_write_target(&self, target: &Path) -> Result<(), String> {
        if !target.starts_with(&self.config_dir) {
            return Err(format!(
                "Safety violation blocked: attempted write outside agy-higher config dir ({:?}): {:?}",
                self.config_dir, target
            ));
        }
        let live_gemini = home_dir().join(".gemini");
        if target.starts_with(&live_gemini) {
            return Err(format!(
                "Safety violation blocked: ~/.gemini is strictly read-only: {:?}",
                target
            ));
        }
        if (cfg!(test) || self.sandbox_mode) && self.sandbox_root.is_some() {
            let sb = self.sandbox_root.as_ref().unwrap();
            if !target.starts_with(sb) {
                return Err(format!(
                    "Safety violation blocked: write target {:?} escapes sandbox {:?}",
                    target, sb
                ));
            }
        }
        Ok(())
    }

    /// Seed realistic Antigravity Desktop fixtures strictly inside `.dev-sandbox/v3/`.
    pub fn ensure_sandbox_seeded(&self) -> Result<(), String> {
        if !self.sandbox_mode {
            return Ok(());
        }
        fs::create_dir_all(&self.antigravity_dir).map_err(|e| e.to_string())?;
        fs::create_dir_all(&self.gemini_projects_dir).map_err(|e| e.to_string())?;
        fs::create_dir_all(&self.config_dir).map_err(|e| e.to_string())?;

        let projects = [
            ("a1b2c3d4-1002-4a00-8002-000000000002", "Donby", Some("/Users/don/git/Donby")),
            ("a1b2c3d4-1001-4a00-8001-000000000001", "agy-higher", Some("/Users/don/git/agy-higher")),
            ("2e1b9011-7e3c-42f9-9312-4e013a7886c0", "work", Some("/Users/don/work")),
            ("c032a419-5393-474e-ad55-d75345bc2456", "学习与作业", Some("/Users/don/Documents")),
        ];
        for (pid, name, path_opt) in &projects {
            let pfile = self.gemini_projects_dir.join(format!("{}.json", pid));
            if !pfile.exists() {
                let payload = if let Some(path) = path_opt {
                    serde_json::json!({
                        "id": pid,
                        "name": name,
                        "projectResources": { "resources": [{ "folderUri": format!("file://{}", path) }] }
                    })
                } else {
                    serde_json::json!({ "id": pid, "name": name, "projectResources": {} })
                };
                fs::write(&pfile, serde_json::to_string_pretty(&payload).unwrap())
                    .map_err(|e| e.to_string())?;
            }
        }

        if !self.app_storage_path.exists() {
            let order: Vec<&str> = projects.iter().map(|p| p.0).collect();
            let storage = serde_json::json!({
                "agy.onboarding.lastLoginUsername": "ananmagoro701@gmail.com",
                "projectsOrder": serde_json::to_string(&order).unwrap()
            });
            fs::write(&self.app_storage_path, serde_json::to_string_pretty(&storage).unwrap())
                .map_err(|e| e.to_string())?;
        }

        if !self.summaries_db_path().exists() {
            seed_sandbox_antigravity(&self.antigravity_dir)?;
        }

        Ok(())
    }
}

pub fn home_dir() -> PathBuf {
    static CACHED_HOME: OnceLock<PathBuf> = OnceLock::new();
    CACHED_HOME
        .get_or_init(|| {
            env::var("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from("/Users/don"))
        })
        .clone()
}

fn encode_varint(mut v: u64, out: &mut Vec<u8>) {
    loop {
        let mut b = (v & 0x7F) as u8;
        v >>= 7;
        if v != 0 {
            b |= 0x80;
            out.push(b);
        } else {
            out.push(b);
            break;
        }
    }
}

fn pb_varint(field: u32, v: u64, out: &mut Vec<u8>) {
    encode_varint(((field as u64) << 3) | 0, out);
    encode_varint(v, out);
}

fn pb_bytes(field: u32, data: &[u8], out: &mut Vec<u8>) {
    encode_varint(((field as u64) << 3) | 2, out);
    encode_varint(data.len() as u64, out);
    out.extend_from_slice(data);
}

pub fn build_sandbox_gen_metadata_pb(
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    thinking_tokens: u64,
    ctx_used_tokens: u64,
    ctx_limit_tokens: u64,
    model_label: &str,
) -> Vec<u8> {
    let mut f4 = Vec::new();
    pb_varint(2, input_tokens, &mut f4);
    pb_varint(3, output_tokens, &mut f4);
    pb_varint(5, cache_read_tokens, &mut f4);
    pb_varint(9, thinking_tokens, &mut f4);
    pb_varint(10, output_tokens.saturating_sub(thinking_tokens), &mut f4);

    let mut f10 = Vec::new();
    pb_varint(1, ctx_used_tokens, &mut f10);
    pb_varint(4, ctx_limit_tokens, &mut f10);
    let mut f9 = Vec::new();
    pb_bytes(10, &f10, &mut f9);

    let mut f1 = Vec::new();
    pb_bytes(4, &f4, &mut f1);
    pb_bytes(9, &f9, &mut f1);
    pb_bytes(21, model_label.as_bytes(), &mut f1);

    let mut root = Vec::new();
    pb_bytes(1, &f1, &mut root);
    root
}

fn seed_sandbox_antigravity(root: &Path) -> Result<(), String> {
    let db_path = root.join("conversation_summaries.db");
    let conv_dir = root.join("conversations");
    let ann_dir = root.join("annotations");
    let brain_dir = root.join("brain");
    fs::create_dir_all(&conv_dir).map_err(|e| e.to_string())?;
    fs::create_dir_all(&ann_dir).map_err(|e| e.to_string())?;
    fs::create_dir_all(&brain_dir).map_err(|e| e.to_string())?;

    let conn = rusqlite::Connection::open(&db_path).map_err(|e| e.to_string())?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            preview TEXT NOT NULL DEFAULT '',
            step_count INTEGER NOT NULL DEFAULT 0,
            last_modified_time DATETIME NOT NULL,
            workspace_uris TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT '',
            project_id TEXT NOT NULL DEFAULT '',
            agent_name TEXT NOT NULL DEFAULT '',
            parent_conversation_id TEXT NOT NULL DEFAULT '',
            nesting_depth INTEGER NOT NULL DEFAULT 0,
            not_fully_idle NUMERIC NOT NULL DEFAULT false,
            killed NUMERIC NOT NULL DEFAULT false,
            last_user_input_time DATETIME NOT NULL DEFAULT '',
            last_user_input_step_index INTEGER NOT NULL DEFAULT -1,
            app_data_dir TEXT NOT NULL DEFAULT '',
            group_id TEXT NOT NULL DEFAULT ''
        );",
    )
    .map_err(|e| e.to_string())?;

    struct Seed<'a> {
        id: &'a str,
        project_id: &'a str,
        cwd: &'a str,
        title: &'a str,
        preview: &'a str,
        steps: i64,
        ts: &'a str,
        status: &'a str,
        pinned: bool,
        model: &'a str,
        turns: usize,
        ctx_used: u64,
        ctx_limit: u64,
        cache_tok: u64,
        in_tok: u64,
        out_tok: u64,
        think_tok: u64,
        checkpoints: usize,
    }

    let rows = vec![
        Seed {
            id: "db17f36d-3b3d-5e57-92da-75713ee65f8a",
            project_id: "a1b2c3d4-1002-4a00-8002-000000000002",
            cwd: "/Users/don/git/Donby",
            title: "Donby Agent Session Handover",
            preview: "接手 Donby 核心渲染与内核解码多会话上下文并核对回归测试",
            steps: 97,
            ts: "2026-11-23 06:11:00+00:00",
            status: "CASCADE_RUN_STATUS_RUNNING",
            pinned: false,
            model: "Gemini 4 Neon (XHigh)",
            turns: 26,
            ctx_used: 192_643,
            ctx_limit: 512_000,
            cache_tok: 189_462,
            in_tok: 2_481,
            out_tok: 680,
            think_tok: 420,
            checkpoints: 1,
        },
        Seed {
            id: "856cfb36-4d80-57b8-9e5d-e92742734f7f",
            project_id: "a1b2c3d4-1002-4a00-8002-000000000002",
            cwd: "/Users/don/git/Donby",
            title: "donbyeg2",
            preview: "Donby 渲染引擎管线优化与 C++/Rust 桥接长期会话",
            steps: 6530,
            ts: "2026-11-22 20:17:00+00:00",
            status: "CASCADE_RUN_STATUS_IDLE",
            pinned: true,
            model: "Gemini 4 Neon (High)",
            turns: 42,
            ctx_used: 348_200,
            ctx_limit: 512_000,
            cache_tok: 331_400,
            in_tok: 4_820,
            out_tok: 1_190,
            think_tok: 640,
            checkpoints: 4,
        },
        Seed {
            id: "cfb0c167-0491-5c9e-bfb9-134354642fd4",
            project_id: "a1b2c3d4-1002-4a00-8002-000000000002",
            cwd: "/Users/don/git/Donby",
            title: "donbyeng",
            preview: "Donby 工程脚手架与跨平台打包验证",
            steps: 1644,
            ts: "2026-11-21 14:48:00+00:00",
            status: "CASCADE_RUN_STATUS_IDLE",
            pinned: true,
            model: "Gemini 4 Argon (High)",
            turns: 18,
            ctx_used: 124_800,
            ctx_limit: 512_000,
            cache_tok: 112_000,
            in_tok: 3_100,
            out_tok: 820,
            think_tok: 310,
            checkpoints: 2,
        },
        Seed {
            id: "agy-desktop-01",
            project_id: "a1b2c3d4-1001-4a00-8001-000000000001",
            cwd: "/Users/don/git/agy-higher",
            title: "Antigravity 上下文与额度面板",
            preview: "聚焦 Antigravity 原生上下文遥测与实时额度监控",
            steps: 142,
            ts: "2026-11-23 06:28:00+00:00",
            status: "CASCADE_RUN_STATUS_IDLE",
            pinned: false,
            model: "Gemini 4 Neon (XHigh)",
            turns: 16,
            ctx_used: 158_400,
            ctx_limit: 512_000,
            cache_tok: 146_200,
            in_tok: 3_850,
            out_tok: 940,
            think_tok: 520,
            checkpoints: 1,
        },
    ];

    for s in rows {
        let uris = serde_json::json!([format!("file://{}", s.cwd)]).to_string();
        conn.execute(
            "INSERT OR REPLACE INTO conversation_summaries
             (conversation_id, title, preview, step_count, last_modified_time, workspace_uris, status, source, project_id, last_user_input_time)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, '', ?8, ?5)",
            rusqlite::params![s.id, s.title, s.preview, s.steps, s.ts, uris, s.status, s.project_id],
        )
        .map_err(|e| e.to_string())?;

        if s.id == "db17f36d-3b3d-5e57-92da-75713ee65f8a" {
            for idx in 1..=3 {
                conn.execute(
                    "INSERT OR REPLACE INTO conversation_summaries
                     (conversation_id, title, preview, step_count, last_modified_time, workspace_uris, status, source, project_id, parent_conversation_id, nesting_depth, last_user_input_time)
                     VALUES (?1, '', '', 40, ?2, ?3, 'CASCADE_RUN_STATUS_IDLE', '', ?4, ?5, 1, ?2)",
                    rusqlite::params![format!("sub-donby-{}", idx), s.ts, uris, s.project_id, s.id],
                )
                .map_err(|e| e.to_string())?;
            }
        }

        let ann = if s.id == "db17f36d-3b3d-5e57-92da-75713ee65f8a" {
            format!(
                "title:{}\nstarred:true\ntags:\"core\"\ntags:\"v2.35\"\n",
                serde_json::to_string(s.title).unwrap()
            )
        } else if s.pinned {
            format!("title:{}\npinned:true\n", serde_json::to_string(s.title).unwrap())
        } else {
            format!("title:{}\n", serde_json::to_string(s.title).unwrap())
        };
        fs::write(ann_dir.join(format!("{}.pbtxt", s.id)), ann).map_err(|e| e.to_string())?;

        let cdb = rusqlite::Connection::open(conv_dir.join(format!("{}.db", s.id)))
            .map_err(|e| e.to_string())?;
        cdb.execute_batch(
            "CREATE TABLE IF NOT EXISTS trajectory_meta (trajectory_id TEXT PRIMARY KEY, cascade_id TEXT, trajectory_type INTEGER, source INTEGER);
             CREATE TABLE IF NOT EXISTS steps (idx INTEGER PRIMARY KEY, step_type INTEGER NOT NULL DEFAULT 0);
             CREATE TABLE IF NOT EXISTS gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);",
        )
        .map_err(|e| e.to_string())?;
        cdb.execute(
            "INSERT OR REPLACE INTO trajectory_meta VALUES (?1, ?2, 4, 18)",
            rusqlite::params![format!("traj-{}", s.id), s.id],
        )
        .map_err(|e| e.to_string())?;

        let mut step_idx = 0i64;
        for _ in 0..s.turns.min(8) {
            cdb.execute("INSERT INTO steps (idx, step_type) VALUES (?1, 14)", [step_idx])
                .map_err(|e| e.to_string())?;
            step_idx += 1;
        }
        for _ in 0..s.turns {
            cdb.execute("INSERT INTO steps (idx, step_type) VALUES (?1, 15)", [step_idx])
                .map_err(|e| e.to_string())?;
            step_idx += 1;
        }
        for _ in 0..s.checkpoints {
            cdb.execute("INSERT INTO steps (idx, step_type) VALUES (?1, 23)", [step_idx])
                .map_err(|e| e.to_string())?;
            step_idx += 1;
        }
        for _ in 0..(s.turns * 2) {
            cdb.execute("INSERT INTO steps (idx, step_type) VALUES (?1, 132)", [step_idx])
                .map_err(|e| e.to_string())?;
            step_idx += 1;
        }

        for t in 0..s.turns {
            let frac = (t + 1) as f64 / (s.turns.max(1) as f64);
            let turn_ctx = ((s.ctx_used as f64) * frac) as u64;
            let turn_cache = ((s.cache_tok as f64) * frac) as u64;
            let blob = build_sandbox_gen_metadata_pb(
                s.in_tok,
                s.out_tok,
                turn_cache,
                s.think_tok,
                turn_ctx,
                s.ctx_limit,
                s.model,
            );
            cdb.execute(
                "INSERT INTO gen_metadata (idx, data) VALUES (?1, ?2)",
                rusqlite::params![t as i64, blob],
            )
            .map_err(|e| e.to_string())?;
        }

        let sbrain = brain_dir.join(s.id);
        fs::create_dir_all(&sbrain).map_err(|e| e.to_string())?;
        if s.id == "db17f36d-3b3d-5e57-92da-75713ee65f8a" {
            let _ = fs::write(sbrain.join("implementation_plan.md"), "# Plan\n");
            let _ = fs::write(sbrain.join("telemetry_audit.md"), "# Audit\n");
        }
    }

    // Seed one archived v2.35.0 conversation to verify showArchivedSessions filter
    conn.execute(
        "INSERT OR REPLACE INTO conversation_summaries
         (conversation_id, title, preview, step_count, last_modified_time, workspace_uris, status, source, project_id, last_user_input_time)
         VALUES ('archived-v235-01', 'Archived Legacy Thread', '已归档历史会话示例', 24, '2026-11-18 10:00:00+00:00', '[\"file:///Users/don/git/agy-higher\"]', 'CASCADE_RUN_STATUS_IDLE', '', 'a1b2c3d4-1001-4a00-8001-000000000001', '2026-11-18 10:00:00+00:00')",
        [],
    )
    .map_err(|e| e.to_string())?;
    fs::write(
        ann_dir.join("archived-v235-01.pbtxt"),
        "title:\"Archived Legacy Thread\"\narchived:true\ntags:\"archive\"\n",
    )
    .map_err(|e| e.to_string())?;

    // Seed one mirrored CLI row to ensure Antigravity scanner filters it out
    conn.execute(
        "INSERT OR REPLACE INTO conversation_summaries
         (conversation_id, title, preview, step_count, last_modified_time, workspace_uris, status, source, project_id, last_user_input_time)
         VALUES ('cli-mirrored-ignore', '', 'mirrored cli row', 10, '2026-11-23 05:00:00+00:00', '[\"file:///Users/don/git/Donby\"]', 'CASCADE_RUN_STATUS_IDLE', 'CORTEX_TRAJECTORY_SOURCE_CLI', 'default-cli-project', '2026-11-23 05:00:00+00:00')",
        [],
    )
    .map_err(|e| e.to_string())?;

    Ok(())
}
