use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApiResponse<T> {
    pub ok: bool,
    pub data: Option<T>,
    pub error: Option<String>,
}

impl<T> ApiResponse<T> {
    pub fn success(data: T) -> Self {
        Self {
            ok: true,
            data: Some(data),
            error: None,
        }
    }

    pub fn failure(err: impl Into<String>) -> Self {
        Self {
            ok: false,
            data: None,
            error: Some(err.into()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InitConfig {
    pub sandbox_mode: Option<bool>,
    pub sandbox_root: Option<String>,
}

fn default_true() -> bool {
    true
}

fn default_false() -> bool {
    false
}

fn default_theme() -> String {
    "dark".to_string()
}

/// Pure panel preferences stored strictly in `~/.config/agy-higher/config.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppPreferences {
    #[serde(default = "default_true")]
    pub hide_non_gemini_models: bool,
    #[serde(default = "default_true")]
    pub show_menu_bar_quota: bool,
    #[serde(default = "default_theme")]
    pub theme_mode: String,
    #[serde(default = "default_false")]
    pub show_archived_sessions: bool,
    #[serde(default = "default_false")]
    pub l10n_enabled: bool,
    #[serde(default = "default_true")]
    pub l10n_keep_english_options: bool,
}

impl Default for AppPreferences {
    fn default() -> Self {
        Self {
            hide_non_gemini_models: true,
            show_menu_bar_quota: true,
            theme_mode: "dark".to_string(),
            show_archived_sessions: false,
            l10n_enabled: false,
            l10n_keep_english_options: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeProject {
    pub id: String,
    pub name: String,
    pub folder_path: Option<String>,
    pub session_count: usize,
    pub total_steps: u32,
    pub last_modified: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ContextBreakdown {
    pub rules_k: u32,
    pub cache_k: u32,
    pub fresh_input_k: u32,
    pub output_k: u32,
    pub free_k: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolUsageStat {
    pub name: String,
    pub count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionTelemetry {
    pub id: String,
    pub short_id: String,
    pub project_id: String,
    pub project_name: String,
    pub cwd: String,
    pub short_path: String,
    pub workspace_paths: Vec<String>,
    pub title: String,
    pub preview: String,
    pub last_user_prompt: String,
    pub is_pinned: bool,
    #[serde(default)]
    pub is_starred: bool,
    #[serde(default)]
    pub is_archived: bool,
    #[serde(default)]
    pub tags: Vec<String>,
    pub status: String,
    pub is_live_active: bool,
    pub branch: String,
    pub workspace_rule_files: Vec<String>,
    pub artifact_files: Vec<String>,
    pub model: String,
    pub models_used: Vec<String>,
    pub ctx_used_tokens: u64,
    pub ctx_limit_tokens: u64,
    pub ctx_used_k: u32,
    pub ctx_total_k: u32,
    pub ctx_pct: u32,
    pub breakdown: ContextBreakdown,
    pub total_input_tokens: u64,
    pub total_cache_read_tokens: u64,
    pub total_output_tokens: u64,
    pub total_thinking_tokens: u64,
    pub cache_hit_pct: u32,
    pub cost_usd: f64,
    pub step_count: u32,
    pub llm_turns: u32,
    pub user_turns: u32,
    pub assistant_turns: u32,
    pub tool_call_count: u32,
    pub top_tools: Vec<ToolUsageStat>,
    pub checkpoint_count: u32,
    pub subagent_count: u32,
    pub telemetry_origin: String,
    pub created_at: String,
    pub last_modified: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaBucket {
    pub id: String,
    pub name: String,
    pub window: String,
    pub remaining_fraction: f64,
    pub remaining_pct: u32,
    pub reset_time: String,
    pub reset_countdown: String,
    pub description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaGroup {
    pub name: String,
    pub description: String,
    pub is_gemini: bool,
    pub buckets: Vec<QuotaBucket>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaSnapshot {
    pub source: String,
    pub account_email: String,
    pub auth_method: String,
    pub plan_label: String,
    pub active_model_id: String,
    pub active_model_label: String,
    pub remaining_credits: i64,
    pub upgrade_uri: String,
    pub description: String,
    pub groups: Vec<QuotaGroup>,
    pub fetched_at: String,
    pub is_cached: bool,
    pub error: Option<String>,
}

/// Antigravity account record stored strictly with non-sensitive metadata & public quota cache.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountProfile {
    pub email: String,
    pub initial: String,
    pub auth_method: String,
    pub plan_label: String,
    pub is_active: bool,
    pub last_seen_at: String,
    pub quota_summary_text: String,
    pub weekly_remaining_pct: Option<u32>,
    pub five_hour_remaining_pct: Option<u32>,
    pub reset_countdown: String,
    pub remaining_credits: Option<i64>,
    pub quota_updated_at: String,
    pub cached_quota: Option<QuotaSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct L10nStatus {
    pub antigravity_version: String,
    pub standard: String,
    pub dictionary_version: String,
    pub phrase_count: usize,
    pub custom_rule_count: usize,
    pub overlay_path: String,
    pub custom_file_path: String,
    pub overlay_ready: bool,
    pub bundle_sha_short: String,
    pub patch_installed: bool,
    pub patch_version: String,
    pub backup_exists: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DashboardSnapshot {
    pub sandbox_mode: bool,
    pub session_count: usize,
    pub projects: Vec<NativeProject>,
    pub sessions: Vec<SessionTelemetry>,
    pub quota: QuotaSnapshot,
    pub accounts: Vec<AccountProfile>,
    pub active_email: String,
    pub preferences: AppPreferences,
    pub l10n: L10nStatus,
    pub last_scanned_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdatePreferencesRequest {
    pub hide_non_gemini_models: Option<bool>,
    pub show_menu_bar_quota: Option<bool>,
    pub theme_mode: Option<String>,
    pub show_archived_sessions: Option<bool>,
    pub l10n_enabled: Option<bool>,
    pub l10n_keep_english_options: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountActionRequest {
    pub action: String,
    pub email: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct L10nActionRequest {
    pub action: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MutationResult {
    pub snapshot: DashboardSnapshot,
    pub message: String,
}
