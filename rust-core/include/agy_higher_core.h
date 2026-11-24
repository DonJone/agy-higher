#ifndef AGY_HIGHER_CORE_H
#define AGY_HIGHER_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize or re-initialize the pure Antigravity telemetry & quota core.
 * config_json: {"sandboxMode": false, "sandboxRoot": null}
 */
char *agy_higher_init(const char *config_json);

/**
 * Re-scan Antigravity Desktop projects, sessions, and active account (strictly read-only).
 */
char *agy_higher_refresh(void);

/**
 * Hydrate full native DB (gen_metadata + steps) telemetry for a specific session ID.
 */
char *agy_higher_focus_session(const char *session_id_str);

/**
 * Fetch live real quota, AI credits, and active model for the currently logged-in Antigravity account.
 */
char *agy_higher_refresh_live_quota(void);

/**
 * Update local panel preferences in ~/.config/agy-higher/config.json:
 * {"hideNonGeminiModels": true, "showMenuBarQuota": true, "themeMode": "dark",
 *  "showArchivedSessions": false, "l10nEnabled": false, "l10nKeepEnglishOptions": true}
 */
char *agy_higher_update_preferences(const char *req_json);

/**
 * Manage local account quota archive in ~/.config/agy-higher/accounts.json:
 * {"action": "sync_accounts"|"remove_cached"|"clear_inactive", "email": "..."}
 */
char *agy_higher_account_action(const char *req_json);

/**
 * Manage STE-STC Chinese localization extension & direct app.asar patch:
 * {"action": "rebuild"|"install_patch"|"uninstall_patch"|"restart_antigravity"|"ensure_custom_file"}
 */
char *agy_higher_l10n_action(const char *req_json);

/**
 * Free any string returned by agy_higher_* C-ABI functions.
 */
void agy_higher_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* AGY_HIGHER_CORE_H */
