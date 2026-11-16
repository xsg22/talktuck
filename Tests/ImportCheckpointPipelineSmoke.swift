import Foundation
import AVFoundation
@main struct ImportCheckpointPipelineSmoke {
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), source=URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let worker=root.appendingPathComponent("qwen-asr"),model=root.appendingPathComponent("model"),audio=root.appendingPathComponent("audio.wav"),calls=root.appendingPathComponent("calls"),checkpoint=root.appendingPathComponent("checkpoint")
        try FileManager.default.createDirectory(at:model,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:source.appendingPathComponent("Tests/ImportCheckpointWorkerFake.py"),to:worker)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:worker.path)
        setenv("TALKTUCK_TEST_RUNTIME",source.appendingPathComponent("Native/QwenRuntime").path,1)
        setenv("TALKTUCK_TEST_CALLS",calls.path,1);setenv("TALKTUCK_TEST_INTERRUPT","1",1)
        let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        do {
            let file=try AVAudioFile(forWriting:audio,settings:format.settings),buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!
            buffer.frameLength=16000;buffer.floatChannelData![0].initialize(repeating:0.1,count:16000)
            for _ in 0..<60 {try file.write(from:buffer)}
        }
        do {
            _=try TranscriptionEngine(temporaryRoot:root).transcribeBatch(audio:audio,model:model,executable:worker,language:"en",hotwords:[],context:"",windowSeconds:12,checkpointDirectory:checkpoint)
            fatalError("interruption must fail")
        } catch { precondition(!(error is CancellationError)) }
        let firstCount=try String(contentsOf:calls).split(separator:"\n").count
        precondition(firstCount==3)
        setenv("TALKTUCK_TEST_INTERRUPT","0",1)
        let output=try TranscriptionEngine(temporaryRoot:root).transcribeBatch(audio:audio,model:model,executable:worker,language:"en",hotwords:[],context:"",windowSeconds:12,checkpointDirectory:checkpoint)
        let finalCount=try String(contentsOf:calls).split(separator:"\n").count
        precondition(finalCount==6,"only three uncompleted windows should run after interruption")
        precondition(!output.text.isEmpty && output.paragraphs.last?.end==60)
        print("PASS: streamed import interruption and restart reuse two completed windows")
    }
}
