import SwiftUI

// MARK: - 已出好的 iPhone 包（11-01 维护者 转测试开发者反馈：历史任务里出好的包只剩一行「查看产物」，多游戏用户没法从历史里再装）
//   数据从产物本身读（游戏库 iPhone/<程序号>/*.ipa、旁边的「…资源包」、IPA 里 Info.plist 的画面模式 / 出包时间 / 包号），不靠任务记录：
//   任务记录换机 / 重开启动器会丢字段（11-01：后端任务记录不存 IPA 路径，重开后完成卡画面模式「未知」）。
//   按游戏一张卡，同款多次出包显示最新一个、旧版本可展开；产物已删、只剩成功任务的款显示「产物已清理」，只给重新出包，不放死按钮。
//   装机复用完成卡同一条路（Store.installToPhone：pack/jobs/install.py 装这款目录里最新的 IPA），所以只有最新版本带「装到 iPhone」。

struct PackShelfVersion: Identifiable, Equatable {
    var id: String { ipa.path }
    let ipa: URL
    let date: Date            // 出包时间：Info.plist S2APackTime，读不到用文件修改时间
    let bytes: Int64          // IPA + 资源包（index.tsv 记的字节）
    let mode: PackGraphicsMode
    let buildID: String?
}

struct PackShelfEntry: Identifiable, Equatable {
    var id: String { gameId }
    let gameId: String
    let name: String
    let game: Game?            // 游戏库里还在：有封面、版本；不在（删了游戏、换了库）回退占位图标与包里的名字
    let versions: [PackShelfVersion]   // 新 → 旧；空 = 产物已清理
    let cleanedAt: Date?       // 产物已清理时：最近一次成功出包的结束时刻
    var latest: PackShelfVersion? { versions.first }
    var sortDate: Date { latest?.date ?? cleanedAt ?? .distantPast }
    static func == (a: Self, b: Self) -> Bool { a.gameId == b.gameId && a.name == b.name && a.versions == b.versions && a.cleanedAt == b.cleanedAt && (a.game == nil) == (b.game == nil) }
}

enum PackShelf {
    /// 扫 <游戏库>/iPhone/<程序号>/：每个 *.ipa 一个版本；再补「有成功出包任务、产物却没了」的款。按最近出包时间排，新的在前
    static func scan(library: URL, games: [Game], tasks: [TaskRecord], evidence: (URL) -> PackGraphicsEvidence = { PackGraphicsEvidenceReader.read(ipa: $0) }) -> [PackShelfEntry] {
        let fm = FileManager.default
        let root = library.appendingPathComponent("iPhone")
        var entries: [PackShelfEntry] = []
        var seen = Set<String>()
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let gid = dir.lastPathComponent
            let ipas = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "ipa" }
            guard !ipas.isEmpty else { continue }
            let packBytes = PackFacts.read(ipa: ipas[0].path).packBytes ?? 0   // 资源包每款一份（推送按内容增量），各版本共用
            let versions: [PackShelfVersion] = ipas.map { ipa in
                let ev = evidence(ipa)
                let mtime = (try? ipa.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let date = ev.packTime.flatMap { ISO8601DateFormatter().date(from: $0) } ?? mtime
                let size = (try? fm.attributesOfItem(atPath: ipa.path)[.size] as? NSNumber)?.int64Value ?? 0
                return PackShelfVersion(ipa: ipa, date: date, bytes: size + packBytes, mode: ev.mode, buildID: ev.buildID)
            }.sorted { $0.date > $1.date }
            let game = games.first { $0.id == gid }
            entries.append(PackShelfEntry(gameId: gid, name: game?.name ?? gid, game: game, versions: versions, cleanedAt: nil))
            seen.insert(gid)
        }
        // 成功出过包、产物已被清理（删除游戏的产物 / 手动删）：留一张卡，只给重新出包
        let done = tasks.filter { $0.operation == "ipa" && $0.state == "completed" && $0.gameId != nil && !seen.contains($0.gameId!) }
        for (gid, ts) in Dictionary(grouping: done, by: { $0.gameId! }) {
            let game = games.first { $0.id == gid }
            guard game != nil else { continue }   // 游戏也不在库里了：没法重出，不留卡
            let last = ts.compactMap(\.ended).max().map { Date(timeIntervalSince1970: $0) }
            entries.append(PackShelfEntry(gameId: gid, name: game!.name, game: game, versions: [], cleanedAt: last))
        }
        return entries.sorted { $0.sortDate > $1.sortDate }
    }
}

