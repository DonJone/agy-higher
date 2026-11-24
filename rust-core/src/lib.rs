pub mod accounts;
pub mod config;
pub mod l10n;
pub mod models;
pub mod paths;
pub mod quota;
pub mod scanner;

use crate::accounts::{
    build_account_profiles, clear_inactive_accounts, is_valid_email,
    read_desktop_active_account_readonly, remove_cached_account,
};
use crate::config::{load_preferences, save_preferences};
use crate::l10n::{
    ensure_custom_translations_template, inspect_l10n_status, install_direct_patch,
    restart_antigravity_normally, sync_and_rebuild_l10n, uninstall_direct_patch,
};
use crate::models::{
    AccountActionRequest, ApiResponse, AppPreferences, DashboardSnapshot, InitConfig,
    L10nActionRequest, MutationResult, NativeProject, QuotaSnapshot, SessionTelemetry,
    UpdatePreferencesRequest,
};
use crate::paths::CorePaths;
use crate::quota::{
    current_unix_secs, fetch_live_quota, format_utc_now, load_cached_or_initial_quota,
    read_verified_quota_cache,
};
use crate::scanner::{is_session_cache_fresh, scan_antigravity_desktop};
use serde::Serialize;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{Mutex, OnceLock};

pub struct CoreEngine {
    pub paths: CorePaths,
    pub preferences: AppPreferences,
    pub focus_session_id: Option<String>,
    pub quota_cache: Option<QuotaSnapshot>,
    pub cached_projects: Vec<NativeProject>,
    pub cached_sessions: Vec<SessionTelemetry>,
    pub has_scanned_sessions: bool,
}

impl CoreEngine {
    pub fn initialize(config: InitConfig) -> Result<Self, String> {
        let paths = CorePaths::resolve(
            config.sandbox_mode.unwrap_or(false),
            config.sandbox_root.as_deref(),
        );
        if paths.sandbox_mode {
            paths.ensure_sandbox_seeded()?;
        }
        let preferences = load_preferences(&paths);
        Ok(Self {
            paths,
            preferences,
            focus_session_id: None,
            quota_cache: None,
            cached_projects: Vec::new(),
            cached_sessions: Vec::new(),
            has_scanned_sessions: false,
        })
    }

    /// Resolve the authoritative active Google account email:
    /// 1. Live OAuth-verified in-memory quota snapshot (NEVER stale!)
    /// 2. Last OAuth-verified disk quota-cache.json (survives restarts accurately)
    /// 3. In sandbox mode only, fall back to fixture app_storage.json; in live mode wait for
    ///    OAuth verification rather than showing stale onboarding `app_storage.json` data.
    fn resolve_active_account(&self) -> (String, String, i64) {
        if let Some(ref q) = self.quota_cache {
            if is_valid_email(&q.account_email) && q.source != "antigravity-pending" {
                return (
                    q.account_email.clone(),
                    if q.auth_method.is_empty() {
                        "consumer".to_string()
                    } else {
                        q.auth_method.clone()
                    },
                    current_unix_secs(),
                );
            }
        }
        if !self.paths.sandbox_mode {
            if let Some(q) = read_verified_quota_cache(&self.paths) {
                return (
                    q.account_email,
                    if q.auth_method.is_empty() {
                        "consumer".to_string()
                    } else {
                        q.auth_method
                    },
                    current_unix_secs(),
                );
            }
            return (String::new(), "consumer".to_string(), 0);
        }
        read_desktop_active_account_readonly(&self.paths)
    }

    /// Full snapshot including disk/SQLite session scan (used by init & refresh).
    pub fn build_snapshot(&mut self) -> Result<DashboardSnapshot, String> {
        let (projects, sessions) = scan_antigravity_desktop(
            &self.paths,
            self.focus_session_id.as_deref(),
            self.preferences.show_archived_sessions,
        );
        self.cached_projects = projects;
        self.cached_sessions = sessions;
        self.has_scanned_sessions = true;
        self.assemble_snapshot_from_cache(false)
    }

    /// Fast-path snapshot reusing already-scanned sessions & projects (<0.3ms).
    /// Used by preferences toggle, account cache edits, focus-on-cached-session, and post-quota updates.
    pub fn build_snapshot_fast(&mut self) -> Result<DashboardSnapshot, String> {
        if !self.has_scanned_sessions {
            return self.build_snapshot();
        }
        self.assemble_snapshot_from_cache(true)
    }

