# NumPy workload: array arithmetic, reductions, sorting, indexing, matrix
# multiplication and FFT — broader than the single arange().sum() it replaced.
python3 - <<'PY' > /dev/null
import numpy as np

a = np.arange(2_000_000, dtype=np.float64)
for _ in range(20):
    b = (a * 2.0 + 1.0).sum()
    c = np.sqrt(a).mean()
    d = np.sort(np.random.default_rng(1).random(200000))
    e = d[::7].sum()
    f = np.dot(np.ones((200, 200)), np.ones((200, 200)))
    g = np.fft.fft(np.random.default_rng(2).random(65536))
    h = np.clip(a, 0, 1000).std()
print(b, c, e, f[0, 0], abs(g[0]), h)
PY
