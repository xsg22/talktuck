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
            return types.SimpleNamespace(text='hello shared phrase' if len(calls)==2 else 'shared phrase world')
        with patch.object(worker,'generate_complete',generate):
            result=worker.recognized_segment(None,audio,start=12,end=20,language='English')
        self.assertEqual(len(calls),3)
        self.assertEqual(result['text'],'hello shared phrase world')
        parts=result['alignmentParts']
        self.assertEqual(parts[0]['start'],12)
        self.assertLess(parts[1]['start'],parts[0]['end'])
        self.assertEqual(parts[1]['end'],20)
        self.assertEqual(''.join(p['text'] for p in parts),result['text'])
        self.assertGreater(sum(calls[1:]),len(audio))

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

if __name__=='__main__':unittest.main()
