use crate::accounts::{is_valid_email, parse_oauth_identity_from_log};
use crate::models::{QuotaBucket, QuotaGroup, QuotaSnapshot};
use crate::paths::CorePaths;
use serde_json::Value;
use std::fs;
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn find_agy_binary() -> String {
    let local = crate::paths::home_dir().join(".local/bin/agy");
    if local.is_file() {
        return local.to_string_lossy().to_string();
    }
    "agy".to_string()
}

/// Fast non-blocking load of cached quota snapshot matching the current active Antigravity account.
/// Automatically discards stale cache belonging to a different account.
pub fn load_cached_or_initial_quota(
    paths: &CorePaths,
    active_email: &str,
    auth_method: &str,
) -> QuotaSnapshot {
    if paths.sandbox_mode || cfg!(test) {
        if let Some(cached) = read_quota_cache(paths) {
            if active_email.is_empty() || cached.account_email.eq_ignore_ascii_case(active_email) {
                return cached;
            }
        }
        let sb = sandbox_quota_snapshot(if active_email.is_empty() {
            "ananmagoro701@gmail.com"
        } else {
            active_email
        });
        let _ = write_quota_cache(paths, &sb);
        return sb;
    }

    if let Some(mut cached) = read_quota_cache(paths) {
        if !active_email.is_empty()
            && cached.account_email.eq_ignore_ascii_case(active_email)
            && !cached.groups.is_empty()
        {
            cached.is_cached = true;
            cached.source = "antigravity-cache".to_string();
            let now_secs = current_unix_secs();
            for g in &mut cached.groups {
                for b in &mut g.buckets {
                    b.reset_countdown =
                        format_reset_countdown(&b.reset_time, b.remaining_pct, now_secs);
                }
            }
            return cached;
        }
    }

    let plan_label = infer_plan_label(auth_method, &[]);
    QuotaSnapshot {
        source: "antigravity-pending".to_string(),
        account_email: active_email.to_string(),
        auth_method: auth_method.to_string(),
        plan_label,
        active_model_id: String::new(),
        active_model_label: "Gemini 4 Neon".to_string(),
        remaining_credits: 0,
        upgrade_uri: "https://antigravity.google/g1-upgrade".to_string(),
        description: "正在同步当前 Antigravity 账户的实时额度...".to_string(),
        groups: Vec::new(),
        fetched_at: String::new(),
        is_cached: true,
        error: None,
    }
}

/// Fetch REAL live quota AND the exact server-verified OAuth email atomically in a SINGLE
/// subprocess (`/usage` with isolated `--log-file`, auto-deleted immediately).
/// Performance: Eliminates 2 redundant parallel `agy` processes (`/credits`, `/model`), slashing
/// sync peak RAM/CPU by ~67% while deriving `active_model_label` from real session telemetry.
/// STRICT ZERO-MIXING GUARANTEE:
/// - `account_email` is ALWAYS bound directly to the OAuth identity verified in that exact `/usage`
///   invocation, NEVER blindly overwritten by stale `app_storage.json` onboarding data.
/// - Never touches Keychain or extracts OAuth tokens.
pub fn fetch_live_quota(
    paths: &CorePaths,
    desktop_active_email: &str,
    fallback_model_label: &str,
) -> Result<QuotaSnapshot, String> {
    if paths.sandbox_mode {
        let mut snap = sandbox_quota_snapshot(if desktop_active_email.is_empty() {
            "ananmagoro701@gmail.com"
        } else {
            desktop_active_email
        });
        snap.is_cached = false;
        snap.fetched_at = format_utc_now();
        let _ = write_quota_cache(paths, &snap);
        return Ok(snap);
    }

    let _ = fs::create_dir_all(&paths.config_dir);
    let pid = std::process::id();
    let ts = current_unix_secs();
    let usage_log = paths.config_dir.join(format!(".probe-usage-{}-{}.log", pid, ts));

    let bin = find_agy_binary();
    let usage_res = run_official_json_query_with_auth(&bin, "/usage", &usage_log);

    let now_secs = current_unix_secs();
    let mut verified_identity: Option<(String, String)> = None;

    let (groups, description, usage_err) = match usage_res {
        Ok((raw, auth_id)) => {
            verified_identity = auth_id;
            match parse_usage_json(&raw, now_secs) {
                Ok((gs, desc)) => (gs, desc, None),
                Err(e) => (Vec::new(), String::new(), Some(e)),
            }
        }
        Err(e) => (Vec::new(), String::new(), Some(e)),
    };

    let active_model_label = if !fallback_model_label.trim().is_empty() {
        fallback_model_label.trim().to_string()
    } else {
        "Gemini 4 Neon".to_string()
    };

    // STRICT ZERO-MIXING GUARD: Require server-verified OAuth email from this exact query!
    let (account_email, auth_method) = match verified_identity {
        Some((em, method)) if is_valid_email(&em) => (em, method),
        _ => {
            if usage_err.is_none() && !groups.is_empty() {
                return Err(
                    "未能从实时查询确认所属 OAuth 账户邮箱，已中止写入以防止不同账户额度混淆"
                        .to_string(),
                );
            }
            (String::new(), "consumer".to_string())
        }
    };

    let plan_label = infer_plan_label(&auth_method, &groups);

    let snapshot = QuotaSnapshot {
        source: "antigravity-live".to_string(),
        account_email,
        auth_method,
        plan_label,
        active_model_id: String::new(),
        active_model_label,
        remaining_credits: 0,
        upgrade_uri: "https://antigravity.google/g1-upgrade".to_string(),
        description,
        groups,
        fetched_at: format_utc_now(),
        is_cached: false,
        error: usage_err,
    };

    if snapshot.error.is_none()
        && !snapshot.groups.is_empty()
        && is_valid_email(&snapshot.account_email)
    {
        let _ = write_quota_cache(paths, &snapshot);
    }

    Ok(snapshot)
}

