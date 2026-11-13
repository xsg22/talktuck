import SwiftUI

struct MacLANSyncView: View {
    @ObservedObject var state: AppState
    @StateObject private var channel = LANSyncChannel(role: .receiver)
    @State private var rpc: LANSyncRPC?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TalkTuckPageHeader(title: L10n.text("从 iPhone 同步"), subtitle: L10n.text("在 iPhone 的设置中打开“同步到 Mac”。")) { EmptyView() }
            TalkTuckCard {
                Text(L10n.text("录音、转录和摘要将复制到此 Mac；Mac 上的修改会保留。"))
                Text(L10n.text(channel.status)).foregroundStyle(.secondary)
                if channel.ready { Text(L10n.text(state.lanSyncMessage)).foregroundStyle(.secondary) }
                if let code = channel.code {
                    Text(code).font(.system(.title, design: .monospaced)).textSelection(.enabled)
                    Text(L10n.text("请核对 iPhone 上的验证码，相同后在两端确认。"))
                    if !channel.ready { Button(L10n.text("验证码相同")) { channel.confirm() } }
                }
                if let error { Text(L10n.text(error)).foregroundStyle(.red) }
                if channel.status == "未连接" || channel.status.hasPrefix("连接中断") {
                    Button(L10n.text("开始接收")) { start() }
                }
            }
        }
        .onAppear { start() }
        .onDisappear { rpc?.cancel(); rpc = nil; channel.stop() }
    }

    private func start() {
        do { rpc = try state.makeLANSyncReceiver(channel: channel); error = nil; channel.start() }
        catch { self.error = "无法准备本机接收目录，请检查存储空间。" }
    }
}
