import Foundation
import AVFoundation
@main struct ImportedFallbackPipelineSmoke {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),source=URL(fileURLWithPath:CommandLine.arguments[2])
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let executable=root.appendingPathComponent("qwen-asr"),audio=root.appendingPathComponent("audio.wav")
  try FileManager.default.copyItem(at:source.appendingPathComponent("Tests/ImportedFallbackWorkerFake.py"),to:executable)
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
  let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
  do { let f=try AVAudioFile(forWriting:audio,settings:format.settings),b=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!
   b.frameLength=16000;b.floatChannelData![0].initialize(repeating:0.1,count:16000)
   for _ in 0..<48 {try f.write(from:b)}
  }
  let result=try TranscriptionEngine(temporaryRoot:root).transcribeBatch(audio:audio,model:root,executable:executable,language:"en",hotwords:[],context:"",windowSeconds:24,initialOverlapSeconds:3,allowParaformerFallback:true)
  precondition(result.fallbackCount==1 && result.readingFallback().fallbackCount==1)
  precondition(result.text=="alpha repeated shared text\nrepeated shared text beta\nbeta next","Cross-model overlaps must not delete real speech")
  let marked=MeetingRecordingAppend.engineName(existing:nil,appending:false,hasExistingText:false,outputs:[result])
  precondition(marked.contains("paraformer-fallback"))
  let normal=TranscriptionOutput(text:"ok",subtitles:"")
  precondition(MeetingRecordingAppend.engineName(existing:marked,appending:true,hasExistingText:true,outputs:[normal]).contains("paraformer-fallback"))
  precondition(!MeetingRecordingAppend.engineName(existing:marked,appending:false,hasExistingText:true,outputs:[normal]).contains("paraformer-fallback"))
  print("PASS: imported fallback provenance and cross-model boundary preservation")
 }
}
