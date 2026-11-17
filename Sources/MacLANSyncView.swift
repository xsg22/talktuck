import SwiftUI

struct MacLANSyncView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var channel: LANSyncChannel
    init(state: AppState) { self.state = state; self.channel = state.lanSyncChannel }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TalkTuckPageHeader(title: L10n.text("从 iPhone 同步"), subtitle: L10n.text("在 iPhone 的设置中打开“同步到 Mac”。")) { EmptyView() }
            TalkTuckCard {
                Text(L10n.text("录音、转录和摘要将复制到此 Mac；Mac 上的修改会保留。"))
                Text(L10n.text(channel.status)).foregroundStyle(.secondary)
                if channel.ready { Text(L10n.text(state.lanSyncMessage)).foregroundStyle(.secondary) }
                if let code = channel.code, !channel.ready {
                    Text(code).font(.system(.title, design: .monospaced)).textSelection(.enabled)
                    Text(L10n.text("请核对 iPhone 上的验证码，相同后在两端确认。"))
                    Button(L10n.text("验证码相同")) { channel.confirm() }
                }
                if let error = state.lanSyncError { Text(L10n.text(error)).foregroundStyle(.red) }
                if channel.status == "未连接" || channel.status.hasPrefix("连接中断") {
                    Button(L10n.text("开始接收")) { state.startLANSync() }
                }
                if !channel.trustedDevices.isEmpty {
                    Text(L10n.text("已配对设备")).font(.headline)
                    ForEach(channel.trustedDevices.keys.sorted(), id: \.self) { id in
                        HStack { Text(channel.trustedDevices[id] ?? "iPhone"); Spacer(); Button(L10n.text("解除配对")) { channel.forget(id) } }
                    }
                }
            }
        }.onAppear { state.startLANSync() }
    }
}