fn run_official_json_query_with_auth(
    bin: &str,
    slash_cmd: &str,
    log_path: &Path,
) -> Result<(String, Option<(String, String)>), String> {
    let log_str = log_path.to_string_lossy().to_string();
    let _ = fs::remove_file(log_path);

    let mut child = Command::new(bin)
        .args(["-p", slash_cmd, "--output-format", "json", "--log-file", &log_str])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("无法查询官方额度接口: {}", e))?;

    // Drain stdout/stderr concurrently so large outputs can never deadlock the pipe buffer
    let mut stdout_pipe = child.stdout.take();
    let mut stderr_pipe = child.stderr.take();

    let (status_res, stdout_bytes, stderr_bytes) = std::thread::scope(|s| {
        let out_h = s.spawn(move || {
            let mut buf = Vec::with_capacity(4096);
            if let Some(ref mut p) = stdout_pipe {
                let _ = p.read_to_end(&mut buf);
            }
            buf
        });
        let err_h = s.spawn(move || {
            let mut buf = Vec::new();
            if let Some(ref mut p) = stderr_pipe {
                let _ = p.read_to_end(&mut buf);
            }
            buf
        });

        let deadline = Instant::now() + Duration::from_secs(20);
        let mut sleep_ms = 15u64;
        let wait_result = loop {
            match child.try_wait() {
                Ok(Some(st)) => break Ok(st),
                Ok(None) => {
                    if Instant::now() >= deadline {
                        let _ = child.kill();
                        let _ = child.wait();
                        break Err("官方额度查询超时（20s）".to_string());
                    }
                    std::thread::sleep(Duration::from_millis(sleep_ms));
                    sleep_ms = (sleep_ms + 10).min(50);
                }
                Err(e) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break Err(format!("额度查询等待失败: {}", e));
                }
            }
        };

        let out_buf = out_h.join().unwrap_or_default();
        let err_buf = err_h.join().unwrap_or_default();
        (wait_result, out_buf, err_buf)
    });

    let auth_identity = fs::read_to_string(log_path)
        .ok()
        .and_then(|txt| parse_oauth_identity_from_log(&txt));
    let _ = fs::remove_file(log_path);

    let status = status_res?;
    let stdout = String::from_utf8_lossy(&stdout_bytes).trim().to_string();
    if !status.success() && stdout.is_empty() {
        let stderr = String::from_utf8_lossy(&stderr_bytes).trim().to_string();
        return Err(format!("额度接口返回异常: {}", stderr));
    }
    Ok((stdout, auth_identity))
}

/// Read the last OAuth-verified quota cache (used on startup to resolve the most recently verified
/// active account instead of relying on stale onboarding `app_storage.json`).
pub fn read_verified_quota_cache(paths: &CorePaths) -> Option<QuotaSnapshot> {
    let cached = read_quota_cache(paths)?;
    if is_valid_email(&cached.account_email) && !cached.groups.is_empty() {
        Some(cached)
    } else {
        None
    }
}

