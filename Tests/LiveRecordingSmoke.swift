import Foundation

@main struct LiveRecordingSmoke {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("talktuck-profile-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        let record = MeetingRecord(title: "后台实时验收", status: .recording)
        _ = try library.save(record)
        let state = AppState(storageURL: root, connectionNamespace: "profile-test-")
        state.prepareLiveRecording()
        check(state.liveEnabled, "新会话默认实时识别")
        state.select(record.id); state.recording = true
        state.mainWindowVisible = false
        check(state.compactRecordingUI && state.liveEnabled, "窗口隐藏不关闭实时识别")
        state.handleLiveEvent(.init(type: "partial", text: "草稿一", start: 0, end: 1), meetingID: record.id)
        let firstSaved = try library.load(record.id)
        state.handleLiveEvent(.init(type: "partial", text: "草稿二", start: 0, end: 2), meetingID: record.id)
        check(try library.load(record.id).updated == firstSaved.updated, "高频partial不会每次写完整会议")
        state.mainWindowVisible = true
        check(state.liveText == "草稿二" && state.livePartial == "草稿二", "显示窗口立即呈现最近草稿，不等待新语音")
        state.mainWindowVisible = false
        for i in 0..<5 {
            state.handleLiveEvent(.init(type: "commit", text: "确认句\(i)", start: Double(i), end: Double(i + 1)), meetingID: record.id)
        }
        let saved = try library.load(record.id)
        check(saved.liveUtterances.count == 5 && saved.previewText.contains("确认句4"), "后台提交句仍逐条保存，无遗漏")
        state.mainWindowVisible = true
        check(state.liveText.contains("确认句4") && state.liveEnabled, "回到前台保留最新已确认文字和识别开关")
        state.mainWindowVisible = false
        state.handleLiveEvent(.init(type: "partial", text: "最后草稿", start: 6, end: 7), meetingID: record.id)
        state.handleLiveEvent(.init(type: "done", text: "", start: 0, end: 0), meetingID: record.id)
        check(state.liveText.contains("最后草稿") && state.livePartial.isEmpty, "尾段结束刷新但不冒充确认句")
        state.recording = false
        state.prepareLiveRecording(); state.recording = true
        check(state.compactRecordingUI && state.liveEnabled, "窗口隐藏不关闭实时识别")
        state.prepareLiveRecording()
        check(state.liveEnabled, "录音中准备操作不能关闭实时识别")
        state.mainWindowVisible = true
        state.expandedRealtime = true
        check(!state.compactRecordingUI, "显示窗口后恢复正文")
        state.recording = false
        print("PASS: 统一实时识别、隐藏不关ASR、后台partial节流、commit落盘、恢复窗口立即呈现、尾段刷新。无硬件采集。")
    }
}
