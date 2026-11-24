import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI

enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case available(AppReleaseInfo)
    case downloading(release: AppReleaseInfo, progress: Double, downloadedBytes: Int64, totalBytes: Int64)
    case verifying(release: AppReleaseInfo)
    case readyToInstall(release: AppReleaseInfo, packageURL: URL, canSelfReplace: Bool)
    case installing(release: AppReleaseInfo)
    case error(message: String)
}

/// Battle-tested native macOS auto-updater (incorporating all Donby release lessons):
/// - Dual channels (Stable / Pre-release) + static `latest.json` fallback (zero GitHub REST rate-limit failures)
/// - Streaming download with SHA-256 verification
/// - Prefers `.app.zip` over `.dmg` for fast zero-mount extraction via `ditto`
/// - Double-forked POSIX_SPAWN_SETSID worker preserves top-level `.app` inode (zero duplicate Dock icons),
///   clears quarantine xattr, refreshes LaunchServices, rolls back on failure, and relaunches cleanly.
@MainActor
final class AppUpdateManager: ObservableObject {
    static let shared = AppUpdateManager()
    static let githubRepo = "DonJone/agy-higher"
    static let githubLatestReleaseAPI = URL(string: "https://api.github.com/repos/DonJone/agy-higher/releases/latest")!
    static let githubReleasesListAPI = URL(string: "https://api.github.com/repos/DonJone/agy-higher/releases?per_page=15")!
    static let githubStaticManifestURL = URL(string: "https://github.com/DonJone/agy-higher/releases/latest/download/latest.json")!
    static let githubReleasesPageURL = URL(string: "https://github.com/DonJone/agy-higher/releases")!

    @Published private(set) var state: AppUpdateState = .idle
    @Published private(set) var availableRelease: AppReleaseInfo? = nil
    @Published var autoCheckEnabled: Bool {
        didSet { UserDefaults.standard.set(autoCheckEnabled, forKey: "agyHigher.autoCheckForUpdates") }
    }
    @Published var updateChannel: AppUpdateChannel {
        didSet { UserDefaults.standard.set(updateChannel.rawValue, forKey: "agyHigher.updateChannel") }
    }

    private var lastCheckTimestamp: Double {
        get { UserDefaults.standard.double(forKey: "agyHigher.lastUpdateCheckTimestamp") }
        set { UserDefaults.standard.set(newValue, forKey: "agyHigher.lastUpdateCheckTimestamp") }
    }

    private var activeDownloadTask: Task<Void, Never>? = nil
    private var didAutoCheckThisSession: Bool = false

    private init() {
        if UserDefaults.standard.object(forKey: "agyHigher.autoCheckForUpdates") == nil {
            self.autoCheckEnabled = true
        } else {
            self.autoCheckEnabled = UserDefaults.standard.bool(forKey: "agyHigher.autoCheckForUpdates")
        }
        let rawChannel = UserDefaults.standard.string(forKey: "agyHigher.updateChannel") ?? AppUpdateChannel.stable.rawValue
        self.updateChannel = AppUpdateChannel(rawValue: rawChannel) ?? .stable
    }

