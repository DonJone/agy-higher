use crate::models::{AccountProfile, QuotaSnapshot};
use crate::paths::CorePaths;
use crate::quota::{
    current_unix_secs, format_reset_countdown, format_unix_display, infer_plan_label,
    sandbox_quota_snapshot, summarize_gemini_quota,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::Write;
use std::path::Path;
use std::time::UNIX_EPOCH;

/// Persisted local registry of Antigravity Desktop accounts + cached public quota snapshots.
/// STRICT COMPLIANCE:
/// - Tracks ONLY accounts actually logged into Antigravity.app (NEVER scans old CLI logs!).
/// - Stores ONLY validated email addresses, timestamps, and public quota snapshots (ZERO tokens/Keychain reads).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AccountsRegistry {
    #[serde(default = "default_version")]
    pub version: u32,
    #[serde(default)]
    pub entries: HashMap<String, StoredAccountRecord>,
}

fn default_version() -> u32 {
    2
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredAccountRecord {
    pub email: String,
    pub auth_method: String,
    pub last_seen_unix: i64,
    pub cached_quota: Option<QuotaSnapshot>,
}

/// Strict email validator so garbled/corrupted log strings can NEVER enter accounts.json.
pub fn is_valid_email(s: &str) -> bool {
    let trimmed = s.trim();
    if trimmed.len() < 5 || trimmed.len() > 120 {
        return false;
    }
    if trimmed.chars().any(|c| c.is_whitespace() || !c.is_ascii()) {
        return false;
    }
    let Some((local, domain)) = trimmed.split_once('@') else {
        return false;
    };
    if local.is_empty() || domain.is_empty() || domain.contains('@') || !domain.contains('.') {
        return false;
    }
    let valid_local = local
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '+'));
    let valid_domain = domain
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-'))
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && !domain.contains("..")
        && domain
            .rsplit('.')
            .next()
            .map(|tld| tld.len() >= 2 && tld.chars().all(|c| c.is_ascii_alphabetic()))
            .unwrap_or(false);
    valid_local && valid_domain
}

/// Extract the exact server-verified OAuth email and authMethod from an isolated
/// `--log-file` produced by a single official quota query.
pub fn parse_oauth_identity_from_log(log_text: &str) -> Option<(String, String)> {
    for line in log_text.lines().rev() {
        if let Some(pos) = line.find("applyAuthResult: email=") {
            let rest = &line[pos + "applyAuthResult: email=".len()..];
            let email = rest.split(',').next().unwrap_or("").trim();
            let method = rest
                .split("authMethod=")
                .nth(1)
                .and_then(|s| s.split(',').next())
                .unwrap_or("consumer")
                .trim();
            if is_valid_email(email) {
                let norm_method = if method.is_empty() { "consumer" } else { method };
                return Some((email.to_string(), norm_method.to_string()));
            }
        }
        if let Some(pos) = line.find("OAuth: authenticated successfully as ") {
            let rest = &line[pos + "OAuth: authenticated successfully as ".len()..];
            let email = rest.split_whitespace().next().unwrap_or("").trim();
            if is_valid_email(email) {
                return Some((email.to_string(), "consumer".to_string()));
            }
        }
    }
    None
}

/// Fallback-only reader for Antigravity.app's initial onboarding storage (`app_storage.json`).
/// NOTE: `agy.onboarding.lastLoginUsername` is ONLY written during onboarding and does NOT update
/// after subsequent account switches; live OAuth identity from `quota.rs` always takes precedence.
pub fn read_desktop_active_account_readonly(paths: &CorePaths) -> (String, String, i64) {
    if paths.desktop_ls_log_path.is_file() {
        let mt = file_mtime_secs(&paths.desktop_ls_log_path).unwrap_or_else(current_unix_secs);
        if let Ok(content) = fs::read_to_string(&paths.desktop_ls_log_path) {
            if let Some((email, method)) = parse_oauth_identity_from_log(&content) {
                return (email, method, mt);
            }
        }
    }

    if let Ok(raw) = fs::read_to_string(&paths.app_storage_path) {
        if let Ok(val) = serde_json::from_str::<Value>(&raw) {
            if let Some(em) = val
                .get("agy.onboarding.lastLoginUsername")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| is_valid_email(s))
            {
                let mt = file_mtime_secs(&paths.app_storage_path).unwrap_or_else(current_unix_secs);
                return (em.to_string(), "consumer".to_string(), mt);
            }
        }
    }

    (String::new(), "consumer".to_string(), 0)
}

