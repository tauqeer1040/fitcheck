"""Render the single Font Awesome glyph the app actually uses (Brands
whatsapp, U+F1E2) into a small standalone asset, so the whole
font_awesome_flutter dependency (3 OTF files) can be dropped."""
from PIL import Image, ImageDraw, ImageFont

SRC = ('C:/Users/tau/AppData/Local/Pub/Cache/hosted/pub.dev/'
       'font_awesome_flutter-11.0.0/lib/fonts/'
       'Font-Awesome-7-Brands-Regular-400.otf')
OUT = 'C:/Users/tau/code/fitcheck/assets/whatsapp_glyph.png'

SIZE = 256
font = ImageFont.truetype(SRC, SIZE)
img = Image.new('RGBA', (SIZE * 2, SIZE * 2), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
# whatsapp is Brands U+F232 (read from the package's
# font_awesome_flutter.dart, not guessed).
d.text((SIZE // 2, SIZE // 2), '\uf232', font=font, fill=(255, 255, 255, 255),
       anchor='mm')

bbox = img.getbbox()
print('rendered bbox:', bbox)
img = img.crop(bbox)
print('cropped size:', img.size)

# The app draws this at 20dp; 96px covers @4x with room to spare.
if max(img.size) > 96:
    r = 96 / max(img.size)
    img = img.resize((round(img.width * r), round(img.height * r)),
                     Image.LANCZOS)
img.save(OUT, optimize=True)
print('wrote', OUT, img.size)

import os
print('bytes:', os.path.getsize(OUT))