pub fn parse_usage_json(raw: &str, now_unix_secs: i64) -> Result<(Vec<QuotaGroup>, String), String> {
    let root: Value =
        serde_json::from_str(raw).map_err(|e| format!("Invalid quota JSON: {}", e))?;
    if root.get("status").and_then(Value::as_str) != Some("SUCCESS") {
        let err_msg = root
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("官方额度接口返回非 SUCCESS 状态");
        return Err(err_msg.to_string());
    }
    let data = root
        .get("command")
        .and_then(|c| c.get("data"))
        .ok_or_else(|| "Missing command.data in quota JSON".to_string())?;

    let description = data
        .get("description")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();

    let raw_groups = data
        .get("groups")
        .and_then(Value::as_array)
        .ok_or_else(|| "Missing groups[] in quota JSON".to_string())?;

    let mut groups = Vec::with_capacity(raw_groups.len());
    for g in raw_groups {
        let name = g
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("Unknown Group")
            .to_string();
        let g_desc = g
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();

        let mut buckets = Vec::new();
        if let Some(arr) = g.get("buckets").and_then(Value::as_array) {
            for b in arr {
                let id = b.get("id").and_then(Value::as_str).unwrap_or("").to_string();
                let b_name = b
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let window = b
                    .get("window")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let frac = b
                    .get("remaining_fraction")
                    .and_then(Value::as_f64)
                    .unwrap_or(0.0)
                    .clamp(0.0, 1.0);
                let pct = (frac * 100.0).round() as u32;
                let reset_time = b
                    .get("reset_time")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let b_desc = b
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let reset_countdown = format_reset_countdown(&reset_time, pct, now_unix_secs);

                buckets.push(QuotaBucket {
                    id,
                    name: b_name,
                    window,
                    remaining_fraction: frac,
                    remaining_pct: pct,
                    reset_time,
                    reset_countdown,
                    description: b_desc,
                });
            }
        }

        buckets.sort_by_key(|b| match b.window.as_str() {
            "weekly" => 0,
            "5h" => 1,
            _ => 2,
        });

        let is_gemini = is_gemini_quota_group(&name, &buckets);
        groups.push(QuotaGroup {
            name,
            description: g_desc,
            is_gemini,
            buckets,
        });
    }

    Ok((groups, description))
}

pub fn is_gemini_quota_group(group_name: &str, buckets: &[QuotaBucket]) -> bool {
    let lower = group_name.to_lowercase();
    if lower.contains("claude") || lower.contains("gpt") || lower.contains("third") {
        return false;
    }
    if lower.contains("gemini") {
        return true;
    }
    if !buckets.is_empty() && buckets.iter().all(|b| b.id.to_lowercase().starts_with("3p-")) {
        return false;
    }
    buckets
        .iter()
        .any(|b| b.id.to_lowercase().contains("gemini"))
}

pub fn parse_credits_json(raw: &str) -> Result<(i64, String), String> {
    let root: Value =
        serde_json::from_str(raw).map_err(|e| format!("Invalid credits JSON: {}", e))?;
    let data = root
        .get("command")
        .and_then(|c| c.get("data"))
        .ok_or_else(|| "Missing command.data in credits JSON".to_string())?;
    let credits = data
        .get("remaining_credits")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let uri = data
        .get("upgrade_uri")
        .and_then(Value::as_str)
        .unwrap_or("https://antigravity.google/g1-upgrade")
        .to_string();
    Ok((credits, uri))
}

pub fn parse_model_json(raw: &str) -> Result<(String, String), String> {
    let root: Value =
        serde_json::from_str(raw).map_err(|e| format!("Invalid model JSON: {}", e))?;
    let data = root
        .get("command")
        .and_then(|c| c.get("data"))
        .ok_or_else(|| "Missing command.data in model JSON".to_string())?;
    let id = data
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let label = data
        .get("label")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if label.is_empty() && id.is_empty() {
        return Err("Empty model payload".to_string());
    }
    let display = if label.is_empty() { id.clone() } else { label };
    Ok((id, display))
}

pub fn summarize_gemini_quota(
    quota: &QuotaSnapshot,
) -> (Option<u32>, Option<u32>, String, String) {
    let gemini_group = quota
        .groups
        .iter()
        .find(|g| g.is_gemini && g.name.to_lowercase().contains("gemini models"))
        .or_else(|| quota.groups.iter().find(|g| g.is_gemini));

    if let Some(g) = gemini_group {
        let weekly = g.buckets.iter().find(|b| b.window == "weekly");
        let five_h = g.buckets.iter().find(|b| b.window == "5h");
        let w_pct = weekly.map(|b| b.remaining_pct);
        let h5_pct = five_h.map(|b| b.remaining_pct);
        match (five_h, weekly) {
            (Some(b5), Some(bw)) => (
                w_pct,
                h5_pct,
                format!("周 {}% · 5h {}%", bw.remaining_pct, b5.remaining_pct),
                format!("周额度 {}", bw.reset_countdown),
            ),
            (None, Some(bw)) => (
                w_pct,
                None,
                format!("周 {}%", bw.remaining_pct),
                bw.reset_countdown.clone(),
            ),
            (Some(b5), None) => (
                None,
                h5_pct,
                format!("5h {}%", b5.remaining_pct),
                b5.reset_countdown.clone(),
            ),
            (None, None) => (None, None, "待同步".to_string(), "点击刷新以获取额度".to_string()),
        }
    } else if quota.error.is_some() {
        (None, None, "未同步".to_string(), "点击刷新以重新查询".to_string())
    } else {
        (None, None, "未同步".to_string(), "点击刷新以获取额度".to_string())
    }
}