fn file_mtime_secs(p: &Path) -> Option<i64> {
    fs::metadata(p)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs() as i64)
}

pub fn load_accounts_registry(paths: &CorePaths) -> AccountsRegistry {
    let p = paths.accounts_json_path();
    let Ok(raw) = fs::read_to_string(&p) else {
        return AccountsRegistry {
            version: 2,
            entries: HashMap::new(),
        };
    };
    let mut reg = serde_json::from_str::<AccountsRegistry>(&raw).unwrap_or_else(|_| AccountsRegistry {
        version: 2,
        entries: HashMap::new(),
    });
    // Auto-purge any invalid/corrupt email keys from older versions
    let before = reg.entries.len();
    reg.entries.retain(|k, v| is_valid_email(k) && is_valid_email(&v.email));
    if reg.entries.len() != before || reg.version < 2 {
        reg.version = 2;
        let _ = save_accounts_registry(paths, &reg);
    }
    reg
}

pub fn save_accounts_registry(
    paths: &CorePaths,
    registry: &AccountsRegistry,
) -> Result<(), String> {
    let target = paths.accounts_json_path();
    paths.assert_safe_write_target(&target)?;
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let serialized = serde_json::to_string_pretty(registry).map_err(|e| e.to_string())?;
    let tmp = target.with_extension("json.tmp");
    {
        let mut f = File::create(&tmp).map_err(|e| e.to_string())?;
        f.write_all(serialized.as_bytes())
            .map_err(|e| e.to_string())?;
    }
    fs::rename(&tmp, &target).map_err(|e| e.to_string())?;
    Ok(())
}

