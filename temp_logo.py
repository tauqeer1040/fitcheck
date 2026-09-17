from PIL import Image, ImageDraw
import os

# Load the logo
logo_path = "assets/logo.png"
logo = Image.open(logo_path).convert("RGBA")

# Add padding (same color as Android background #000000)
padding = 20
padded_logo = Image.new("RGBA", (logo.width + 2 * padding, logo.height + 2 * padding), (0, 0, 0, 255))
padded_logo.paste(logo, (padding, padding), logo)

# Save with padding
output_path = "assets/logo_padded.png"
padded_logo.save(output_path)
print(f"Saved padded logo to {output_path}")
