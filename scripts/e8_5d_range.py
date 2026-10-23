import json, sys
from scipy.optimize import fsolve
d = json.load(open(sys.argv[1])); e = json.load(open(sys.argv[2])); sp = json.load(open(sys.argv[3]))
out = {}
for M in ('A', 'B'):
    b = d['models'][M]['bits']; Ds = b['by_side_uJ']; lo, hi = b['range_uJ']
    mu = e['models'][M]['mean_model_error']
    f = lambda x: [Ds['pcm'] / (1 + mu['pcm'] + 2 * x[0]) + Ds['sram'] / (1 + mu['sram'] + 2 * x[1]) - lo,
                   Ds['pcm'] / (1 + mu['pcm'] - 2 * x[0]) + Ds['sram'] / (1 + mu['sram'] - 2 * x[1]) - hi]
    se = fsolve(f, [0.014, 0.016] if M == "A" else [0.041, 0.010], xtol=1e-14)
    zold = sp['models'][M]['sides']['pcm']['parked_zero']; znew = e['models'][M]['zero_parked_measured_uJ']
    pm = Ds['pcm'] - zold
    nlo = pm / (1 + mu['pcm'] + 2 * se[0]) + Ds['sram'] / (1 + mu['sram'] + 2 * se[1]) + znew
    nhi = pm / (1 + mu['pcm'] - 2 * se[0]) + Ds['sram'] / (1 + mu['sram'] - 2 * se[1]) + znew
    cor = pm / (1 + mu['pcm']) + Ds['sram'] / (1 + mu['sram']) + znew
    print(f"{M}: SE pcm {se[0]*100:.3f} %, sram {se[1]*100:.3f} % (check: {f(se)[0]:.1e}, {f(se)[1]:.1e}); "
          f"mean pcm {mu['pcm']*100:+.2f} %, sram {mu['sram']*100:+.2f} %")
    print(f"   rel5 range {lo:.3f}-{hi:.3f}, corrected {b['corrected_uJ']:.3f}; new D {e['models'][M]['D_uJ']:.3f}, "
          f"range {nlo:.3f}-{nhi:.3f}, corrected {cor:.3f} (E8.5d {e['models'][M]['corrected_uJ']:.3f})")
    out[M] = {'se_pcm': se[0], 'se_sram': se[1], 'range_new_uJ': [nlo, nhi], 'corrected_new_uJ': cor}
json.dump(out, open(sys.argv[4], 'w'), indent=1)
