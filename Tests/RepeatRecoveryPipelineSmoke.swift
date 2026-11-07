import Foundation
import AVFoundation

@main struct RepeatRecoveryPipelineSmoke {
    static func main() throws {
        guard let base = ProcessInfo.processInfo.environment["TALKTUCK_TEST_ROOT"],
              let fake = ProcessInfo.processInfo.environment["TALKTUCK_FAKE_WORKER"] else { fatalError("Missing isolated test inputs") }
        let root = URL(fileURLWithPath:base).appendingPathComponent("repeat-pipeline-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let worker = root.appendingPathComponent("qwen-asr")
        try FileManager.default.copyItem(at:URL(fileURLWithPath:fake),to:worker)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:worker.path)
        let audio=root.appendingPathComponent("fixture.wav"), format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        do {
            let file=try AVAudioFile(forWriting:audio,settings:format.settings), b=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!
            b.frameLength=16000;b.floatChannelData![0].initialize(repeating:0.1,count:16000)
            try file.write(from:b);try file.write(from:b)
        }
        let output=try TranscriptionEngine(temporaryRoot:root).transcribeBatch(audio:audio,model:root,executable:worker,language:"zh",hotwords:[],context:"",windowSeconds:24,recoverRepeatedOutput:true)
        precondition(output.text=="复核正文。" && output.originalCandidates.count==1)
        let original=output.originalCandidates[0]
        precondition(original.original=="首版重复。首版重复。" && original.selected==output.text && original.start==0 && original.end==2)
        let fallback=output.readingFallback();precondition(fallback.originalCandidates==output.originalCandidates)
        var record=MeetingRecord(title:"isolated",status:.recorded);record.audioFiles=["a"]
        try MeetingRecordingAppend.apply(outputs:[fallback],files:["a"],durations:[2],appending:false,to:&record)
        let decoded=try JSONDecoder().decode(MeetingRecord.self,from:JSONEncoder().encode(record))
        precondition(decoded.text==output.text && decoded.originalRecognitionCandidates.count==1 && decoded.originalRecognitionCandidates[0].audioFile=="a")
        print("PASS: worker option, selected text, durable original candidate and backward-compatible record")
    }
}
