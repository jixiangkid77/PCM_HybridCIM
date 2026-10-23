#!/usr/bin/env python3
"""P2R-E8.4e rule C (claude/p2r-e8-5d-sandbox.md, section 3.2): replace the
'parked on a word with zero bits' term of E8.4e by the E8.5d measurement.
new zero term (condition c) = tt 25 C measured value x ratio of A_pcm_l04 k1's
6.08-ms parked energy at c to tt 25 C (d_rom_e85d.json 'conditions').
Corrected value as E8.6a-3 / E8.5d drom: model parts divided per side by
(1 + mean model error), the measured zero-parked part not divided."""
import json, sys, hashlib

def md5(p):
    return hashlib.md5(open(p, 'rb').read()).hexdigest()

cmp_p, split_p, e85d_p = sys.argv[1:4]
cmpj = json.load(open(cmp_p)); split = json.load(open(split_p)); e85d = json.load(open(e85d_p))
print('inputs: compare', md5(cmp_p), '| split', md5(split_p), '| d_rom_e85d', md5(e85d_p))
names = {'ttm40': 'tt:-40:1.80', 'tt85': 'tt:85:1.80', 'ff25': 'ff:25:1.80', 'ss25': 'ss:25:1.80', 'ff85': 'ff:85:1.80'}
order = ['ttm40', 'ss25', 'ff25', 'tt85', 'ff85']
out = {'inputs': {'compare': md5(cmp_p), 'split': md5(split_p), 'd_rom_e85d': md5(e85d_p)}, 'models': {}}
for m in ('A', 'B'):
    em = e85d['models'][m]; err = em['mean_model_error']
    s = split['models'][m]['sides']
    # tt 25 C (rel5) recomputed the same way: must equal E8.5d drom
    zt = em['zero_parked_measured_uJ']
    D_tt = split['models'][m]['totals']['D_uJ'] - s['pcm']['parked_zero'] + zt
    C_tt = (s['pcm']['D_uJ'] - s['pcm']['parked_zero']) / (1 + err['pcm']) + s['sram']['D_uJ'] / (1 + err['sram']) + zt
    print(f'model {m}: tt 25 C recomputed D {D_tt:.6f} (E8.5d {em["D_uJ"]:.6f}), corrected {C_tt:.6f} (E8.5d {em["corrected_uJ"]:.6f})')
    assert abs(D_tt - em['D_uJ']) < 1e-9 and abs(C_tt - em['corrected_uJ']) < 1e-9
    leak_tt = s['pcm']['parked_leak'] + s['sram']['parked_leak']
    rows = {'tt25': {'D_old': split['models'][m]['totals']['D_uJ'], 'zero_old': s['pcm']['parked_zero'], 'zero_new': zt,
                     'D_new': D_tt, 'corr_new': C_tt, 'leak': leak_tt}}
    for c in order:
        p = cmpj['conditions'][c]['models'][m]['parts_uJ']
        D_old = cmpj['conditions'][c]['models'][m]['D_uJ']
        zero_old = p['pcm_parked_zero'] + p['sram_parked_zero']
        zn = e85d['conditions'][names[c]]['zero_parked_uJ'][m]
        assert abs(zn - zt * e85d['conditions'][names[c]]['ratio_to_tt']) < 1e-12
        pcm_model = sum(v for k, v in p.items() if k.startswith('pcm_') and k != 'pcm_parked_zero')
        sram_model = sum(v for k, v in p.items() if k.startswith('sram_') and k != 'sram_parked_zero')
        assert abs(pcm_model + sram_model + zero_old - D_old) < 1e-9
        D_new = D_old - zero_old + zn
        C_new = pcm_model / (1 + err['pcm']) + sram_model / (1 + err['sram']) + zn
        rows[c] = {'D_old': D_old, 'zero_old': zero_old, 'zero_new': zn, 'D_new': D_new, 'corr_new': C_new,
                   'corr_old': cmpj['conditions'][c]['models'][m]['corrected_uJ'],
                   'leak': p['pcm_parked_leak'] + p['sram_parked_leak'],
                   'D_trains': cmpj['conditions'][c]['models'][m]['D_trains_uJ']}
    out['models'][m] = rows
    print(f'\nmodel {m}   cond   D_old    zero_old -> zero_new   D_new   x tt25 | corrected new (old)  x tt25 | leak share new | trains-check new')
    for c in ['tt25'] + order:
        r = rows[c]
        tr = ''
        if 'D_trains' in r:
            Dt = r['D_trains'] - r['zero_old'] + r['zero_new']
            tr = f'{Dt:8.3f} ({(Dt / r["D_new"] - 1) * 100:+.1f} %)'
            r['D_trains_new'] = Dt
        co = f' ({r["corr_old"]:.3f})' if 'corr_old' in r else ''
        print(f'          {c:5s} {r["D_old"]:8.3f}  {r["zero_old"]:7.3f} -> {r["zero_new"]:6.3f}  {r["D_new"]:8.3f}  {r["D_new"] / rows["tt25"]["D_new"]:5.2f} | {r["corr_new"]:8.3f}{co:10s} {r["corr_new"] / rows["tt25"]["corr_new"]:5.2f} | {r["leak"] / r["D_new"] * 100:5.1f} % | {tr}')
json.dump(out, open(sys.argv[4], 'w'), indent=1)
print('\nwritten', sys.argv[4], md5(sys.argv[4]))
