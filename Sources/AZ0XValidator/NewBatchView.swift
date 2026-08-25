import SwiftUI
import AZ0XCore

/// Two steps: which boards, then what to run on them.
///
/// The board list offers only boards that can actually be taken. A board something else is already
/// driving is simply absent — listing it and then refusing it would invite the operator to tick
/// something that cannot start.
struct NewBatchView: View {
    @EnvironmentObject var app: AppModel
    let step: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("新建验证批次 · 第 \(step) 步 / 共 2 步 · \(step == 1 ? "选型号与待测板" : "选测试项")")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)

            if step == 1 { stepOne } else { stepTwo }
        }
        .task(id: step) {
            // Sampled only while this screen is open; a running batch is not polled under it.
            while step == 1, !Task.isCancelled {
                await app.scan()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - Step 1

    private var stepOne: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 16) {
                Field("型号") {
                    Picker("", selection: $app.model) {
                        ForEach(DeviceModel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Field("流程") {
                    Picker("", selection: $app.flow) {
                        ForEach(ValidationFlow.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Callout(tint: .secondary, icon: "pencil",
                        text: "确认后本批次固定为已勾选的板，之后插拔不影响。")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                Panel(title: "待测板 · 处于 MASKROM",
                      trailing: app.candidates.isEmpty ? nil : "全选",
                      onTrailing: { app.confirmed = Set(app.candidates.map(\.deviceID)) }) {
                    if app.candidates.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "cable.connector.slash")
                            Text(app.isScanning && app.attached.isEmpty
                                 ? "正在检测设备"
                                 : "未检测到可用的 \(app.model.rawValue)，请将待测板置于 MASKROM 模式")
                        }
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.vertical, 12).padding(.horizontal, 12)
                    } else {
                        ForEach(app.candidates) { board in
                            Tick(on: app.confirmed.contains(board.deviceID)) {
                                if app.confirmed.contains(board.deviceID) {
                                    app.confirmed.remove(board.deviceID)
                                } else {
                                    app.confirmed.insert(board.deviceID)
                                }
                            } content: {
                                Text("插座 \(board.socket)")
                                    .font(.system(.callout, design: .monospaced))
                                Spacer(minLength: 8)
                                Text(app.model.soc).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !app.excludedNote.isEmpty {
                        Divider()
                        Text(app.excludedNote)
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack {
                    Spacer()
                    Button("取消") { app.cancelNewBatch() }
                    Button("下一步") { app.screen = .newBatch(step: 2) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(app.confirmed.isEmpty)
                }
                .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
    }

    // MARK: - Step 2

    private var stepTwo: some View {
        HStack(alignment: .top, spacing: 22) {
            ScrollView {
                Panel(title: "测试项") {
                    ForEach(TestItem.items(for: app.flow, model: app.model)) { item in
                        itemRow(item)
                        if item.code == "T06", app.picked.contains("T06") { phaseRows }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 14) {
                Panel(title: "本次概要") {
                    VStack(spacing: 7) {
                        summary("待测板", "\(app.confirmed.count) 块")
                        summary("测试项",
                                "\(app.resolvedItems.count) / \(TestItem.items(for: app.flow, model: app.model).count)")
                        ForEach(app.scaleSummary, id: \.0) { summary($0.0, $0.1) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }

                if app.isPartialRun {
                    Callout(tint: Palette.hold, icon: "exclamationmark.triangle",
                            text: "本次只跑部分测试项。报告将标记为抽测记录，不构成物料导入结论。")
                }
                if app.hasLongRun {
                    Callout(tint: Palette.hold, icon: "moon.zzz",
                            text: "含长测项，请让机器保持唤醒、不要合盖。")
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Button("上一步") { app.screen = .newBatch(step: 1) }
                    Button("开始验证 \(app.confirmed.count) 块") { app.startBatch() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(app.confirmed.isEmpty || app.resolvedItems.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
    }

    private func itemRow(_ item: TestItem) -> some View {
        let locked = !item.isOptional
            || TestItem.isLocked(item, picked: app.picked, flow: app.flow, model: app.model)
        let on = locked || app.picked.contains(item.code)
        return Tick(on: on, locked: locked) {
            if app.picked.contains(item.code) { app.picked.remove(item.code) }
            else { app.picked.insert(item.code) }
        } content: {
            Text(item.code).font(.system(.callout, design: .monospaced))
            Text(item.title).font(.callout)
            if locked {
                Text(item.isOptional ? "· 选了板载项即锁定" : "· 必选")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if item.isRecordOnly {
                Text("仅记录").font(.caption).foregroundStyle(.secondary)
            } else if let load = item.workloadLabel(burninPhases: app.burninPhases.count) {
                Text(load).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    /// The burn-in segments sit under T06 rather than in a panel of their own: they are part of that
    /// item, and a separate panel made T06 look unlike every other row.
    private var phaseRows: some View {
        ForEach(BurninPhase.allCases) { phase in
            Tick(on: app.burninPhases.contains(phase), indented: true) {
                if app.burninPhases.contains(phase) { app.burninPhases.remove(phase) }
                else { app.burninPhases.insert(phase) }
            } content: {
                Text(phase.title).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(TestItem.hoursText(Thresholds.longRunSeconds))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.callout, design: .monospaced))
        }
    }
}

// MARK: - Small pieces

struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

struct Panel<Content: View>: View {
    let title: String
    var trailing: String?
    var onTrailing: (() -> Void)?
    @ViewBuilder let content: Content

    init(title: String, trailing: String? = nil, onTrailing: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.onTrailing = onTrailing
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let trailing, let onTrailing {
                    Button(trailing, action: onTrailing).buttonStyle(.link).font(.caption)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.secondary.opacity(0.06))
            Divider()
            VStack(spacing: 0) { content }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.22)))
    }
}

/// A checkbox row. Locked rows show as chosen and do not respond, because the sequence requires
/// them — an item that cannot be unticked should not look like one that can.
struct Tick<Content: View>: View {
    let on: Bool
    var locked = false
    var indented = false
    let action: () -> Void
    @ViewBuilder let content: Content

    init(on: Bool, locked: Bool = false, indented: Bool = false,
         action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.on = on
        self.locked = locked
        self.indented = indented
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: { if !locked { action() } }) {
            HStack(spacing: 9) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                content
            }
            .padding(.leading, indented ? 30 : 12)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(locked ? 0.55 : 1)
        .background(indented ? Color.secondary.opacity(0.05) : .clear)
        .help(locked ? "本序列必须包含这一项" : "")
    }
}
