"""One-off: undo the 40-degree rotations on the arrow assets.

Both arrows currently sit at net +40 deg (arrow.png got +40; arrow2.png
got -40 then +80). Rotate each back -40 deg, trim transparent padding,
restore the original 1536x1024 size.
"""
from PIL import Image

for path in ("assets/arrow.png", "assets/arrow2.png"):
    img = Image.open(path).convert("RGBA")
    print(f"{path} before: {img.size}")
    img = img.rotate(-40, expand=True, resample=Image.Resampling.BICUBIC)
    img = img.crop(img.getbbox())  # trim transparent padding
    img = img.resize((1536, 1024), Image.LANCZOS)
    img.save(path, optimize=True)
    print(f"{path} after:  {img.size}")

print("done")