    fn assemble_snapshot_from_cache(&mut self, skip_pref_reload: bool) -> Result<DashboardSnapshot, String> {
        if !skip_pref_reload {
            self.preferences = load_preferences(&self.paths);
        }
        let (active_email, active_method, active_mtime) = self.resolve_active_account();

        let quota = match &self.quota_cache {
            Some(q)
                if !active_email.is_empty()
                    && q.account_email.eq_ignore_ascii_case(&active_email) =>
            {
                q.clone()
            }
            _ => {
                let q = load_cached_or_initial_quota(&self.paths, &active_email, &active_method);
                self.quota_cache = Some(q.clone());
                q
            }
        };

        let accounts = build_account_profiles(
            &self.paths,
            &active_email,
            &active_method,
            active_mtime,
            &quota,
        );

        let l10n = inspect_l10n_status(&self.paths);

        Ok(DashboardSnapshot {
            sandbox_mode: self.paths.sandbox_mode,
            session_count: self.cached_sessions.len(),
            projects: self.cached_projects.clone(),
            sessions: self.cached_sessions.clone(),
            quota,
            accounts,
            active_email,
            preferences: self.preferences.clone(),
            l10n,
            last_scanned_at: format_utc_now(),
        })
    }

    pub fn focus_session(&mut self, session_id: &str) -> Result<DashboardSnapshot, String> {
        let trimmed = session_id.trim();
        if !trimmed.is_empty() {
            self.focus_session_id = Some(trimmed.to_string());
            if self.has_scanned_sessions
                && self.cached_sessions.iter().any(|s| s.id == trimmed)
                && is_session_cache_fresh(&self.paths, trimmed)
            {
                return self.build_snapshot_fast();
            }
        }
        self.build_snapshot()
    }

    pub fn update_preferences(
        &mut self,
        req: UpdatePreferencesRequest,
    ) -> Result<MutationResult, String> {
        let mut prefs = self.preferences.clone();
        let mut msg = "面板偏好已更新".to_string();
        let mut needs_rescan = false;
        let mut needs_l10n_sync = false;

        if let Some(hide) = req.hide_non_gemini_models {
            prefs.hide_non_gemini_models = hide;
            msg = if hide {
                "已屏蔽非 Gemini 模型额度分组".to_string()
            } else {
                "已显示全部模型额度分组（含 Claude / GPT）".to_string()
            };
        }
        if let Some(show_mb) = req.show_menu_bar_quota {
            prefs.show_menu_bar_quota = show_mb;
            msg = if show_mb {
                "已在 macOS 顶部菜单栏开启额度显示".to_string()
            } else {
                "已隐藏 macOS 菜单栏额度图标".to_string()
            };
        }
        if let Some(theme) = req.theme_mode {
            let norm = if theme.eq_ignore_ascii_case("light") {
                "light".to_string()
            } else {
                "dark".to_string()
            };
            prefs.theme_mode = norm;
            msg = if prefs.theme_mode == "light" {
                "已切换至浅色单色主题".to_string()
            } else {
                "已切换至深色单色主题".to_string()
            };
        }
        if let Some(show_archived) = req.show_archived_sessions {
            if prefs.show_archived_sessions != show_archived {
                needs_rescan = true;
            }
            prefs.show_archived_sessions = show_archived;
            msg = if show_archived {
                "已显示归档历史会话".to_string()
            } else {
                "已隐藏归档历史会话".to_string()
            };
        }
        let mut l10n_turned_on = false;
        let mut l10n_turned_off = false;
        if let Some(l10n_on) = req.l10n_enabled {
            prefs.l10n_enabled = l10n_on;
            if l10n_on {
                needs_l10n_sync = true;
                l10n_turned_on = true;
            } else {
                l10n_turned_off = true;
            }
            msg = if l10n_on {
                "已启用中文拓展（STE-STC 词库）".to_string()
            } else {
                "已关闭中文拓展（已打补丁的窗口自动还原英文）".to_string()
            };
        }
        if let Some(keep_en) = req.l10n_keep_english_options {
            if prefs.l10n_keep_english_options != keep_en {
                needs_l10n_sync = true;
            }
            prefs.l10n_keep_english_options = keep_en;
            msg = if keep_en {
                "选项名已设为保留英文（Extra High / Plan / Auto）".to_string()
            } else {
                "选项名已设为 STE-STC 中文".to_string()
            };
        }

        save_preferences(&self.paths, &prefs)?;
        self.preferences = prefs;
        if needs_l10n_sync {
            let _ = sync_and_rebuild_l10n(&self.paths, &self.preferences);
        }
        if l10n_turned_on && !self.paths.sandbox_mode {
            let cur_status = inspect_l10n_status(&self.paths);
            if !cur_status.patch_installed {
                if let Ok(patch_msg) = install_direct_patch(&self.paths, &self.preferences) {
                    msg = patch_msg;
                }
            } else {
                msg = "已启用中文拓展，Antigravity 窗口将自动热切换为 STE-STC 中文".to_string();
            }
        } else if l10n_turned_off && !self.paths.sandbox_mode {
            msg = "已关闭中文拓展，Antigravity 窗口将自动恢复原版英文".to_string();
        }
        let snapshot = if needs_rescan {
            self.build_snapshot()?
        } else {
            self.build_snapshot_fast()?
        };
        Ok(MutationResult { snapshot, message: msg })
    }

