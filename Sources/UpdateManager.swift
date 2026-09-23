import Foundation

struct UpdateRelease {
    let version: String
    let downloadURL: URL
}

enum UpdateCheckResult {
    case upToDate(String)
    case available(UpdateRelease)
    case failure(Error)
}

enum UpdateError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case packageNotFound
    case downloadFailed
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub 返回了无法识别的版本信息。"
        case .httpStatus(let code): return "GitHub 连接失败（HTTP \(code)），请稍后重试。"
        case .packageNotFound: return "最新版中没有找到 Apple 芯片安装包。"
        case .downloadFailed: return "安装包下载失败，请检查网络后重试。"
        case .installationFailed(let detail): return "自动安装失败：\(detail)"
        }
    }
}

enum UpdateManager {
    private static let releaseAPI = URL(string: "https://api.github.com/repos/hbiszxm/mac-fullscreen-message/releases/latest")!

    static func check(completion: @escaping (UpdateCheckResult) -> Void) {
        var components = URLComponents(string: "https://github.com/hbiszxm/mac-fullscreen-message/releases/latest/download/update.json")!
        components.queryItems = [URLQueryItem(name: "cache", value: String(Int(Date().timeIntervalSince1970)))]
        var request = URLRequest(url: components.url!)
        request.setValue("mac-fullscreen-message", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, error in
            if error == nil,
               let response = response as? HTTPURLResponse,
               (200..<300).contains(response.statusCode),
               let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = object["version"] as? String,
               let value = object["download_url"] as? String,
               let url = URL(string: value) {
                let result: UpdateCheckResult = isNewer(version, than: currentVersion)
                    ? .available(UpdateRelease(version: version, downloadURL: url))
                    : .upToDate(currentVersion)
                DispatchQueue.main.async { completion(result) }
            } else {
                checkAPI(completion: completion)
            }
        }.resume()
    }

    private static func checkAPI(completion: @escaping (UpdateCheckResult) -> Void) {
        var request = URLRequest(url: releaseAPI)
        request.setValue("mac-fullscreen-message", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: UpdateCheckResult
            if let error {
                result = .failure(error)
            } else if let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = object["tag_name"] as? String,
                      let assets = object["assets"] as? [[String: Any]] {
                let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let asset = assets.first { item in
                    guard let name = item["name"] as? String else { return false }
                    return name == "FullscreenMessage-AppleSilicon.pkg" ||
                        (name.hasPrefix("FullscreenMessage-AppleSilicon-") && name.hasSuffix(".pkg"))
                }
                if isNewer(version, than: currentVersion) {
                    if let value = asset?["browser_download_url"] as? String, let url = URL(string: value) {
                        result = .available(UpdateRelease(version: version, downloadURL: url))
                    } else {
                        result = .failure(UpdateError.packageNotFound)
                    }
                } else {
                    result = .upToDate(currentVersion)
                }
            } else if let response = response as? HTTPURLResponse {
                result = .failure(UpdateError.httpStatus(response.statusCode))
            } else {
                result = .failure(UpdateError.invalidResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    static func download(_ release: UpdateRelease, completion: @escaping (Result<URL, Error>) -> Void) {
        var components = URLComponents(url: release.downloadURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "cache", value: String(Int(Date().timeIntervalSince1970)))]
        var request = URLRequest(url: components?.url ?? release.downloadURL)
        request.setValue("mac-fullscreen-message", forHTTPHeaderField: "User-Agent")
        URLSession.shared.downloadTask(with: request) { temporaryURL, response, error in
            guard error == nil, let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode), let temporaryURL else {
                DispatchQueue.main.async { completion(.failure(error ?? UpdateError.downloadFailed)) }
                return
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("FullscreenMessage-AppleSilicon-V\(release.version).pkg")
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                DispatchQueue.main.async { completion(.success(destination)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    static func installSilently(packageURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let appPath = Bundle.main.bundlePath
        if FileManager.default.isWritableFile(atPath: appPath) {
            installWithoutPrivileges(packageURL: packageURL, appPath: appPath, completion: completion)
            return
        }
        installWithAdministratorPrivileges(packageURL: packageURL, completion: completion)
    }

    private static func installWithoutPrivileges(packageURL: URL, appPath: String, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let manager = FileManager.default
            let workDirectory = manager.temporaryDirectory.appendingPathComponent("fullscreen-message-update-\(UUID().uuidString)")
            let expandedDirectory = workDirectory.appendingPathComponent("expanded")
            do {
                try manager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
                let expand = Process()
                expand.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
                expand.arguments = ["--expand-full", packageURL.path, expandedDirectory.path]
                try expand.run()
                expand.waitUntilExit()
                guard expand.terminationStatus == 0 else {
                    throw UpdateError.installationFailed("无法解包更新文件。")
                }
                guard let enumerator = manager.enumerator(at: expandedDirectory, includingPropertiesForKeys: nil),
                      let sourceApp = enumerator.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "全屏消息.app" }) else {
                    throw UpdateError.installationFailed("更新包中没有找到应用程序。")
                }
                let helper = Process()
                helper.executableURL = URL(fileURLWithPath: "/bin/sh")
                helper.arguments = [
                    "-c",
                    "sleep 1; /usr/bin/ditto --norsrc \"$1\" \"$2\" && /usr/bin/open \"$2\"; /bin/rm -rf \"$3\"",
                    "fullscreen-message-updater",
                    sourceApp.path,
                    appPath,
                    workDirectory.path
                ]
                try helper.run()
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                try? manager.removeItem(at: workDirectory)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func installWithAdministratorPrivileges(packageURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let shellPath = packageURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let command = "/usr/sbin/installer -pkg '\(shellPath)' -target /"
        let appleScriptCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(appleScriptCommand)\" with administrator privileges"]
        process.standardError = errorPipe
        process.terminationHandler = { process in
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(UpdateError.installationFailed(
                        detail?.isEmpty == false ? detail! : "管理员授权已取消或安装程序返回错误。"
                    )))
                }
            }
        }
        do {
            try process.run()
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }
}