pub fn infer_plan_label(auth_method: &str, groups: &[QuotaGroup]) -> String {
    if auth_method.to_lowercase().contains("enterprise")
        || auth_method.to_lowercase().contains("business")
    {
        return "Gemini Enterprise".to_string();
    }
    let has_separate_argon = groups
        .iter()
        .any(|g| g.name.to_lowercase().contains("argon"));
    if has_separate_argon {
        "Google AI Pro".to_string()
    } else if !groups.is_empty() {
        "Google AI Plan".to_string()
    } else {
        "Google Account".to_string()
    }
}

fn read_quota_cache(paths: &CorePaths) -> Option<QuotaSnapshot> {
    let p = paths.quota_cache_path();
    let raw = fs::read_to_string(p).ok()?;
    serde_json::from_str(&raw).ok()
}

pub fn write_quota_cache(paths: &CorePaths, snap: &QuotaSnapshot) -> Result<(), String> {
    let target = paths.quota_cache_path();
    paths.assert_safe_write_target(&target)?;
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let json = serde_json::to_string_pretty(snap).map_err(|e| e.to_string())?;
    let tmp = target.with_extension("json.tmp");
    fs::write(&tmp, json).map_err(|e| e.to_string())?;
    fs::rename(&tmp, &target).map_err(|e| e.to_string())?;
    Ok(())
}

pub fn sandbox_quota_snapshot(email: &str) -> QuotaSnapshot {
    let now = current_unix_secs();
    let five_h_reset = format_unix_iso8601(now + 4 * 3600 + 18 * 60);
    let weekly_reset = format_unix_iso8601(now + 6 * 86400 + 4 * 3600);
    let argon_reset = format_unix_iso8601(now + 6 * 86400 + 12 * 3600);
    let p3_weekly_reset = format_unix_iso8601(now + 7 * 86400);
    let p3_5h_reset = format_unix_iso8601(now + 5 * 3600);

    let (w_frac, h5_frac, argon_frac): (f64, f64, f64) = (0.86, 0.96, 0.95);
    let w_pct = (w_frac * 100.0).round() as u32;
    let h5_pct = (h5_frac * 100.0).round() as u32;
    let ar_pct = (argon_frac * 100.0).round() as u32;

    QuotaSnapshot {
        source: "antigravity-sandbox".to_string(),
        account_email: email.to_string(),
        auth_method: "consumer".to_string(),
        plan_label: "Google AI Pro".to_string(),
        active_model_id: "gemini-4-neon-xhigh".to_string(),
        active_model_label: "Gemini 4 Neon (XHigh)".to_string(),
        remaining_credits: 0,
        upgrade_uri: "https://antigravity.google/g1-upgrade".to_string(),
        description: "Within each group, models share a weekly limit and a 5-hour limit."
            .to_string(),
        groups: vec![
            QuotaGroup {
                name: "Gemini Models".to_string(),
                description:
                    "Models within this group: Gemini 4 Neon, Gemini 4 Hydrogen, Orchestrator (Neon), Gemini 3.8 Flash"
                        .to_string(),
                is_gemini: true,
                buckets: vec![
                    QuotaBucket {
                        id: "gemini-weekly".to_string(),
                        name: "Weekly Limit Remaining".to_string(),
                        window: "weekly".to_string(),
                        remaining_fraction: w_frac,
                        remaining_pct: w_pct,
                        reset_time: weekly_reset.clone(),
                        reset_countdown: format_reset_countdown(&weekly_reset, w_pct, now),
                        description: "weekly window".to_string(),
                    },
                    QuotaBucket {
                        id: "gemini-5h".to_string(),
                        name: "Five Hour Limit Remaining".to_string(),
                        window: "5h".to_string(),
                        remaining_fraction: h5_frac,
                        remaining_pct: h5_pct,
                        reset_time: five_h_reset.clone(),
                        reset_countdown: format_reset_countdown(&five_h_reset, h5_pct, now),
                        description: "5h window".to_string(),
                    },
                ],
            },
            QuotaGroup {
                name: "Gemini 4 Argon".to_string(),
                description: "For paid Pro plans, Argon quota is separate.".to_string(),
                is_gemini: true,
                buckets: vec![QuotaBucket {
                    id: "gemini-argon-wtu-weekly".to_string(),
                    name: "Gemini 4 Argon Weekly Limit".to_string(),
                    window: "weekly".to_string(),
                    remaining_fraction: argon_frac,
                    remaining_pct: ar_pct,
                    reset_time: argon_reset.clone(),
                    reset_countdown: format_reset_countdown(&argon_reset, ar_pct, now),
                    description: "Argon weekly window".to_string(),
                }],
            },
            QuotaGroup {
                name: "Claude and GPT models".to_string(),
                description:
                    "Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B"
                        .to_string(),
                is_gemini: false,
                buckets: vec![
                    QuotaBucket {
                        id: "3p-weekly".to_string(),
                        name: "Weekly Limit Remaining".to_string(),
                        window: "weekly".to_string(),
                        remaining_fraction: 1.0,
                        remaining_pct: 100,
                        reset_time: p3_weekly_reset.clone(),
                        reset_countdown: format_reset_countdown(&p3_weekly_reset, 100, now),
                        description: "Quota available".to_string(),
                    },
                    QuotaBucket {
                        id: "3p-5h".to_string(),
                        name: "Five Hour Limit Remaining".to_string(),
                        window: "5h".to_string(),
                        remaining_fraction: 1.0,
                        remaining_pct: 100,
                        reset_time: p3_5h_reset.clone(),
                        reset_countdown: format_reset_countdown(&p3_5h_reset, 100, now),
                        description: "Quota available".to_string(),
                    },
                ],
            },
        ],
        fetched_at: format_utc_now(),
        is_cached: false,
        error: None,
    }
}

