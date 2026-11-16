import pathlib,sys,types,unittest
from unittest.mock import patch

sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'Native/QwenRuntime'))
import worker
from inference_policy import RATE,TokenLimitReached

class Recovery(unittest.TestCase):
    def test_only_failing_range_is_split_with_complete_ordered_coverage(self):
        audio=[.1]*(8*RATE);calls=[]
        def generate(model,samples,**kwargs):
            calls.append(len(samples))
            if len(samples)>6*RATE:raise TokenLimitReached('limit')
            return types.SimpleNamespace(text='hello shared phrase' if len(calls)==3 else 'shared phrase world')
        with patch.object(worker,'generate_complete',generate):
            result=worker.recognized_segment(None,audio,start=12,end=20,language='English')
        self.assertEqual(len(calls),4)
        self.assertEqual(result['text'],'hello shared phrase world')
        parts=result['alignmentParts']
        self.assertEqual(parts[0]['start'],12)
        self.assertLess(parts[1]['start'],parts[0]['end'])
        self.assertEqual(parts[1]['end'],20)
        self.assertEqual(''.join(p['text'] for p in parts),result['text'])
        self.assertGreater(sum(calls[2:]),len(audio))

    def test_dense_speech_retries_whole_window_before_splitting(self):
        calls=[]
        def generate(model,samples,**kwargs):
            calls.append((len(samples),kwargs.get('token_limit')))
            if kwargs.get('token_limit') is None:raise TokenLimitReached('limit')
            return types.SimpleNamespace(text='A complete name')
        with patch.object(worker,'generate_complete',generate):
            result=worker.recognized_segment(None,[.1]*(8*RATE),start=0,end=8,language='English')
        self.assertEqual(result['text'],'A complete name')
        self.assertEqual(calls,[(8*RATE,None),(8*RATE,1024)])
        self.assertNotIn('alignmentParts',result)

    def test_ambiguous_speech_overlap_is_never_published(self):
        audio=[.1]*(8*RATE);calls=[]
        def generate(model,samples,**kwargs):
            if len(samples)>6*RATE:raise TokenLimitReached('limit')
            calls.append(1)
            return types.SimpleNamespace(text='first phrase' if len(calls)%2 else 'another phrase')
        with patch.object(worker,'generate_complete',generate):
            with self.assertRaises(TokenLimitReached):
                worker.recognized_segment(None,audio,start=0,end=8,language='English')

    def test_unrecoverable_limit_and_other_failures_propagate(self):
        audio=[0.]*(4*RATE)
        for failure in (TokenLimitReached('limit'),ValueError('other')):
            with patch.object(worker,'generate_complete',side_effect=failure):
                with self.assertRaises(type(failure)):
                    worker.recognized_segment(None,audio,start=0,end=4,language=None)

    def test_terminal_child_token_limit_stays_an_unsafe_seam(self):
        with patch.object(worker,'generate_complete',side_effect=TokenLimitReached('limit')):
            with self.assertRaises(worker.SeamAmbiguous):
                worker.recognized_segment(None,[.1]*(4*RATE),start=0,end=4,language='English')

    def test_repetitive_recovery_fails_closed_without_deleting_text(self):
        self.assertTrue(worker.suspicious_repetition('重复内容'*8))
        self.assertFalse(worker.suspicious_repetition('这是一段正常谈话，用来验证短句没有被重复生成。'))
        def generate(model,samples,**kwargs):
            if len(samples)>2*RATE:raise TokenLimitReached('limit')
            return types.SimpleNamespace(text='重复内容'*8)
        with patch.object(worker,'generate_complete',generate):
            with self.assertRaises(TokenLimitReached):
                worker.recognized_segment(None,[.1]*(4*RATE),start=0,end=4,language='Chinese')

if __name__=='__main__':unittest.main()
