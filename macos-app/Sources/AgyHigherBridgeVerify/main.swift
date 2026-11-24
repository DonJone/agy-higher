import CAgyHigherCore
import Foundation

func callAndDecode(_ rawPtr: UnsafeMutablePointer<CChar>?) -> [String: Any] {
    guard let ptr = rawPtr else {
        fputs("FAIL: null pointer from Rust core\n", stderr)
        exit(1)
    }
    defer { agy_higher_string_free(ptr) }
    let text = String(cString: ptr)
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("FAIL: invalid JSON from Rust core: \(text.prefix(200))\n", stderr)
        exit(1)
    }
    return obj
}

func assertTrue(_ cond: Bool, _ label: String) {
    if !cond {
        fputs("FAIL: \(label)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

let sbRoot = "/Users/don/git/agy-higher/.dev-sandbox/swift-bridge-v3"
try? FileManager.default.removeItem(atPath: sbRoot)

// 1. Initialize pure Antigravity Desktop v3 engine in isolated sandbox
let initJSON = "{\"sandboxMode\":true,\"sandboxRoot\":\"\(sbRoot)\"}"
let initResp = initJSON.withCString { callAndDecode(agy_higher_init($0)) }
assertTrue(initResp["ok"] as? Bool == true, "agy_higher_init ok=true")
let snap = initResp["data"] as! [String: Any]
assertTrue(snap["sandboxMode"] as? Bool == true, "sandboxMode=true")
assertTrue((snap["sessionCount"] as? Int ?? 0) == 4, "pure Antigravity Desktop sessionCount=4 (CLI mirrored excluded)")
assertTrue(snap["activeEmail"] as? String == "ananmagoro701@gmail.com", "activeEmail=ananmagoro701@gmail.com")

// Verify ZERO unlogged/CLI accounts on initial scan
let initialAccounts = snap["accounts"] as! [[String: Any]]
assertTrue(initialAccounts.count == 1, "only 1 active Antigravity Desktop account detected (zero CLI accounts)")
assertTrue(initialAccounts[0]["email"] as? String == "ananmagoro701@gmail.com", "account[0]=ananmagoro701@gmail.com")
assertTrue(initialAccounts[0]["isActive"] as? Bool == true, "account[0].isActive=true")

// 2. Verify real protobuf gen_metadata telemetry hydrated
let sessions = snap["sessions"] as! [[String: Any]]
let donby = sessions.first(where: { ($0["id"] as? String) == "db17f36d-3b3d-5e57-92da-75713ee65f8a" })!
assertTrue(donby["telemetryOrigin"] as? String == "db+gen_metadata", "native DB gen_metadata telemetry extracted")
assertTrue((donby["ctxUsedTokens"] as? Int ?? 0) == 192643, "exact ctxUsedTokens=192643")
assertTrue((donby["ctxLimitTokens"] as? Int ?? 0) == 512000, "exact ctxLimitTokens=512000")
assertTrue((donby["totalThinkingTokens"] as? Int ?? 0) > 0, "thinking tokens extracted")

// 3. Focus session & refresh live quota (sandbox)
let focusResp = "856cfb36-8824-4a51-b9c0-112233445566".withCString { callAndDecode(agy_higher_focus_session($0)) }
assertTrue(focusResp["ok"] as? Bool == true, "agy_higher_focus_session ok=true")

let quotaResp = callAndDecode(agy_higher_refresh_live_quota())
assertTrue(quotaResp["ok"] as? Bool == true, "agy_higher_refresh_live_quota ok=true")

// 4. Preferences update (hideNonGeminiModels + showMenuBarQuota + themeMode)
let prefJSON = "{\"hideNonGeminiModels\":false,\"showMenuBarQuota\":false,\"themeMode\":\"light\"}"
let prefResp = prefJSON.withCString { callAndDecode(agy_higher_update_preferences($0)) }
assertTrue(prefResp["ok"] as? Bool == true, "agy_higher_update_preferences ok=true")
let prefSnap = (prefResp["data"] as! [String: Any])["snapshot"] as! [String: Any]
let prefs = prefSnap["preferences"] as! [String: Any]
assertTrue(prefs["hideNonGeminiModels"] as? Bool == false, "hideNonGeminiModels persisted=false")
assertTrue(prefs["showMenuBarQuota"] as? Bool == false, "showMenuBarQuota persisted=false")
assertTrue(prefs["themeMode"] as? String == "light", "themeMode persisted=light")

// 5. Seed stale + corrupt cached accounts into sandbox accounts.json, then verify auto-purge + remove_cached + clear_inactive
let accountsPath = "\(sbRoot)/v3/agy-higher-config/accounts.json"
let pollutedAccountsJSON = """
{
  "entries": {
    "ananmagoro701@gmail.com": {
      "email": "ananmagoro701@gmail.com",
      "authMethod": "consumer",
      "lastSeenUnix": 1795400000,
      "cachedQuota": null
    },
    "old-one@gmail.com": {
      "email": "old-one@gmail.com",
      "authMethod": "consumer",
      "lastSeenUnix": 1795300000,
      "cachedQuota": null
    },
    "old-two@gmail.com": {
      "email": "old-two@gmail.com",
      "authMethod": "consumer",
      "lastSeenUnix": 1795200000,
      "cachedQuota": null
    },
    "corrupt@gmail.cI1116 21:15:37 hooks_manager.go:54]": {
      "email": "corrupt@gmail.cI1116 21:15:37 hooks_manager.go:54]",
      "authMethod": "consumer",
      "lastSeenUnix": 1795100000,
      "cachedQuota": null
    }
  }
}
"""
try pollutedAccountsJSON.write(toFile: accountsPath, atomically: true, encoding: .utf8)

let afterSeedResp = callAndDecode(agy_higher_refresh())
let seededAccounts = (afterSeedResp["data"] as! [String: Any])["accounts"] as! [[String: Any]]
assertTrue(seededAccounts.count == 3, "corrupt log email auto-purged on refresh (3 valid accounts remain)")

// 6. Test remove_cached permanently deletes and does NOT resurrect on refresh
let remJSON = "{\"action\":\"remove_cached\",\"email\":\"old-one@gmail.com\"}"
let remResp = remJSON.withCString { callAndDecode(agy_higher_account_action($0)) }
assertTrue(remResp["ok"] as? Bool == true, "remove_cached ok=true")
let afterRemRefresh = callAndDecode(agy_higher_refresh())
let remAccounts = (afterRemRefresh["data"] as! [String: Any])["accounts"] as! [[String: Any]]
assertTrue(remAccounts.count == 2, "removed account stayed deleted after refresh (2 accounts remain)")

// 7. Test refusing removal of currently active account
let remActiveJSON = "{\"action\":\"remove_cached\",\"email\":\"ananmagoro701@gmail.com\"}"
let remActiveResp = remActiveJSON.withCString { callAndDecode(agy_higher_account_action($0)) }
assertTrue(remActiveResp["ok"] as? Bool == false, "refuses removing currently active account")

// 8. Test clear_inactive removes all remaining non-active cached accounts
let clearJSON = "{\"action\":\"clear_inactive\"}"
let clearResp = clearJSON.withCString { callAndDecode(agy_higher_account_action($0)) }
assertTrue(clearResp["ok"] as? Bool == true, "clear_inactive ok=true")
let clearAccounts = ((clearResp["data"] as! [String: Any])["snapshot"] as! [String: Any])["accounts"] as! [[String: Any]]
assertTrue(clearAccounts.count == 1, "clear_inactive leaves only the 1 active account")

// 9. Test sync_accounts succeeds cleanly
let syncJSON = "{\"action\":\"sync_accounts\"}"
let syncResp = syncJSON.withCString { callAndDecode(agy_higher_account_action($0)) }
assertTrue(syncResp["ok"] as? Bool == true, "sync_accounts ok=true")

// 10. Verify v2.35.0 annotations (starred, tags, archived toggle) + STE-STC l10n rebuild
assertTrue(donby["isStarred"] as? Bool == true, "v2.35.0 annotation starred=true parsed")
assertTrue((donby["tags"] as? [String]) == ["core", "v2.35"], "v2.35.0 annotation tags parsed")

let showArchJSON = "{\"showArchivedSessions\":true,\"l10nEnabled\":true,\"l10nKeepEnglishOptions\":true}"
let showArchResp = showArchJSON.withCString { callAndDecode(agy_higher_update_preferences($0)) }
assertTrue(showArchResp["ok"] as? Bool == true, "showArchivedSessions + l10nEnabled update ok=true")
let archSnap = (showArchResp["data"] as! [String: Any])["snapshot"] as! [String: Any]
assertTrue((archSnap["sessionCount"] as? Int ?? 0) == 5, "showArchivedSessions=true reveals archived conversation (sessionCount=5)")

let l10nEnsureResp = "{\"action\":\"ensure_custom_file\"}".withCString { callAndDecode(agy_higher_l10n_action($0)) }
assertTrue(l10nEnsureResp["ok"] as? Bool == true, "agy_higher_l10n_action ensure_custom_file ok=true")
let l10nRebuildResp = "{\"action\":\"rebuild\"}".withCString { callAndDecode(agy_higher_l10n_action($0)) }
assertTrue(l10nRebuildResp["ok"] as? Bool == true, "agy_higher_l10n_action rebuild ok=true")
let l10nInfo = ((l10nRebuildResp["data"] as! [String: Any])["snapshot"] as! [String: Any])["l10n"] as! [String: Any]
assertTrue(l10nInfo["overlayReady"] as? Bool == true, "STE-STC overlay built and ready")
assertTrue((l10nInfo["phraseCount"] as? Int ?? 0) > 100, "STE-STC dictionary phraseCount > 100")

print("ALL V2.35 + STE-STC SWIFT <-> RUST BRIDGE CHECKS PASSED (28/28)")
