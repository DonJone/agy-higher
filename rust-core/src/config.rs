use crate::models::AppPreferences;
use crate::paths::CorePaths;
use std::fs::{self, File};
use std::io::Write;

/// Load local panel preferences strictly from `~/.config/agy-higher/config.json`.
pub fn load_preferences(paths: &CorePaths) -> AppPreferences {
    let p = paths.config_json_path();
    let Ok(raw) = fs::read_to_string(&p) else {
        return AppPreferences::default();
    };
    serde_json::from_str::<AppPreferences>(&raw).unwrap_or_default()
}

/// Atomically persist local panel preferences to `~/.config/agy-higher/config.json`.
pub fn save_preferences(paths: &CorePaths, prefs: &AppPreferences) -> Result<(), String> {
    let target = paths.config_json_path();
    paths.assert_safe_write_target(&target)?;

    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }

    let serialized = serde_json::to_string_pretty(prefs).map_err(|e| e.to_string())?;
    let tmp = target.with_extension("json.tmp");
    {
        let mut f = File::create(&tmp).map_err(|e| e.to_string())?;
        f.write_all(serialized.as_bytes()).map_err(|e| e.to_string())?;
    }
    fs::rename(&tmp, &target).map_err(|e| e.to_string())?;
    Ok(())
}