    pub fn l10n_action(&mut self, req: L10nActionRequest) -> Result<MutationResult, String> {
        let message = match req.action.as_str() {
            "rebuild" => {
                let (_, msg) = sync_and_rebuild_l10n(&self.paths, &self.preferences)?;
                msg
            }
            "install_patch" => {
                self.preferences.l10n_enabled = true;
                let _ = save_preferences(&self.paths, &self.preferences);
                install_direct_patch(&self.paths, &self.preferences)?
            }
            "uninstall_patch" => {
                self.preferences.l10n_enabled = false;
                let _ = save_preferences(&self.paths, &self.preferences);
                uninstall_direct_patch(&self.paths)?
            }
            "restart_antigravity" => restart_antigravity_normally(&self.paths)?,
            "ensure_custom_file" => {
                let path = ensure_custom_translations_template(&self.paths)?;
                format!("自定义词条已就绪: {}", path.to_string_lossy())
            }
            other => return Err(format!("不支持的中文拓展操作: {}", other)),
        };
        let snapshot = self.build_snapshot_fast()?;
        Ok(MutationResult { snapshot, message })
    }

    pub fn account_action(&mut self, req: AccountActionRequest) -> Result<MutationResult, String> {
        let (active_email, _, _) = self.resolve_active_account();
        let message = match req.action.as_str() {
            "sync_accounts" => {
                if active_email.is_empty() {
                    "未在 Antigravity 检测到已登录账户".to_string()
                } else {
                    format!("已同步当前 Antigravity 账户: {}", active_email)
                }
            }
            "remove_cached" => {
                let target = req
                    .email
                    .as_deref()
                    .ok_or_else(|| "缺少账户邮箱".to_string())?;
                remove_cached_account(&self.paths, target, &active_email)?
            }
            "clear_inactive" => clear_inactive_accounts(&self.paths, &active_email)?,
            other => return Err(format!("不支持的账户操作: {}", other)),
        };

        let snapshot = self.build_snapshot_fast()?;
        Ok(MutationResult { snapshot, message })
    }
}

// ---------- Global C-ABI Bridge ----------

static ENGINE: OnceLock<Mutex<Option<CoreEngine>>> = OnceLock::new();

fn engine_mutex() -> &'static Mutex<Option<CoreEngine>> {
    ENGINE.get_or_init(|| Mutex::new(None))
}

