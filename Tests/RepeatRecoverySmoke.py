import pathlib,sys,types,unittest
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'Native/QwenRuntime'))
from repeat_recovery import find_repeat,recover,trim_overlap,RATE

class Audio:
 def __len__(self):return 117*RATE
class RepeatTests(unittest.TestCase):
 def setUp(self):
  self.phrase=''.join(chr(0x4e00+i) for i in range(116))
  self.baseline=self.phrase*5;self.correct=self.phrase*4
  self.good=dict(text=self.correct,alignmentParts=[dict(text=self.correct,start=0,end=117)])
 def test_detect_and_confirm_two_candidates(self):
  self.assertIsNotNone(find_repeat(self.baseline))
  with patch('repeat_recovery.windowed',side_effect=[dict(self.good),dict(self.good)]) as call:
   result=recover(None,Audio(),self.baseline,0,'Chinese',None,None)
  self.assertEqual(call.call_count,2);self.assertEqual(result['text'],self.correct);self.assertEqual(result['originalText'],self.baseline)
 def test_real_repetition_is_never_removed_when_probe_keeps_it(self):
  same=dict(text=self.baseline,alignmentParts=[dict(text=self.baseline,start=0,end=117)])
  with patch('repeat_recovery.windowed',return_value=same) as call:
   self.assertIsNone(recover(None,Audio(),self.baseline,0,'Chinese',None,None));self.assertEqual(call.call_count,1)
 def test_disagreement_and_probe_error_keep_original(self):
  bad=dict(text=self.correct[:-20]+'不同内容'*5,alignmentParts=[])
  with patch('repeat_recovery.windowed',side_effect=[dict(self.good),bad]):self.assertIsNone(recover(None,Audio(),self.baseline,0,'Chinese',None,None))
  with patch('repeat_recovery.windowed',side_effect=ValueError('failed')):self.assertIsNone(recover(None,Audio(),self.baseline,0,'Chinese',None,None))
 def test_language_and_size_gates(self):
  with patch('repeat_recovery.windowed',side_effect=AssertionError):
   self.assertIsNone(recover(None,Audio(),self.baseline,0,'English',None,None))
   self.assertIsNone(recover(None,Audio(),'nonrepeat',0,'Chinese',None,None))
 def test_audio_overlap_retains_new_words(self):
  tail,trimmed=trim_overlap('前面这段相同的文字用于覆盖','这段相同的文字用于覆盖后面的新内容')
  self.assertTrue(trimmed);self.assertEqual(tail,'后面的新内容')
if __name__=='__main__':unittest.main()
