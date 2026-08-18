import sys, os
def load(objp):
    mtlp = objp.replace('.obj', '.mtl')
    cols = {}
    if os.path.exists(mtlp):
        cur = None
        for l in open(mtlp):
            t = l.split()
            if not t: continue
            if t[0] == 'newmtl': cur = t[1]
            elif t[0] == 'Kd' and cur: cols[cur] = tuple(float(x) for x in t[1:4])
    V = []; tris = []; cur = None
    for l in open(objp):
        t = l.split()
        if not t: continue
        if t[0] == 'v': V.append(tuple(float(x) for x in t[1:4]))
        elif t[0] == 'usemtl': cur = t[1]
        elif t[0] == 'f':
            idx = [int(p.split('/')[0]) - 1 for p in t[1:]]
            for k in range(1, len(idx) - 1):          # fan-triangulate n-gons
                tris.append(((idx[0], idx[k], idx[k+1]), cur))
    return V, tris, cols

def emit(objp, name):
    V, tris, cols = load(objp)
    # De-index: a vertex shared by two materials cannot carry one colour, and flat
    # shading needs unshared vertices anyway.
    verts = []; vcols = []; ind = []
    mats = sorted({m for _, m in tris})
    per = {m: [] for m in mats}
    for (a, b, c), m in tris:
        per[m].append((a, b, c))
    out = []
    for m in mats:
        verts = []; vcols = []; ind = []
        for (a, b, c) in per[m]:
            base = len(verts)
            for i in (a, b, c):
                verts.append(V[i]); vcols.append(cols.get(m, (1, 1, 1)))
            ind += [base, base + 1, base + 2]
        out.append((m, verts, vcols, ind))
    return out

if __name__ == '__main__':
    for m, verts, vcols, ind in emit(sys.argv[1], sys.argv[2]):
        print(f'{m}: {len(verts)} verts, {len(ind)//3} tris, colour {vcols[0]}')
