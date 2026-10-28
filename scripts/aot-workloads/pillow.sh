# Pillow workload: decode, resize, rotate, filters, colour conversion and
# encoding for JPEG/PNG/WebP — the old one built a 256×256 image and resized
# it once (611 translations).
python3 - <<'PY' > /dev/null
from PIL import Image, ImageFilter

base = Image.new("RGB", (512, 512))
px = base.load()
for y in range(512):
    for x in range(512):
        px[x, y] = ((x * 3) % 256, (y * 5) % 256, ((x ^ y) * 7) % 256)

for _ in range(8):
    im = base.resize((256, 256)).rotate(30).convert("L")
    im.filter(ImageFilter.GaussianBlur(2))
    im.filter(ImageFilter.SHARPEN)
    im.convert("RGB").save("/tmp/aotw-pillow.jpg", quality=85)
    Image.open("/tmp/aotw-pillow.jpg").load()
    base.save("/tmp/aotw-pillow.png")
    Image.open("/tmp/aotw-pillow.png").load()
    base.save("/tmp/aotw-pillow.webp", quality=80)
    Image.open("/tmp/aotw-pillow.webp").load()
PY
