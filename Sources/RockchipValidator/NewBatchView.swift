import SwiftUI
import ValidationCore

/// New-batch flow, in two steps: what to test and on which boards, then which items.
/// One page held both and the second half fell below the fold, which hid the two things
/// the operator is deciding.
struct NewBatchView: View {
    @EnvironmentObject var app: AppState
    @State private var step = 1

    var body: some View {
        VStack(spacing: 0) {
            stepHeader
            Divider()
            if let fetchError = app.fetchError { errorBanner(fetchError) }
            // The wait replaces the page rather than sitting beside it. What the operator can
            // usefully do while an image is coming down is nothing, and leaving the selection
            // on screen live invites a second click that starts a second batch.
            if app.imageFetch != nil {
                fetchingPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { page.padding(.vertical, 22) }
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: app.screen) { await rescanWhileVisible() }
    }

    private var stepHeader: some View {
        HStack(spacing: 10) {
            Text("新建验证批次").font(.system(size: 15, weight: .semibold))
            Text("第 \(step) 步 / 共 2 步 · \(step == 1 ? "选型号与待测板" : "选测试项")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var page: some View {
        if step == 1 { stepOne } else { stepTwo }
    }

    /// What is being validated, and on which boards.
    private var stepOne: some View {
        VStack(spacing: 22) {

            // A hand-written two-row layout rather than Form with .formStyle.
            VStack(spacing: 14) {
                pickerRow("型号") {
                    Picker("", selection: $app.model) {
                        ForEach(BoardModel.catalog) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                }
                pickerRow("流程") {
                    Picker("", selection: $app.flow) {
                        ForEach(ValidationFlow.allCases) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                }
            }
            .frame(width: 380)

            boardList
        }
        .frame(maxWidth: .infinity)
    }

    /// Which items, and what they will cost.
    private var stepTwo: some View {
        VStack(spacing: 22) {
            itemChecklist
            cost
        }
        .frame(maxWidth: .infinity)
    }

    /// What the batch will occupy, stated before the operator can start it.
    private var cost: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(app.estimatedDuration, systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
            if app.hasLongRun {
                Label("测试期间请保持电脑开机，不要合上盖子",
                      systemImage: "bolt.horizontal.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 380, alignment: .leading)
    }

    // MARK: - Footer

    /// What the step before the batch is doing. It has two halves and they look different: asking
    /// CI which build is current has no byte count to show, and the transfer has nothing to name
    /// until the asking is done.
    @ViewBuilder
    private var fetchingPanel: some View {
        VStack(spacing: 13) {
            Text("正在准备镜像").font(.system(size: 15, weight: .medium))
            switch app.imageFetch {
            case .asking:
                ProgressView().controlSize(.small)
                Text("正在获取镜像信息…").font(.callout).foregroundStyle(.secondary)
            case let .fetching(asset, done, total):
                if let total, total > 0 {
                    ProgressView(value: Double(done), total: Double(total)).frame(width: 320)
                    Text("\(bytes(done)) / \(bytes(total))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    // No content-length: a determinate bar would need a denominator we do not have.
                    ProgressView().controlSize(.small)
                    Text(bytes(done)).font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !asset.isEmpty {
                    Text(asset).font(.caption).foregroundStyle(.tertiary)
                }
            case nil:
                EmptyView()
            }
            // What happens next, not why it works this way.
            Text("镜像就绪后自动开始验证")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
        }
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Stays until the next attempt. The batch did not start, so the selection behind it is still
    /// the operator's to correct and press again.
    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.red)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.08))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            if step == 1 {
                Button("取消") { app.cancelNewBatch() }
                Button {
                    step = 2
                } label: {
                    Text("下一步").frame(minWidth: 90)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(app.confirmed.isEmpty)
            } else {
                Button("上一步") { step = 1 }
                    .disabled(app.imageFetch != nil)
                Button {
                    app.startBatch()
                } label: {
                    Text(startTitle).frame(minWidth: 120)
                }
                .keyboardShortcut(.defaultAction)
                // A second press would start a second download and a second batch.
                .disabled(app.resolvedItems.isEmpty || app.confirmed.isEmpty
                          || app.imageFetch != nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var startTitle: String {
        if app.imageFetch != nil { return "正在准备镜像…" }
        let n = app.confirmed.count
        return n > 1 ? "开始验证 \(n) 块" : "开始验证"
    }

    // MARK: - Boards

    /// The batch is the set confirmed here, not whatever happens to be plugged in later.
    private var boardList: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("待测板")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全选") { app.confirmed = Set(app.candidates.map(\.deviceID)) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(app.confirmed.count == app.candidates.count)
            }
            if app.candidates.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "cable.connector.slash").foregroundStyle(.secondary)
                    Text(app.isScanning && app.attached.isEmpty
                         ? "正在检测设备"
                         : "未检测到可用的 \(app.model.code)，请将待测板置于 MASKROM 模式")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(height: 34)
            } else {
                ForEach(app.candidates, id: \.id) { device in
                    boardRow(device)
                }
            }
            if !claimedNote.isEmpty {
                Text(claimedNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(width: 380)
    }

    private func boardRow(_ device: MaskromScan.Board) -> some View {
        let isOn = app.confirmed.contains(device.deviceID)
        return HStack(spacing: 10) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 17))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            Text("插座 \(device.socket)")
                .font(.system(.body, design: .monospaced))
            Spacer(minLength: 8)
            Text(app.model.socName)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture {
            if isOn { app.confirmed.remove(device.deviceID) }
            else    { app.confirmed.insert(device.deviceID) }
        }
        .help("确认后本批次固定为已勾选的板，之后插拔不影响")
    }

    /// Boards excluded from the candidate list, so their absence is explained. Counted by
    /// `AppState` from the same filter the list uses, or the explanation could describe a
    /// different set than the rows above it.
    private var claimedNote: String {
        let (claimed, others) = app.excludedCounts
        var parts: [String] = []
        if others > 0  { parts.append("\(others) 块其它型号") }
        if claimed > 0 { parts.append("\(claimed) 块已在其它批次中") }
        return parts.isEmpty ? "" : "另有 " + parts.joined(separator: "、") + "，不在本批次候选内"
    }

    /// Polls only while configuring; a running batch must not have the tool called under it.
    private func rescanWhileVisible() async {
        while app.screen == .newBatch && !Task.isCancelled {
            await app.scan()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - Item list

    /// Everything is selected by default.
    private var itemChecklist: some View {
        let all = TestItem.items(for: app.flow, model: app.model)
        // TestItem.optionalItems is used rather than filtering in place.
        let optional = TestItem.optionalItems(for: app.flow, model: app.model)
        // An implied item takes no top-level row; it is indented under the item implying it.
        let rows = all.filter { $0.impliedBy == nil }
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("测试项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全选") {
                    app.picked = Set(optional.map(\.code))
                    app.burninPhases = Set(BurninPhase.allCases)
                }
                .buttonStyle(.link)
                .font(.caption)
                // Disabled when there is nothing left to select. It used to be disabled unless the
                // run counted as 抽测, which tied a button's availability to a judgement about the
                // run rather than to what the button would do.
                .disabled(app.picked == Set(optional.map(\.code))
                          && app.burninPhases.count == BurninPhase.allCases.count)
            }
            ForEach(rows) { item in
                // A divider between the mandatory and optional groups makes it clear why the first.
                if item.isOptional, item.code == optional.first?.code {
                    Divider().padding(.vertical, 5)
                }
                itemRow(item)
                // The three T06 phases are indented under it.
                if item.code == "T06", app.picked.contains("T06") {
                    ForEach(BurninPhase.allCases) { phase in
                        phaseRow(phase)
                    }
                }
                // An implied item, E06 following E05, indented in the same way.
                ForEach(all.filter { implied in
                    implied.impliedBy == item.code
                        && app.resolvedItems.contains { $0.code == implied.code }
                }) { implied in
                    impliedRow(implied, by: item)
                }
            }
        }
        .frame(width: 380)
    }

    /// One item row. A locked item shows a lock rather than an unchecked box.
    /// The amount this item is bounded by, in the unit it is actually bounded by.
    ///
    /// Hours for the burn-in, cycles for suspend and reboot, full-device writes for the eMMC
    /// burn-in. Nothing else about an item is settable here: how the burn-in loads memory, what fio
    /// is told to do, how long a suspend dwells are *how the measurement is taken*, and moving one
    /// of those would make two reports incomparable without either of them saying so.
    /// How much of itself this item will do, chosen from a short list.
    ///
    /// A list rather than a number, because the amounts anyone actually wants are the default or
    /// something much smaller for a quick look; nobody dials 2700. A free field would have meant
    /// handling letters, punctuation, an empty box and a paste of something absurd — a lot of
    /// surface for a knob that has four useful positions.
    ///
    /// Whatever is picked here is what this run is judged against, so no amount needs a warning
    /// beside it. The default is simply first in the list.
    @ViewBuilder
    private func scaleField(_ item: TestItem) -> some View {
        switch item.code {
        case "T06":
            amountPicker(Binding(get: { app.scale.burninSeconds },
                                 set: { app.setScale(\.burninSeconds, $0) }),
                         options: [(43_200, "12 小时/段（默认）"), (21_600, "6 小时/段"),
                                   (7_200, "2 小时/段"), (1_800, "30 分钟/段"),
                                   (600, "10 分钟/段"), (60, "1 分钟/段")])
        case "T07", "T08":
            amountPicker(Binding(get: { app.scale.cycles },
                                 set: { app.setScale(\.cycles, $0) }),
                         options: [(3_000, "3000 次（默认）"), (1_000, "1000 次"),
                                   (300, "300 次"), (100, "100 次"), (20, "20 次"), (5, "5 次")])
        case "E05":
            amountPicker(Binding(get: { app.scale.emmcTargetN },
                                 set: { app.setScale(\.emmcTargetN, $0) }),
                         options: [(20, "20 次全盘写（默认）"), (10, "10 次"),
                                   (5, "5 次"), (2, "2 次"), (1, "1 次")])
        default:
            if item.isRecordOnly {
                Text("仅记录").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func amountPicker(_ value: Binding<Int>,
                              options: [(Int, String)]) -> some View {
        Picker("", selection: value) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func itemRow(_ item: TestItem) -> some View {
        let locked = TestItem.isLocked(item, picked: app.picked,
                                       flow: app.flow, model: app.model)
        let isOn = locked || app.picked.contains(item.code)
        return HStack(spacing: 10) {
            // Only this half responds to a click. The stepper beside it is a control of its own, and
            // with the tap gesture on the whole row, nudging an amount also unticked the item — the
            // two things an operator does here sit a few pixels apart and must not share a target.
            HStack(spacing: 10) {
                // A locked item still runs, so it stays ticked; the lock says it cannot be
                // unticked. A bare lock read as "unavailable", which is the opposite.
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text(item.displayTitle)
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // A locked item does not respond to a click.
                guard !locked else { return }
                if app.picked.contains(item.code) {
                    app.picked.remove(item.code)
                } else {
                    app.picked.insert(item.code)
                }
            }
            .help(locked ? lockReason(item) : "点击选择是否执行本项")

            // How much this run will ask of the board — the one thing about an item an operator
            // sets, and what the item is then judged against. No warning accompanies a small
            // amount: the report states it, and stating it is enough.
            if isOn { scaleField(item) }
        }
        .font(.body)
        .frame(height: 30)
        .accessibilityLabel("\(item.displayTitle)，\(locked ? "必跑" : (isOn ? "已选" : "未选"))")
    }

    /// Why a row is locked. Flashing states the condition, since it is deselectable on its own.
    private func lockReason(_ item: TestItem) -> String {
        item.isOptional
            ? "已选了板载测试项，刷机不可取消：板载测试要跑在刷入的固件上"
            : "结论的地基，不可取消：\(item.title)"
    }

    /// Row of an implied item, indented under the item implying it and not selectable.
    private func impliedRow(_ item: TestItem, by implier: TestItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(item.displayTitle)
            Spacer(minLength: 8)
            Text("随 \(implier.code) 自动执行")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.leading, 27)
        .frame(height: 26)
        .help("\(item.title)：\(item.method)")
    }

    private func phaseRow(_ phase: BurninPhase) -> some View {
        let isOn = app.burninPhases.contains(phase)
        return HStack(spacing: 10) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            Text(phase.title)
            Spacer(minLength: 8)
            // The amount the operator set, not the compiled-in standard. This read the constant
            // and so kept saying 12 小时 while the field above it said something else.
            Text(TestItem.hoursText(app.scale.burninSeconds))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.leading, 27)
        .frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture {
            if isOn { app.burninPhases.remove(phase) }
            else    { app.burninPhases.insert(phase) }
        }
        .help(phase.detail)
    }

    private func pickerRow<P: View>(_ label: String,
                                    @ViewBuilder picker: () -> P) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
            picker()
                .labelsHidden()
                .frame(maxWidth: .infinity)
        }
    }

}

