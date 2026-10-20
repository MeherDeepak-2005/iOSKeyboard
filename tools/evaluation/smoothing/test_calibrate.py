import math
import unittest
from calibrate import BASELINE, accepts, choice, counts


class CalibrationTests(unittest.TestCase):
    def gate(self, **kw):
        return dict(typed='typo',candidate='type',kind='close',typedMargin=2.,candidateGap=3.,spatialCost=.8,allowsCloseRescue=True,**kw)

    def test_rescue_requires_margin_gap_and_close_channel(self):
        p={**BASELINE,'closeRescueMargin':1.5,'closeRescueGap':2.,'closeRescueMaxCost':1.}
        g=self.gate()
        self.assertTrue(accepts(g,p))
        for k,v in [('typedMargin',1.5),('candidateGap',1.99),('spatialCost',1.01),('allowsCloseRescue',False)]:
            self.assertFalse(accepts({**g,k:v},p))
        self.assertTrue(accepts({**g,'candidateGap':None},p))

    def test_baseline_close_is_exact_old_strict_margin(self):
        for margin in [-10.,0.,2.99,3.,3.000001,8.]:
            for gap in [None,0.,.2,9.]:
                self.assertEqual(accepts({**self.gate(),'typedMargin':margin,'candidateGap':gap},BASELINE),margin>3.)

    def test_real_loose_and_severe_keep_existing_guards(self):
        p={**BASELINE,'closeRescueMargin':0.,'closeRescueGap':0.}
        self.assertFalse(accepts({**self.gate(),'kind':'realWord','typedMargin':5.},p))
        self.assertTrue(accepts({**self.gate(),'kind':'realWord','typedMargin':5.1},p))
        self.assertFalse(accepts({**self.gate(),'kind':'loose','typedMargin':4.,'candidateGap':.9},p))
        self.assertFalse(accepts({**self.gate(),'kind':'severe','typedMargin':math.log(10)},p))
        self.assertTrue(accepts({**self.gate(),'kind':'severe','typedMargin':3.,'candidateGap':math.log(2)},p))

    def test_direct_protected_outcomes_are_fixed(self):
        row=dict(typed='dont',intended="don't",choice="don't",kind='typo_single')
        self.assertEqual(choice(row,BASELINE),"don't")
        self.assertEqual(counts([row],BASELINE)['typo']['correct'],1)


if __name__=='__main__':unittest.main()