/// Build Antigravity account profile list:
/// - Automatically upserts ONLY the currently logged-in Antigravity Desktop account.
/// - Preserves previously archived Antigravity accounts ONLY until the user removes them.
/// - NEVER resurrects removed accounts from CLI logs!
pub fn build_account_profiles(
    paths: &CorePaths,
    active_email: &str,
    active_method: &str,
    active_mtime: i64,
    live_quota: &QuotaSnapshot,
) -> Vec<AccountProfile> {
    let mut registry = load_accounts_registry(paths);
    let mut dirty = false;

    // STRICT ZERO-PHANTOM GUARD:
    // Only persist an account into accounts.json when its identity has been OAuth-verified
    // (live or verified cache), or in sandbox mode. Never pollute accounts.json with stale
    // onboarding `app_storage.json` emails before live OAuth verification completes!
    let identity_verified = paths.sandbox_mode
        || (live_quota.source != "antigravity-pending"
            && is_valid_email(&live_quota.account_email)
            && live_quota.account_email.eq_ignore_ascii_case(active_email));

    if identity_verified && is_valid_email(active_email) {
        let key = active_email.trim().to_lowercase();
        let entry = registry.entries.entry(key).or_insert_with(|| {
            dirty = true;
            StoredAccountRecord {
                email: active_email.trim().to_string(),
                auth_method: active_method.to_string(),
                last_seen_unix: active_mtime.max(current_unix_secs()),
                cached_quota: if paths.sandbox_mode {
                    Some(sandbox_quota_snapshot(active_email))
                } else {
                    None
                },
            }
        });
        if active_mtime > entry.last_seen_unix.saturating_add(60) {
            entry.last_seen_unix = active_mtime;
            dirty = true;
        }
        // STRICT ZERO-MIXING GUARD + DIRTY CHECK:
        // Only overwrite & persist accounts.json when verified quota actually changed!
        if live_quota.error.is_none()
            && !live_quota.groups.is_empty()
            && is_valid_email(&live_quota.account_email)
            && live_quota.account_email.eq_ignore_ascii_case(active_email)
        {
            let quota_changed = match &entry.cached_quota {
                Some(prev) => {
                    prev.fetched_at != live_quota.fetched_at
                        || prev.source != live_quota.source
                        || prev.groups.len() != live_quota.groups.len()
                        || !prev.account_email.eq_ignore_ascii_case(&live_quota.account_email)
                }
                None => true,
            };
            if quota_changed {
                entry.cached_quota = Some(live_quota.clone());
                dirty = true;
            }
        }
    }

    if dirty {
        let _ = save_accounts_registry(paths, &registry);
    }

    let now_secs = current_unix_secs();
    let mut profiles: Vec<(i64, AccountProfile)> = registry
        .entries
        .values()
        .map(|rec| {
            let is_active =
                !active_email.is_empty() && rec.email.eq_ignore_ascii_case(active_email);

            let mut cached_q = if is_active
                && !live_quota.groups.is_empty()
                && live_quota.account_email.eq_ignore_ascii_case(&rec.email)
            {
                Some(live_quota.clone())
            } else {
                rec.cached_quota.clone()
            };
            if let Some(ref mut q) = cached_q {
                for g in &mut q.groups {
                    for b in &mut g.buckets {
                        b.reset_countdown =
                            format_reset_countdown(&b.reset_time, b.remaining_pct, now_secs);
                    }
                }
            }

            let (w_pct, h5_pct, summary_text, countdown, plan_label, credits, updated_at) =
                if let Some(ref q) = cached_q {
                    let (w, h5, txt, cd) = summarize_gemini_quota(q);
                    (
                        w,
                        h5,
                        txt,
                        cd,
                        if q.plan_label.is_empty() {
                            infer_plan_label(&rec.auth_method, &q.groups)
                        } else {
                            q.plan_label.clone()
                        },
                        Some(q.remaining_credits),
                        q.fetched_at.clone(),
                    )
                } else {
                    (
                        None,
                        None,
                        "等待同步".to_string(),
                        "点击刷新额度以获取实时余量".to_string(),
                        infer_plan_label(&rec.auth_method, &[]),
                        None,
                        String::new(),
                    )
                };

            let initial = rec
                .email
                .chars()
                .next()
                .unwrap_or('G')
                .to_uppercase()
                .to_string();

            let profile = AccountProfile {
                email: rec.email.clone(),
                initial,
                auth_method: rec.auth_method.clone(),
                plan_label,
                is_active,
                last_seen_at: if rec.last_seen_unix > 0 {
                    format_unix_display(rec.last_seen_unix)
                } else {
                    "--".to_string()
                },
                quota_summary_text: summary_text,
                weekly_remaining_pct: w_pct,
                five_hour_remaining_pct: h5_pct,
                reset_countdown: countdown,
                remaining_credits: credits,
                quota_updated_at: updated_at,
                cached_quota: cached_q,
            };
            (rec.last_seen_unix, profile)
        })
        .collect();

    profiles.sort_by(|a, b| {
        b.1.is_active
            .cmp(&a.1.is_active)
            .then_with(|| b.0.cmp(&a.0))
            .then_with(|| a.1.email.cmp(&b.1.email))
    });

    profiles.into_iter().map(|(_, p)| p).collect()
}

/// Permanently remove a non-active cached account record from `~/.config/agy-higher/accounts.json`.
pub fn remove_cached_account(
    paths: &CorePaths,
    email: &str,
    active_email: &str,
) -> Result<String, String> {
    let key = email.trim().to_lowercase();
    if key.is_empty() {
        return Err("账户邮箱不能为空".to_string());
    }
    if !active_email.is_empty() && key == active_email.trim().to_lowercase() {
        return Err("当前正在使用的 Antigravity 活跃账户不可移除".to_string());
    }
    let mut reg = load_accounts_registry(paths);
    if reg.entries.remove(&key).is_some() {
        save_accounts_registry(paths, &reg)?;
        Ok(format!("已永久移除缓存账户: {}", email))
    } else {
        Ok(format!("缓存中已无该账户: {}", email))
    }
}

/// Permanently clear all non-active cached accounts, keeping only the currently active Antigravity account.
pub fn clear_inactive_accounts(paths: &CorePaths, active_email: &str) -> Result<String, String> {
    let active_key = active_email.trim().to_lowercase();
    let mut reg = load_accounts_registry(paths);
    let before = reg.entries.len();
    reg.entries.retain(|k, _| !active_key.is_empty() && *k == active_key);
    let removed = before.saturating_sub(reg.entries.len());
    save_accounts_registry(paths, &reg)?;
    Ok(format!("已清理 {} 个历史非活跃账户缓存", removed))
}