extension Store {
    func refreshPackShelf() {
        let library = libraryURL, games = games, tasks = tasks
        guard !LocalLauncherProfile.active, !preferences.library.isEmpty else { packShelf = []; return }
        Task.detached { let shelf = PackShelf.scan(library: library, games: games, tasks: tasks); await MainActor.run { self.packShelf = shelf } }
    }
    /// 删一个版本的 IPA（放进废纸篓，可从废纸篓找回）；删的是这款最后一个 IPA 时连资源包一起放进废纸篓
    func trashPackVersion(_ entry: PackShelfEntry, _ version: PackShelfVersion) {
        let fm = FileManager.default
        do {
            try fm.trashItem(at: version.ipa, resultingItemURL: nil)
            if entry.versions.count == 1, let pack = PackFacts.read(ipa: version.ipa.path).packURL ?? (try? fm.contentsOfDirectory(at: version.ipa.deletingLastPathComponent(), includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.hasSuffix("资源包") }) {
                try fm.trashItem(at: pack, resultingItemURL: nil)
            }
            notice = L("已移到废纸篓。"); refreshPackShelf()
        } catch { self.error = L("删除失败：") + error.localizedDescription }
    }
}

struct PackShelfPanel: View {
    @EnvironmentObject var store: Store
    let entries: [PackShelfEntry]
    var body: some View {
        GlassPanel(title: "已出好的 iPhone 包", symbol: "iphone.gen3") {
            LazyVStack(spacing: 8) { ForEach(entries) { PackShelfCard(entry: $0) } }
        }
    }
}

struct PackShelfCard: View {
    @EnvironmentObject var store: Store
    let entry: PackShelfEntry
    @State private var showOlder = false
    @State private var confirmDelete: PackShelfVersion?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                cover.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 5, y: 2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.name).font(.headline).lineLimit(1)
                        if let v = entry.game?.display, !v.isEmpty { Text(v).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    if let latest = entry.latest {
                        FlowRow(spacing: 8, lineSpacing: 2) {
                            Text(latest.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                            Text("·"); Text(ByteCountFormatter.string(fromByteCount: latest.bytes, countStyle: .file)).monospacedDigit()
                            Text("·"); Text(L("画面模式") + " " + latest.mode.title)
                            if let t = store.iphoneTarget { Text("·"); Text(t.label) }
                        }.font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(L("产物已清理") + (entry.cleanedAt.map { L("（最后一次出包 ") + $0.formatted(date: .abbreviated, time: .shortened) + L("）") } ?? ""))
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                actions
            }
            if entry.versions.count > 1 {
                DisclosureGroup(isExpanded: $showOlder) {
                    VStack(spacing: 6) { ForEach(entry.versions.dropFirst()) { olderRow($0) } }.padding(.top, 4)
                } label: { Text(L("旧版本 ") + "\(entry.versions.count - 1)").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(WorkspaceLayout.cardInset).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .confirmationDialog(L("删除这个 iPhone 包？"), isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { v in
            Button(L("移到废纸篓"), role: .destructive) { store.trashPackVersion(entry, v) }
        } message: { _ in Text(L("IPA 会移到废纸篓，可从废纸篓找回。删的是这款最后一个包时，资源包也一起移走。")) }
    }
    @ViewBuilder private var cover: some View {
        if let game = entry.game { GameCover(game: game) }
        else { ZStack { Color.secondary.opacity(0.12); Image(systemName: "app.dashed").font(.system(size: 28)).foregroundStyle(.secondary) } }
    }
    @ViewBuilder private var actions: some View {
        if let latest = entry.latest {
            HStack(spacing: 8) {
                Button(L("改用 AltStore")) { store.showInstallGuide = true }.buttonStyle(.borderless)
                Button { store.reveal(latest.ipa) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help(L("在访达中显示")).accessibilityLabel(L("在访达中显示"))
                Button { confirmDelete = latest } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(L("删除")).accessibilityLabel(L("删除"))
                Button { if let g = entry.game { store.requestInstall(g) } } label: { Label(L("装到 iPhone"), systemImage: "iphone.and.arrow.forward") }
                    .buttonStyle(.borderedProminent).disabled(entry.game == nil || store.executionBusy)
                    .help(entry.game == nil ? L("这款游戏不在当前游戏库里，没法装") : "")
            }.controlSize(.small)
        } else if let g = entry.game {
            Button { store.packIPhone(g) } label: { Label(L("重新出包"), systemImage: "arrow.clockwise") }.controlSize(.small)
        }
    }
    private func olderRow(_ v: PackShelfVersion) -> some View {
        HStack(spacing: 10) {
            Text(v.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
            Text(ByteCountFormatter.string(fromByteCount: v.bytes, countStyle: .file)).monospacedDigit().foregroundStyle(.secondary)
            Text(v.mode.title).foregroundStyle(.secondary)
            Spacer()
            Button { store.reveal(v.ipa) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help(L("在访达中显示")).accessibilityLabel(L("在访达中显示"))
            Button { confirmDelete = v } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(L("删除")).accessibilityLabel(L("删除"))
        }.font(.caption)
    }
}
