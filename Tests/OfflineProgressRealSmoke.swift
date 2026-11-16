import Foundation

@main struct OfflineProgressRealSmoke {
    final class Capture: @unchecked Sendable {
        private let lock=NSLock(); private var data:[OfflineRecognitionProgress]=[]
        func add(_ item:OfflineRecognitionProgress) { lock.lock(); data.append(item); lock.unlock() }
        func values()->[OfflineRecognitionProgress] { lock.lock(); defer { lock.unlock() }; return data }
    }
    static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), audio=URL(fileURLWithPath:CommandLine.arguments[3]), executable=URL(fileURLWithPath:CommandLine.arguments[4])
        guard let model=ASRResources.qwen else { fatalError("ASR model unavailable") }
        let progress=Capture()
        let task=Task.detached {
            try TranscriptionEngine(temporaryRoot:root).transcribeBatch(audio:audio,model:model,executable:executable,language:"en",hotwords:[],context:"",windowSeconds:6,checkpointDirectory:root.appendingPathComponent("real-checkpoint"),onProgress:{ progress.add($0) })
        }
        let deadline=Date().addingTimeInterval(180)
        while Date()<deadline && !progress.values().contains(where:{$0.processedSeconds>0}) { try await Task.sleep(for:.milliseconds(200)) }
        guard let first=progress.values().first(where:{$0.processedSeconds>0}) else { fatalError("no real progress") }
        precondition(first.processedSeconds<first.totalSeconds && !first.preview.isEmpty)
        let output=try await task.value
        precondition(!output.text.isEmpty && (progress.values().last?.processedSeconds ?? 0)>first.processedSeconds)
        print("PASS: packaged recognition engine emitted a text preview and actual progress before completion")
    }
}