    static var currentVersion: String {
        AgyHigherAppInfo.version
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing:
            return true
        default:
            return false
        }
    }

    var statusSummaryText: String {
        switch state {
        case .idle:
            return "当前 v\(Self.currentVersion)"
        case .checking:
            return "正在检查更新..."
        case .upToDate(let cur):
            return "已是最新版本 v\(cur)"
        case .available(let rel):
            return "发现新版本 v\(rel.version)\(rel.isPrerelease ? " (预览版)" : "")"
        case .downloading(_, let progress, let done, let total):
            let pct = Int((progress * 100).rounded())
            return "正在下载 \(pct)% (\(formatBytes(done)) / \(formatBytes(total)))"
        case .verifying:
            return "正在校验 SHA-256..."
        case .readyToInstall(let rel, _, let canReplace):
            return canReplace ? "v\(rel.version) 已就绪，正在替换..." : "已下载 v\(rel.version)，请手动拖入应用程序"
        case .installing(let rel):
            return "正在安装 v\(rel.version) 并重启..."
        case .error(let msg):
            return msg
        }
    }

    func checkForUpdatesIfAutoEnabled() async {
        guard autoCheckEnabled, !didAutoCheckThisSession else { return }
        didAutoCheckThisSession = true
        await checkForUpdates(manual: false)
    }

    func checkForUpdates(manual: Bool) async {
        guard !isBusy else { return }
        state = .checking
        if manual {
            didAutoCheckThisSession = true
        }

        do {
            guard let release = try await fetchLatestReleaseInfo() else {
                lastCheckTimestamp = Date().timeIntervalSince1970
                availableRelease = nil
                state = .upToDate(currentVersion: Self.currentVersion)
                return
            }
            lastCheckTimestamp = Date().timeIntervalSince1970

            if AppVersionComparator.isVersion(release.version, newerThan: Self.currentVersion) {
                availableRelease = release
                state = .available(release)
            } else {
                availableRelease = nil
                state = .upToDate(currentVersion: Self.currentVersion)
            }
        } catch {
            if manual {
                state = .error(message: "检查更新失败: \(error.localizedDescription)")
            } else {
                state = availableRelease.map { .available($0) } ?? .idle
            }
        }
    }

    private func fetchLatestReleaseInfo() async throws -> AppReleaseInfo? {
        let preferredArch: String = {
            #if arch(arm64)
            return "arm64"
            #else
            return "x86_64"
            #endif
        }()

        if updateChannel == .prerelease {
            var listReq = URLRequest(url: Self.githubReleasesListAPI, timeoutInterval: 10)
            listReq.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            listReq.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            listReq.setValue("AgyHigher/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

            if let (data, response) = try? await URLSession.shared.data(for: listReq),
               let http = response as? HTTPURLResponse {
                if http.statusCode == 404 { return nil }
                if (200...299).contains(http.statusCode),
                   let parsed = try? AppVersionComparator.parseGitHubReleasesList(
                       data: data,
                       preferredArch: preferredArch,
                       includePrereleases: true
                   ) {
                    return parsed
                }
            }
        }

        var req = URLRequest(url: Self.githubLatestReleaseAPI, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("AgyHigher/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        if let (data, response) = try? await URLSession.shared.data(for: req),
           let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }
            if (200...299).contains(http.statusCode),
               let parsed = try? AppVersionComparator.parseGitHubLatestRelease(data: data, preferredArch: preferredArch) {
                return parsed
            }
        }

        // Static release manifest fallback avoids GitHub REST API rate limits (403/429)
        var staticReq = URLRequest(url: Self.githubStaticManifestURL, timeoutInterval: 12)
        staticReq.setValue("AgyHigher/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (manifestData, manifestResp) = try await URLSession.shared.data(for: staticReq)
        guard let http = manifestResp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "AgyHigherUpdater", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "GitHub 更新源返回状态码 \(http.statusCode)"
            ])
        }
        return try AppVersionComparator.parseStaticManifestJSON(data: manifestData)
    }

    func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        if let release = availableRelease {
            state = .available(release)
        } else {
            state = .idle
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(availableRelease?.htmlURL ?? Self.githubReleasesPageURL)
    }

    func startDownloadAndInstall(_ release: AppReleaseInfo) {
        if isBusy {
            guard case .downloading(let active, _, _, _) = state, active.tagName != release.tagName else { return }
        }
        guard let asset = release.preferredUpdateAsset else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }

        activeDownloadTask?.cancel()
        state = .downloading(release: release, progress: 0, downloadedBytes: 0, totalBytes: asset.size)

        activeDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cachesBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let updatesDir = cachesBase
                    .appendingPathComponent("AgyHigherUpdates", isDirectory: true)
                    .appendingPathComponent(release.tagName, isDirectory: true)
                try FileManager.default.createDirectory(at: updatesDir, withIntermediateDirectories: true)
                let destPackage = updatesDir.appendingPathComponent(asset.name)

                if !Self.verifyExistingCachedPackage(destPackage, expectedSize: asset.size) {
                    try? FileManager.default.removeItem(at: destPackage)
                    try await Self.downloadFileStreaming(
                        from: asset.browserDownloadURL,
                        to: destPackage,
                        expectedSize: asset.size
                    ) { downloaded, total in
                        Task { @MainActor in
                            guard case .downloading = self.state else { return }
                            let denom = max(1, total > 0 ? total : asset.size)
                            let frac = min(1.0, max(0.0, Double(downloaded) / Double(denom)))
                            self.state = .downloading(release: release, progress: frac, downloadedBytes: downloaded, totalBytes: denom)
                        }
                    }
                }

                guard !Task.isCancelled else { return }
                state = .verifying(release: release)

                var expectedSHA = asset.expectedSHA256
                if expectedSHA == nil, let checksumAsset = release.checksumAsset {
                    let checksumText = try await Self.fetchChecksumText(from: checksumAsset.browserDownloadURL)
                    expectedSHA = AppVersionComparator.parseSHA256Checksum(from: checksumText, matchingFileName: asset.name)
                }
                if let expectedSHA {
                    let actualSHA = try Self.computeFileSHA256(url: destPackage)
                    guard actualSHA == expectedSHA else {
                        try? FileManager.default.removeItem(at: destPackage)
                        throw NSError(domain: "AgyHigherUpdater", code: -2, userInfo: [
                            NSLocalizedDescriptionKey: "安装包 SHA-256 校验未通过，已自动删除损坏文件"
                        ])
                    }
                }

                guard !Task.isCancelled else { return }
                let writableApp = Self.currentWritableAppBundleURL()
                state = .readyToInstall(release: release, packageURL: destPackage, canSelfReplace: writableApp != nil)
                installReadyUpdate(release: release, packageURL: destPackage)
            } catch is CancellationError {
                self.cancelDownload()
            } catch {
                self.state = .error(message: "更新失败: \(error.localizedDescription)")
            }
        }
    }

    private func installReadyUpdate(release: AppReleaseInfo, packageURL: URL) {
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            state = .error(message: "未找到已下载的安装包")
            return
        }

        let isZipPackage = packageURL.pathExtension.lowercased() == "zip"

        guard let targetAppURL = Self.currentWritableAppBundleURL() else {
            if isZipPackage {
                let stageDir = packageURL.deletingLastPathComponent().appendingPathComponent("extracted", isDirectory: true)
                if let extractedApp = try? Self.extractAppBundleWithDitto(zipURL: packageURL, into: stageDir) {
                    NSWorkspace.shared.activateFileViewerSelecting([extractedApp])
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([packageURL])
                }
            } else {
                NSWorkspace.shared.open(packageURL)
            }
            state = .readyToInstall(release: release, packageURL: packageURL, canSelfReplace: false)
            return
        }

        state = .installing(release: release)
        Task.detached(priority: .userInitiated) {
            do {
                if isZipPackage {
                    let stageDir = packageURL.deletingLastPathComponent().appendingPathComponent("extracted", isDirectory: true)
                    let extractedApp = try Self.extractAppBundleWithDitto(zipURL: packageURL, into: stageDir)
                    try Self.spawnDetachedAppReplacer(
                        sourceAppURL: extractedApp,
                        mountPointToDetach: nil,
                        targetAppURL: targetAppURL,
                        packageURL: packageURL,
                        cleanupDirURL: stageDir
                    )
                } else {
                    let mountPoint = try Self.attachDMGReadOnly(dmgURL: packageURL)
                    let mountedApp = mountPoint.appendingPathComponent("AgyHigher.app", isDirectory: true)
                    guard FileManager.default.fileExists(atPath: mountedApp.path) else {
                        Self.detachDMG(mountPoint: mountPoint)
                        throw NSError(domain: "AgyHigherUpdater", code: -3, userInfo: [
                            NSLocalizedDescriptionKey: "DMG 镜像中未找到 AgyHigher.app"
                        ])
                    }
                    try Self.spawnDetachedAppReplacer(
                        sourceAppURL: mountedApp,
                        mountPointToDetach: mountPoint,
                        targetAppURL: targetAppURL,
                        packageURL: packageURL,
                        cleanupDirURL: nil
                    )
                }

                await MainActor.run {
                    self.performGracefulExitForUpdate()
                }
            } catch {
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([packageURL])
                    self.state = .error(message: "自动更新失败，已定位安装包: \(error.localizedDescription)")
                }
            }
        }
    }

    private func performGracefulExitForUpdate() {
        for win in NSApp.windows {
            win.orderOut(nil)
            win.close()
        }
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.90) {
            Darwin.exit(0)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        }
        return String(format: "%.0f KB", Double(bytes) / 1024.0)
    }

    nonisolated private static func currentWritableAppBundleURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension.lowercased() == "app" else { return nil }
        let path = bundleURL.standardizedFileURL.path
        guard !path.hasPrefix("/Volumes/") else { return nil }
        let parentDir = bundleURL.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parentDir) ? bundleURL : nil
    }

    nonisolated private static func verifyExistingCachedPackage(_ url: URL, expectedSize: Int64) -> Bool {
        guard expectedSize > 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.int64Value == expectedSize
    }

    nonisolated private static func extractAppBundleWithDitto(zipURL: URL, into stageDir: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: stageDir)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zipURL.path, stageDir.path]
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "AgyHigherUpdater", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: errStr.isEmpty ? "解压 .app.zip 更新包失败" : errStr
            ])
        }

        let candidateApp = stageDir.appendingPathComponent("AgyHigher.app", isDirectory: true)
        if fm.fileExists(atPath: candidateApp.appendingPathComponent("Contents/MacOS/AgyHigher").path) {
            return candidateApp
        }
        if let children = try? fm.contentsOfDirectory(at: stageDir, includingPropertiesForKeys: nil),
           let firstApp = children.first(where: { $0.pathExtension.lowercased() == "app" }) {
            return firstApp
        }
        throw NSError(domain: "AgyHigherUpdater", code: -5, userInfo: [
            NSLocalizedDescriptionKey: "更新包解压后未包含 AgyHigher.app"
        ])
    }

    nonisolated private static func downloadFileStreaming(
        from remoteURL: URL,
        to destinationURL: URL,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<URL, Error>?
            private var lastEmit = ProcessInfo.processInfo.systemUptime
            private let expectedSize: Int64
            private let onProgress: @Sendable (Int64, Int64) -> Void

            init(expectedSize: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
                self.expectedSize = expectedSize
                self.onProgress = onProgress
            }

            func awaitResult(_ cont: CheckedContinuation<URL, Error>) {
                lock.lock()
                continuation = cont
                lock.unlock()
            }

            private func finish(with result: Result<URL, Error>) {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(with: result)
            }

            func urlSession(
                _ session: URLSession,
                downloadTask: URLSessionDownloadTask,
                didWriteData bytesWritten: Int64,
                totalBytesWritten: Int64,
                totalBytesExpectedToWrite: Int64
            ) {
                let now = ProcessInfo.processInfo.systemUptime
                lock.lock()
                let shouldEmit = (now - lastEmit) >= 0.10
                if shouldEmit { lastEmit = now }
                lock.unlock()
                if shouldEmit {
                    let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
                    onProgress(totalBytesWritten, total)
                }
            }

            func urlSession(
                _ session: URLSession,
                downloadTask: URLSessionDownloadTask,
                didFinishDownloadingTo location: URL
            ) {
                if let http = downloadTask.response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    finish(with: .failure(URLError(.badServerResponse)))
                    return
                }
                let tempCopy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("agyhigher-dl-\(UUID().uuidString).pkg")
                do {
                    if FileManager.default.fileExists(atPath: tempCopy.path) {
                        try FileManager.default.removeItem(at: tempCopy)
                    }
                    try FileManager.default.moveItem(at: location, to: tempCopy)
                    finish(with: .success(tempCopy))
                } catch {
                    finish(with: .failure(error))
                }
            }

            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                if let error {
                    finish(with: .failure(error))
                }
            }
        }

        var req = URLRequest(url: remoteURL, timeoutInterval: 180)
        req.setValue("AgyHigher/\(AgyHigherAppInfo.version)", forHTTPHeaderField: "User-Agent")

        let delegate = Delegate(expectedSize: expectedSize, onProgress: onProgress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: req)
        defer { session.invalidateAndCancel() }

        let tempURL: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                delegate.awaitResult(cont)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        let finalSize = ((try? FileManager.default.attributesOfItem(atPath: destinationURL.path))?[.size] as? NSNumber)?.int64Value ?? expectedSize
        onProgress(finalSize, max(expectedSize, finalSize))
    }

    nonisolated private static func fetchChecksumText(from url: URL) async throws -> String {
        let req = URLRequest(url: url, timeoutInterval: 15)
        let (data, _) = try await URLSession.shared.data(for: req)
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private static func computeFileSHA256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 262_144), !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func attachDMGReadOnly(dmgURL: URL) throws -> URL {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", "-nobrowse", "-readonly", "-plist", dmgURL.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: outData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "AgyHigherUpdater", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: errStr.isEmpty ? "挂载更新镜像失败" : errStr
            ])
        }
        for ent in entities {
            if let mp = ent["mount-point"] as? String, !mp.isEmpty {
                return URL(fileURLWithPath: mp, isDirectory: true)
            }
        }
        throw NSError(domain: "AgyHigherUpdater", code: -4, userInfo: [
            NSLocalizedDescriptionKey: "未解析到 DMG 挂载路径"
        ])
    }

    nonisolated private static func detachDMG(mountPoint: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", mountPoint.path, "-quiet"]
        try? proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let forceProc = Process()
            forceProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            forceProc.arguments = ["detach", mountPoint.path, "-force", "-quiet"]
            try? forceProc.run()
            forceProc.waitUntilExit()
        }
    }

    nonisolated private static func spawnDetachedAppReplacer(
        sourceAppURL: URL,
        mountPointToDetach: URL?,
        targetAppURL: URL,
        packageURL: URL,
        cleanupDirURL: URL?
    ) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let targetPath = targetAppURL.standardizedFileURL.path
        let sourceAppPath = sourceAppURL.standardizedFileURL.path
        let mountPath = mountPointToDetach?.standardizedFileURL.path ?? ""
        let packagePath = packageURL.standardizedFileURL.path
        let cleanupPath = cleanupDirURL?.standardizedFileURL.path ?? ""

        let workerScript = """
        PID="$1"
        SOURCE_APP="$2"
        TARGET_APP="$3"
        MOUNT_POINT="$4"
        PACKAGE_FILE="$5"
        CLEANUP_DIR="$6"

        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 24 ]; do
            sleep 0.25
            i=$((i + 1))
        done
        if kill -0 "$PID" 2>/dev/null; then
            kill -TERM "$PID" >/dev/null 2>&1 || true
            j=0
            while kill -0 "$PID" 2>/dev/null && [ "$j" -lt 16 ]; do
                sleep 0.25
                j=$((j + 1))
            done
            kill -KILL "$PID" >/dev/null 2>&1 || true
        fi

        OTHER_PIDS="$(pgrep -x AgyHigher 2>/dev/null || true)"
        if [ -n "$OTHER_PIDS" ]; then
            for opid in $OTHER_PIDS; do
                [ "$opid" = "$$" ] && continue
                kill -TERM "$opid" >/dev/null 2>&1 || true
            done
            sleep 0.4
            for opid in $OTHER_PIDS; do
                [ "$opid" = "$$" ] && continue
                kill -0 "$opid" 2>/dev/null && kill -KILL "$opid" >/dev/null 2>&1 || true
            done
        fi

        sleep 0.5
        BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agyhigher-backup.XXXXXX" 2>/dev/null || echo "/tmp/agyhigher-backup-$$")"
        mkdir -p "$BACKUP_DIR" 2>/dev/null || true
        BACKUP_CONTENTS="${BACKUP_DIR}/Contents"

        # Preserve top-level .app directory inode so macOS Dock never duplicates the icon
        mkdir -p "$TARGET_APP" 2>/dev/null || true
        if [ -d "$TARGET_APP/Contents" ]; then
            mv "$TARGET_APP/Contents" "$BACKUP_CONTENTS" || {
                rm -rf "$BACKUP_DIR"
                exit 1
            }
        fi

        LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        detach_dmg() {
            if [ -n "$MOUNT_POINT" ]; then
                hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || hdiutil detach "$MOUNT_POINT" -force -quiet >/dev/null 2>&1 || true
            fi
            for vol in /Volumes/AgyHigher*; do
                [ -e "$vol" ] || continue
                hdiutil detach "$vol" -quiet >/dev/null 2>&1 || hdiutil detach "$vol" -force -quiet >/dev/null 2>&1 || true
            done
        }

        if ditto "$SOURCE_APP/Contents" "$TARGET_APP/Contents"; then
            touch "$TARGET_APP" >/dev/null 2>&1 || true
            xattr -rd com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1 || true
            rm -rf "$BACKUP_DIR" >/dev/null 2>&1 || true
            [ -n "$CLEANUP_DIR" ] && rm -rf "$CLEANUP_DIR" >/dev/null 2>&1 || true
            detach_dmg
            if [ -x "$LSREG" ]; then
                [ -n "$SOURCE_APP" ] && "$LSREG" -u "$SOURCE_APP" >/dev/null 2>&1 || true
                "$LSREG" -f "$TARGET_APP" >/dev/null 2>&1 || true
            fi
            rm -f "$PACKAGE_FILE" >/dev/null 2>&1 || true
            [ -n "$PACKAGE_FILE" ] && rmdir "$(dirname "$PACKAGE_FILE")" >/dev/null 2>&1 || true
            sleep 0.35
            /usr/bin/open "$TARGET_APP"
        else
            rm -rf "$TARGET_APP/Contents"
            [ -d "$BACKUP_CONTENTS" ] && mv "$BACKUP_CONTENTS" "$TARGET_APP/Contents"
            rm -rf "$BACKUP_DIR" >/dev/null 2>&1 || true
            detach_dmg
            /usr/bin/open "$TARGET_APP"
        fi
        """

        let trampolineScript = """
        (nohup /bin/sh -c "$1" agyhigher-updater-worker "$2" "$3" "$4" "$5" "$6" "$7" </dev/null >/dev/null 2>&1 &)
        """
        try spawnSessionDetachedShell(
            arguments: ["/bin/sh", "-c", trampolineScript, "agyhigher-trampoline", workerScript, "\(pid)", sourceAppPath, targetPath, mountPath, packagePath, cleanupPath]
        )
    }

    nonisolated private static func spawnSessionDetachedShell(arguments: [String]) throws {
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let spawnFlags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attr, spawnFlags)

        var cStrings: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        cStrings.append(nil)
        defer {
            for ptr in cStrings {
                if let ptr { free(ptr) }
            }
        }

        var envCStrings: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        envCStrings.append(nil)
        defer {
            for ptr in envCStrings {
                if let ptr { free(ptr) }
            }
        }

        var childPid: pid_t = 0
        let rc = posix_spawn(&childPid, "/bin/sh", &fileActions, &attr, &cStrings, &envCStrings)
        guard rc == 0 else {
            throw NSError(domain: "AgyHigherUpdater", code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: "启动更新安装进程失败 (posix_spawn \(rc))"
            ])
        }
        var status: Int32 = 0
        _ = waitpid(childPid, &status, 0)
    }
}
