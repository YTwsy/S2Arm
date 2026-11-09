// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation

struct LocalLauncherProfile: Decodable {
    struct Toolchain: Codable {
        let python: String
        let bash: String
        let dotnet: String
        let sdkRoot: String
        let path: [String]
        let nugetPackages: String?
        let sourceCache: String?
        let rewriterDeps: String?
        let tzdataCache: String?
    }

    static let name = "macos14-local"
    static let applicationName = "S2Arm macOS 14"
    static let mobileOperations: Set<String> = [
        "downloadIosPlatform", "ipa", "install", "installRemove", "installCheck",
        "signingProject", "targetDevice", "pullDiagnostics",
    ]
    static let active: Bool = {
        #if S2A_MACOS14
        Bundle.main.object(forInfoDictionaryKey: "S2ARuntimeProfile") as? String == name
        #else
        false
        #endif
    }()

    let schema: Int
    let engineDir: String
    let developerDir: String
    let fontsDir: String?
    let localToolchain: Toolchain

    static func read(resources: URL) throws -> Self {
        let url = resources.appendingPathComponent("LocalProfile.json")
        let profile = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard profile.schema == 1 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        return profile
    }

    func aiHandoffText(dataRoot: URL, app: URL, language: String) -> String {
        func quote(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let script = URL(fileURLWithPath: engineDir).appendingPathComponent("launchers/macos/s2armctl.py")
        let command = "\(quote(localToolchain.python)) -B -I \(quote(script.path)) --data-root \(quote(dataRoot.path))"
        let connect = "\(command) start \(quote(app.path))"
        let state = "\(command) state --json"
        if language != "zh-Hans" {
            return """
            Help me prepare and play my own Switch games on this Mac using S2Arm's macos14-local profile.
            Connect to this launcher with:
            \(connect)
            Inspect its environment, library, and jobs with:
            \(state)
            Keep the same Python, script, and --data-root in every command. Use env to recheck the environment, keys and games to import files I provide, then prepare GAME_ID, wait GAME_ID --op build, and launch GAME_ID as needed. Use the Mac workflow described here.
            Ask me for the locations of my keys and games. Pause for me to handle system permissions or passwords. Keep all data on this Mac and ask before deleting anything.
            """
        }
        return """
        请用 S2Arm 的 macos14-local 配置，帮我在这台 Mac 上准备和运行我自己的 Switch 游戏。
        用这条命令连接本机启动器：
        \(connect)
        用这条命令查看环境、游戏库和任务：
        \(state)
        每条命令沿用相同的 Python、脚本和 --data-root。按需用 env 复查环境，keys 和 games 导入我提供的文件，再用 prepare GAME_ID、wait GAME_ID --op build 和 launch GAME_ID 准备、等待及启动。按这里的 Mac 流程操作。
        密钥和游戏的位置请问我。遇到系统授权或密码时停下来由我处理。数据留在这台 Mac 上，删除前先问我。
        """
    }
}