fn to_c_json<T: Serialize>(resp: ApiResponse<T>) -> *mut c_char {
    let json = serde_json::to_string(&resp).unwrap_or_else(|e| {
        format!(
            r#"{{"ok":false,"data":null,"error":"Serialization failure: {}"}}"#,
            e
        )
    });
    CString::new(json)
        .unwrap_or_else(|_| {
            CString::new(r#"{"ok":false,"data":null,"error":"NUL byte in response"}"#).unwrap()
        })
        .into_raw()
}

unsafe fn read_c_str(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Ok(String::new());
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map(|s| s.to_string())
        .map_err(|e| format!("Invalid UTF-8 C string: {}", e))
}

fn with_engine<T, F>(f: F) -> *mut c_char
where
    T: Serialize,
    F: FnOnce(&mut CoreEngine) -> Result<T, String>,
{
    let mut guard = match engine_mutex().lock() {
        Ok(g) => g,
        Err(e) => return to_c_json::<T>(ApiResponse::failure(format!("Engine lock poisoned: {}", e))),
    };
    let engine = match guard.as_mut() {
        Some(e) => e,
        None => {
            let init = InitConfig {
                sandbox_mode: None,
                sandbox_root: None,
            };
            match CoreEngine::initialize(init) {
                Ok(e) => {
                    *guard = Some(e);
                    guard.as_mut().unwrap()
                }
                Err(err) => return to_c_json::<T>(ApiResponse::failure(err)),
            }
        }
    };
    match f(engine) {
        Ok(data) => to_c_json(ApiResponse::success(data)),
        Err(err) => to_c_json::<T>(ApiResponse::failure(err)),
    }
}

#[no_mangle]
pub unsafe extern "C" fn agy_higher_init(config_json: *const c_char) -> *mut c_char {
    let raw = match read_c_str(config_json) {
        Ok(s) => s,
        Err(e) => return to_c_json::<DashboardSnapshot>(ApiResponse::failure(e)),
    };
    let cfg: InitConfig = if raw.trim().is_empty() {
        InitConfig {
            sandbox_mode: None,
            sandbox_root: None,
        }
    } else {
        match serde_json::from_str(&raw) {
            Ok(c) => c,
            Err(e) => {
                return to_c_json::<DashboardSnapshot>(ApiResponse::failure(format!(
                    "Invalid init JSON: {}",
                    e
                )));
            }
        }
    };

    match CoreEngine::initialize(cfg) {
        Ok(mut engine) => match engine.build_snapshot() {
            Ok(snap) => {
                if let Ok(mut guard) = engine_mutex().lock() {
                    *guard = Some(engine);
                }
                to_c_json(ApiResponse::success(snap))
            }
            Err(e) => to_c_json::<DashboardSnapshot>(ApiResponse::failure(e)),
        },
        Err(e) => to_c_json::<DashboardSnapshot>(ApiResponse::failure(e)),
    }
}

#[no_mangle]
pub unsafe extern "C" fn agy_higher_refresh() -> *mut c_char {
    with_engine(|engine| engine.build_snapshot())
}

#[no_mangle]
pub unsafe extern "C" fn agy_higher_focus_session(session_id_str: *const c_char) -> *mut c_char {
    let sid = match read_c_str(session_id_str) {
        Ok(s) => s,
        Err(e) => return to_c_json::<DashboardSnapshot>(ApiResponse::failure(e)),
    };
    with_engine(|engine| engine.focus_session(&sid))
}

#[no_mangle]
pub unsafe extern "C" fn agy_higher_refresh_live_quota() -> *mut c_char {
    // Release ENGINE lock before spawning network/subprocess query so main thread never blocks
    let (paths, fallback_model) = {
        let mut guard = match engine_mutex().lock() {
            Ok(g) => g,
            Err(e) => {
                return to_c_json::<DashboardSnapshot>(ApiResponse::failure(format!(
                    "Engine lock poisoned: {}",
                    e
                )));
            }
        };
        let engine = match guard.as_mut() {
            Some(e) => e,
            None => {
                match CoreEngine::initialize(InitConfig {
                    sandbox_mode: None,
                    sandbox_root: None,
                }) {
                    Ok(e) => {
                        *guard = Some(e);
                        guard.as_mut().unwrap()
                    }
                    Err(err) => return to_c_json::<DashboardSnapshot>(ApiResponse::failure(err)),
                }
            }
        };
        let model = engine
            .cached_sessions
            .first()
            .map(|s| s.model.clone())
            .unwrap_or_default();
        (engine.paths.clone(), model)
    };

    let (active_email, _, _) = read_desktop_active_account_readonly(&paths);
    let live = match fetch_live_quota(&paths, &active_email, &fallback_model) {
        Ok(q) => q,
        Err(e) => return to_c_json::<DashboardSnapshot>(ApiResponse::failure(e)),
    };

    with_engine(|engine| {
        engine.quota_cache = Some(live);
        engine.build_snapshot_fast()
    })
}

#[no_mangle]
pub unsafe extern "C" fn agy_higher_update_preferences(req_json: *const c_char) -> *mut c_char {
    let raw = match read_c_str(req_json) {
        Ok(s) => s,
        Err(e) => return to_c_json::<MutationResult>(ApiResponse::failure(e)),
    };
    let req: UpdatePreferencesRequest = match serde_json::from_str(&raw) {
        Ok(r) => r,
        Err(e) => {
            return to_c_json::<MutationResult>(ApiResponse::failure(format!(
                "Invalid preferences JSON: {}",
                e
            )));
        }
    };
    with_engine(|engine| engine.update_preferences(req))
}

#[no_mangle]
pub unsafe extern "C" fn agy_higher_account_action(req_json: *const c_char) -> *mut c_char {
    let raw = match read_c_str(req_json) {
        Ok(s) => s,
        Err(e) => return to_c_json::<MutationResult>(ApiResponse::failure(e)),
    };
    let req: AccountActionRequest = match serde_json::from_str(&raw) {
        Ok(r) => r,
        Err(e) => {
            return to_c_json::<MutationResult>(ApiResponse::failure(format!(
                "Invalid account action JSON: {}",
                e
            )));
        }
    };
    with_engine(|engine| engine.account_action(req))
}

#[no_mangle]
pub unsafe extern "C" fn agy_higher_l10n_action(req_json: *const c_char) -> *mut c_char {
    let raw = match read_c_str(req_json) {
        Ok(s) => s,
        Err(e) => return to_c_json::<MutationResult>(ApiResponse::failure(e)),
    };
    let req: L10nActionRequest = match serde_json::from_str(&raw) {
        Ok(r) => r,
        Err(e) => {
            return to_c_json::<MutationResult>(ApiResponse::failure(format!(
                "Invalid l10n action JSON: {}",
                e
            )));
        }
    };
    // Release ENGINE lock during direct patch install / Antigravity restart so UI never stalls
    if req.action == "install_patch"
        || req.action == "uninstall_patch"
        || req.action == "restart_antigravity"
    {
        let (paths, mut prefs) = {
            let mut guard = match engine_mutex().lock() {
                Ok(g) => g,
                Err(e) => {
                    return to_c_json::<MutationResult>(ApiResponse::failure(format!(
                        "Engine lock poisoned: {}",
                        e
                    )));
                }
            };
            let engine = match guard.as_mut() {
                Some(e) => e,
                None => {
                    match CoreEngine::initialize(InitConfig {
                        sandbox_mode: None,
                        sandbox_root: None,
                    }) {
                        Ok(e) => {
                            *guard = Some(e);
                            guard.as_mut().unwrap()
                        }
                        Err(err) => return to_c_json::<MutationResult>(ApiResponse::failure(err)),
                    }
                }
            };
            (engine.paths.clone(), engine.preferences.clone())
        };

        let result_msg = match req.action.as_str() {
            "install_patch" => {
                prefs.l10n_enabled = true;
                let _ = save_preferences(&paths, &prefs);
                install_direct_patch(&paths, &prefs)
            }
            "uninstall_patch" => {
                prefs.l10n_enabled = false;
                let _ = save_preferences(&paths, &prefs);
                uninstall_direct_patch(&paths)
            }
            _ => restart_antigravity_normally(&paths),
        };

        return match result_msg {
            Ok(message) => with_engine(|engine| {
                engine.preferences = prefs;
                let snapshot = engine.build_snapshot_fast()?;
                Ok(MutationResult { snapshot, message })
            }),
            Err(e) => to_c_json::<MutationResult>(ApiResponse::failure(e)),
        };
    }

    with_engine(|engine| engine.l10n_action(req))
}

#[no_mangle]
pub unsafe extern "C" fn agy_higher_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        let _ = CString::from_raw(ptr);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::accounts::{is_valid_email, load_accounts_registry, save_accounts_registry, StoredAccountRecord};
    use crate::paths::build_sandbox_gen_metadata_pb;
    use crate::quota::{parse_credits_json, parse_model_json, parse_usage_json};
    use crate::scanner::{open_sqlite_readonly, parse_gen_metadata_pb};
    use std::path::PathBuf;

    fn fresh_test_sandbox(name: &str) -> PathBuf {
        let dir = PathBuf::from(crate::paths::DEFAULT_SANDBOX_ROOT)
            .join("unit-tests-v3")
            .join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn test_strict_email_validation_rejects_corrupt_logs() {
        assert!(is_valid_email("ananmagoro701@gmail.com"));
        assert!(is_valid_email("user.name+tag@example.co.jp"));
        assert!(!is_valid_email("beatles329399@gmail.cI1116 21:15:37 hooks_manager.go:54]"));
        assert!(!is_valid_email("no-at-sign.com"));
        assert!(!is_valid_email("bad@localhost"));
        assert!(!is_valid_email(""));
    }

    #[test]
    fn test_gen_metadata_protobuf_exact_extraction() {
        let blob = build_sandbox_gen_metadata_pb(
            2_481,
            141,
            189_462,
            11,
            192_643,
            512_000,
            "Gemini 4 Neon (XHigh)",
        );
        let parsed = parse_gen_metadata_pb(&blob).expect("should parse gen_metadata protobuf");
        assert_eq!(parsed.input_tokens, 2_481);
        assert_eq!(parsed.output_tokens, 141);
        assert_eq!(parsed.cache_read_tokens, 189_462);
        assert_eq!(parsed.thinking_tokens, 11);
        assert_eq!(parsed.ctx_used_tokens, 192_643);
        assert_eq!(parsed.ctx_limit_tokens, 512_000);
        assert_eq!(parsed.model_label, "Gemini 4 Neon (XHigh)");
    }

    #[test]
    fn test_pure_antigravity_desktop_scan_and_account_removal_persists() {
        let sb = fresh_test_sandbox("desktop_pure");
        let mut engine = CoreEngine::initialize(InitConfig {
            sandbox_mode: Some(true),
            sandbox_root: Some(sb.to_string_lossy().to_string()),
        })
        .unwrap();

        let snap = engine.build_snapshot().unwrap();
        assert_eq!(snap.session_count, 4);
        assert!(!snap.sessions.iter().any(|s| s.id == "cli-mirrored-ignore"));
        // Only the active Antigravity Desktop account is present (zero CLI accounts!)
        assert_eq!(snap.accounts.len(), 1);
        assert_eq!(snap.accounts[0].email, "ananmagoro701@gmail.com");

        // Simulate a previously cached old account + a corrupt log entry
        let mut reg = load_accounts_registry(&engine.paths);
        reg.entries.insert(
            "old@gmail.com".to_string(),
            StoredAccountRecord {
                email: "old@gmail.com".to_string(),
                auth_method: "consumer".to_string(),
                last_seen_unix: 1700000000,
                cached_quota: None,
            },
        );
        reg.entries.insert(
            "corrupt@gmail.cI1116 bad line".to_string(),
            StoredAccountRecord {
                email: "corrupt@gmail.cI1116 bad line".to_string(),
                auth_method: "consumer".to_string(),
                last_seen_unix: 1700000000,
                cached_quota: None,
            },
        );
        save_accounts_registry(&engine.paths, &reg).unwrap();

        // Reload auto-purges corrupt entry and keeps valid old@gmail.com
        let snap2 = engine.build_snapshot().unwrap();
        assert_eq!(snap2.accounts.len(), 2);

        // Removing old@gmail.com MUST permanently remove it and NEVER resurrect on refresh!
        let rem = engine
            .account_action(AccountActionRequest {
                action: "remove_cached".to_string(),
                email: Some("old@gmail.com".to_string()),
            })
            .unwrap();
        assert_eq!(rem.snapshot.accounts.len(), 1);
        let after_refresh = engine.build_snapshot().unwrap();
        assert_eq!(after_refresh.accounts.len(), 1);
        assert_eq!(after_refresh.accounts[0].email, "ananmagoro701@gmail.com");
    }

    #[test]
    fn test_preferences_persistence_including_theme() {
        let sb = fresh_test_sandbox("prefs");
        let mut engine = CoreEngine::initialize(InitConfig {
            sandbox_mode: Some(true),
            sandbox_root: Some(sb.to_string_lossy().to_string()),
        })
        .unwrap();

        let res = engine
            .update_preferences(UpdatePreferencesRequest {
                hide_non_gemini_models: Some(false),
                show_menu_bar_quota: Some(false),
                theme_mode: Some("light".to_string()),
                show_archived_sessions: Some(true),
                l10n_enabled: Some(true),
                l10n_keep_english_options: Some(false),
            })
            .unwrap();
        assert!(!res.snapshot.preferences.hide_non_gemini_models);
        assert!(!res.snapshot.preferences.show_menu_bar_quota);
        assert_eq!(res.snapshot.preferences.theme_mode, "light");
        assert!(res.snapshot.preferences.show_archived_sessions);
        assert!(res.snapshot.preferences.l10n_enabled);
        assert!(!res.snapshot.preferences.l10n_keep_english_options);
    }

    #[test]
    fn test_strict_readonly_write_guard() {
        let sb = fresh_test_sandbox("write_guard");
        let paths = CorePaths::resolve(true, Some(&sb.to_string_lossy()));
        let live_gemini = crate::paths::home_dir().join(".gemini").join("antigravity");
        assert!(paths.assert_safe_write_target(&live_gemini).is_err());
        assert!(paths.assert_safe_write_target(&paths.config_json_path()).is_ok());
    }

    #[test]
    fn test_parse_official_quota_json() {
        let usage_raw = r#"{
            "status": "SUCCESS",
            "command": {
                "data": {
                    "description": "Shared limits.",
                    "groups": [
                        {
                            "name": "Gemini Models",
                            "description": "Gemini 4 Neon",
                            "buckets": [
                                {"id": "gemini-5h", "name": "5h", "window": "5h", "remaining_fraction": 0.96},
                                {"id": "gemini-weekly", "name": "Weekly", "window": "weekly", "remaining_fraction": 0.86}
                            ]
                        },
                        {
                            "name": "Claude and GPT models",
                            "description": "3P models",
                            "buckets": [{"id": "3p-weekly", "name": "Weekly", "window": "weekly", "remaining_fraction": 1.0}]
                        }
                    ]
                }
            }
        }"#;
        let (groups, _) = parse_usage_json(usage_raw, 1795400000).unwrap();
        assert_eq!(groups.len(), 2);
        assert!(groups[0].is_gemini);
        assert!(!groups[1].is_gemini);
        assert_eq!(groups[0].buckets[0].remaining_pct, 86);

        let credits_raw = r#"{"status":"SUCCESS","command":{"data":{"remaining_credits":120,"upgrade_uri":"https://antigravity.google/g1-upgrade"}}}"#;
        assert_eq!(parse_credits_json(credits_raw).unwrap().0, 120);

        let model_raw = r#"{"status":"SUCCESS","command":{"data":{"id":"gemini-4-neon-xhigh","label":"Gemini 4 Neon (XHigh)"}}}"#;
        assert_eq!(parse_model_json(model_raw).unwrap().1, "Gemini 4 Neon (XHigh)");
    }

    #[test]
    fn test_oauth_log_extraction_and_zero_cross_account_quota_mixing() {
        use crate::accounts::parse_oauth_identity_from_log;
        use crate::quota::sandbox_quota_snapshot;

        let log_sample = "\
I1123 15:40:35.742887 1 server_oauth.go:221] applyAuthResult: email=ananmagoro701@gmail.com, authMethod=consumer, quotaProject=\n\
I1123 15:40:35.743200 1 server_oauth.go:226] OAuth: authenticated successfully as ananmagoro701@gmail.com\n";
        let (em, method) = parse_oauth_identity_from_log(log_sample).expect("must extract OAuth email");
        assert_eq!(em, "ananmagoro701@gmail.com");
        assert_eq!(method, "consumer");

        // Verify Account A (5%) and Account B (83%) NEVER mix even if app_storage.json stays stale!
        let sb = fresh_test_sandbox("zero_mix");
        let mut engine = CoreEngine::initialize(InitConfig {
            sandbox_mode: Some(true),
            sandbox_root: Some(sb.to_string_lossy().to_string()),
        })
        .unwrap();

        let mut q_don = sandbox_quota_snapshot("donnnyjuan@gmail.com");
        q_don.source = "antigravity-live".to_string();
        q_don.groups[0].buckets[0].remaining_pct = 5;
        q_don.groups[0].buckets[0].remaining_fraction = 0.05;
        engine.quota_cache = Some(q_don);
        let snap1 = engine.build_snapshot().unwrap();
        assert_eq!(snap1.active_email, "donnnyjuan@gmail.com");
        assert_eq!(
            snap1.accounts.iter().find(|a| a.email == "donnnyjuan@gmail.com").unwrap().weekly_remaining_pct,
            Some(5)
        );

        // Now simulate switching OAuth login to ananmagoro701@gmail.com (83%) while app_storage.json is unchanged
        let mut q_anan = sandbox_quota_snapshot("ananmagoro701@gmail.com");
        q_anan.source = "antigravity-live".to_string();
        q_anan.groups[0].buckets[0].remaining_pct = 83;
        q_anan.groups[0].buckets[0].remaining_fraction = 0.83;
        engine.quota_cache = Some(q_anan);
        let snap2 = engine.build_snapshot().unwrap();

        assert_eq!(snap2.active_email, "ananmagoro701@gmail.com");
        let anan = snap2.accounts.iter().find(|a| a.email == "ananmagoro701@gmail.com").unwrap();
        let don = snap2.accounts.iter().find(|a| a.email == "donnnyjuan@gmail.com").unwrap();
        assert!(anan.is_active);
        assert!(!don.is_active);
        assert_eq!(anan.weekly_remaining_pct, Some(83));
        assert_eq!(don.weekly_remaining_pct, Some(5));
    }

    #[test]
    fn test_disk_telemetry_cache_persists_and_fast_paths_work() {
        let sb = fresh_test_sandbox("disk_cache");
        let mut engine = CoreEngine::initialize(InitConfig {
            sandbox_mode: Some(true),
            sandbox_root: Some(sb.to_string_lossy().to_string()),
        })
        .unwrap();

        let snap1 = engine.build_snapshot().unwrap();
        assert_eq!(snap1.session_count, 4);
        assert!(engine.paths.telemetry_cache_path().is_file());

        // Fast-path preference update reuses cached sessions cleanly without losing data
        let pref = engine
            .update_preferences(UpdatePreferencesRequest {
                hide_non_gemini_models: Some(false),
                show_menu_bar_quota: None,
                theme_mode: Some("light".to_string()),
                show_archived_sessions: None,
                l10n_enabled: None,
                l10n_keep_english_options: None,
            })
            .unwrap();
        assert_eq!(pref.snapshot.session_count, 4);
        assert_eq!(pref.snapshot.preferences.theme_mode, "light");

        // Fresh engine reloads persisted telemetry-cache.json with identical metrics
        let mut engine2 = CoreEngine::initialize(InitConfig {
            sandbox_mode: Some(true),
            sandbox_root: Some(sb.to_string_lossy().to_string()),
        })
        .unwrap();
        let snap2 = engine2.build_snapshot().unwrap();
        let donby1 = snap1
            .sessions
            .iter()
            .find(|s| s.id == "db17f36d-3b3d-5e57-92da-75713ee65f8a")
            .unwrap();
        let donby2 = snap2
            .sessions
            .iter()
            .find(|s| s.id == "db17f36d-3b3d-5e57-92da-75713ee65f8a")
            .unwrap();
        assert_eq!(donby1.ctx_used_tokens, donby2.ctx_used_tokens);
        assert_eq!(donby1.total_input_tokens, donby2.total_input_tokens);
        assert_eq!(donby1.total_cache_read_tokens, donby2.total_cache_read_tokens);
    }

    #[test]
    fn test_open_sqlite_readonly_wal_without_shm() {
        let sb = fresh_test_sandbox("wal_ro");
        let db = sb.join("wal_test.db");
        {
            let wconn = rusqlite::Connection::open(&db).unwrap();
            wconn
                .execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (42);")
                .unwrap();
        }
        let _ = std::fs::remove_file(sb.join("wal_test.db-shm"));
        let _ = std::fs::remove_file(sb.join("wal_test.db-wal"));
        let rconn = open_sqlite_readonly(&db).expect("immutable fallback should succeed");
        let val: i64 = rconn.query_row("SELECT x FROM t", [], |r| r.get(0)).unwrap();
        assert_eq!(val, 42);
    }

    #[test]
    fn test_v235_annotations_and_show_archived_toggle() {
        let sb = fresh_test_sandbox("v235_annotations");
        let mut engine = CoreEngine::initialize(InitConfig {
            sandbox_mode: Some(true),
            sandbox_root: Some(sb.to_string_lossy().to_string()),
        })
        .unwrap();

        // Default: archived sessions are hidden (4 visible)
        let snap1 = engine.build_snapshot().unwrap();
        assert_eq!(snap1.session_count, 4);
        assert!(!snap1.sessions.iter().any(|s| s.id == "archived-v235-01"));
        let donby = snap1
            .sessions
            .iter()
            .find(|s| s.id == "db17f36d-3b3d-5e57-92da-75713ee65f8a")
            .unwrap();
        assert!(donby.is_starred);
        assert_eq!(donby.tags, vec!["core".to_string(), "v2.35".to_string()]);

        // Enable showArchivedSessions -> archived conversation becomes visible (5 total)
        let res = engine
            .update_preferences(UpdatePreferencesRequest {
                hide_non_gemini_models: None,
                show_menu_bar_quota: None,
                theme_mode: None,
                show_archived_sessions: Some(true),
                l10n_enabled: None,
                l10n_keep_english_options: None,
            })
            .unwrap();
        assert_eq!(res.snapshot.session_count, 5);
        let archived = res
            .snapshot
            .sessions
            .iter()
            .find(|s| s.id == "archived-v235-01")
            .unwrap();
        assert!(archived.is_archived);
        assert_eq!(archived.tags, vec!["archive".to_string()]);
    }

    #[test]
    fn test_l10n_custom_translations_and_rebuild() {
        use crate::l10n::parse_custom_translations;

        let parsed = parse_custom_translations(
            "# comment\nContext window\nNew Conversation = 创建新对话\nNew Conversation = 发起对话\n",
        );
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0], ("Context window".to_string(), "".to_string()));
        assert_eq!(parsed[1], ("New Conversation".to_string(), "发起对话".to_string()));

        let sb = fresh_test_sandbox("l10n_rebuild");
        let mut engine = CoreEngine::initialize(InitConfig {
            sandbox_mode: Some(true),
            sandbox_root: Some(sb.to_string_lossy().to_string()),
        })
        .unwrap();

        let ensure = engine
            .l10n_action(L10nActionRequest {
                action: "ensure_custom_file".to_string(),
            })
            .unwrap();
        assert!(engine.paths.custom_translations_path().is_file());
        assert_eq!(ensure.snapshot.l10n.custom_rule_count, 0);

        std::fs::write(
            engine.paths.custom_translations_path(),
            "# test\nContext window\nSettings = 系统设置\n",
        )
        .unwrap();

        let rebuilt = engine
            .l10n_action(L10nActionRequest {
                action: "rebuild".to_string(),
            })
            .unwrap();
        assert!(rebuilt.snapshot.l10n.overlay_ready);
        assert_eq!(rebuilt.snapshot.l10n.custom_rule_count, 2);
        assert!(rebuilt.snapshot.l10n.phrase_count > 100);
        assert!(engine.paths.l10n_overlay_path().is_file());
    }
}
