"""One-off: regenerate assets/logo_padded.png for flutter_launcher_icons.

Black 1024x1024 canvas, logo centered and scaled to 80% of the canvas
width (20% total margin, 10% per side), preserving aspect ratio — no
crop, no alpha in the background so it doubles as a square/legacy icon.
"""
from PIL import Image
import os

SIZE = 1024
LOGO_FRAC = 0.80  # logo width = 80% of icon width (20% total margin)

logo = Image.open("assets/logo3.png").convert("RGBA")

canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 255))

# Scale by width so the logo ends up exactly 90% of the icon width.
scale = (SIZE * LOGO_FRAC) / logo.width
new_w = round(logo.width * scale)
new_h = round(logo.height * scale)
resized = logo.resize((new_w, new_h), Image.LANCZOS)

canvas.paste(resized, ((SIZE - new_w) // 2, (SIZE - new_h) // 2), resized)
canvas.convert("RGB").save("assets/logo_padded.png")

bbox = canvas.split()[3].getbbox()
print(f"logo_padded: {SIZE}x{SIZE}, logo {new_w}x{new_h} ({LOGO_FRAC:.0%} width), content bbox={bbox}")
print("done")