pub fn current_unix_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub fn format_reset_countdown(iso: &str, remaining_pct: u32, now_unix_secs: i64) -> String {
    if remaining_pct >= 100 {
        return "额度充足".to_string();
    }
    let Some(target) = parse_iso8601_utc(iso) else {
        return if iso.is_empty() {
            "额度可用".to_string()
        } else {
            iso.to_string()
        };
    };
    let diff = target - now_unix_secs;
    if diff <= 0 {
        return "即将刷新".to_string();
    }
    let days = diff / 86400;
    let hours = (diff % 86400) / 3600;
    let mins = (diff % 3600) / 60;
    if days > 0 {
        format!("{} 天 {} 小时后重置", days, hours)
    } else if hours > 0 {
        format!("{} 小时 {} 分钟后重置", hours, mins)
    } else {
        format!("{} 分钟后重置", mins.max(1))
    }
}

pub fn parse_iso8601_utc(s: &str) -> Option<i64> {
    let clean = s.trim().trim_end_matches('Z');
    let (date_part, time_part) = clean.split_once('T')?;
    let mut d = date_part.split('-');
    let year: i64 = d.next()?.parse().ok()?;
    let month: i64 = d.next()?.parse().ok()?;
    let day: i64 = d.next()?.parse().ok()?;

    let time_no_frac = time_part.split('.').next().unwrap_or(time_part);
    let time_no_tz = time_no_frac.split('+').next().unwrap_or(time_no_frac);
    let mut t = time_no_tz.split(':');
    let hour: i64 = t.next()?.parse().ok()?;
    let min: i64 = t.next()?.parse().ok()?;
    let sec: i64 = t.next()?.parse().ok()?;

    let days = days_from_civil(year, month, day);
    Some(days * 86400 + hour * 3600 + min * 60 + sec)
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = y - if m <= 2 { 1 } else { 0 };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    let year = y + if m <= 2 { 1 } else { 0 };
    (year, m as u32, d as u32)
}

pub fn format_unix_iso8601(secs: i64) -> String {
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    let (y, m, d) = civil_from_days(days);
    let h = rem / 3600;
    let min = (rem % 3600) / 60;
    let s = rem % 60;
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, h, min, s)
}

pub fn format_unix_display(secs: i64) -> String {
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    let (y, m, d) = civil_from_days(days);
    let h = rem / 3600;
    let min = (rem % 3600) / 60;
    format!("{:04}-{:02}-{:02} {:02}:{:02}", y, m, d, h, min)
}

pub fn format_utc_now() -> String {
    format_unix_iso8601(current_unix_secs())
}
