import os
import sys
import base64
import subprocess
from PIL import Image

WORKSPACE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_PATH = os.path.join(WORKSPACE, "android", "fastlane", "metadata", "android", "en-US", "images", "icon.png")
OUT_PATH = os.path.join(WORKSPACE, "android", "fastlane", "metadata", "android", "en-US", "images", "featureGraphic.png")

with open(ICON_PATH, "rb") as f:
    icon_b64 = "data:image/png;base64," + base64.b64encode(f.read()).decode("utf-8")

html_content = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Figtree:wght@400;500;600;700;800;900&display=swap" rel="stylesheet">
<style>
  * {{
    box-sizing: border-box;
    margin: 0;
    padding: 0;
  }}
  body {{
    width: 1024px;
    height: 500px;
    overflow: hidden;
    background-color: #06070B;
    font-family: 'Figtree', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    color: #FFFFFF;
    position: relative;
    user-select: none;
    -webkit-font-smoothing: antialiased;
  }}

  /* Radial dot grid background */
  .grid {{
    position: absolute;
    inset: 0;
    background-image: radial-gradient(rgba(255, 255, 255, 0.08) 1px, transparent 1px);
    background-size: 24px 24px;
    background-position: -12px -12px;
    opacity: 0.35;
    mask-image: radial-gradient(circle at 60% 50%, black 20%, transparent 85%);
    -webkit-mask-image: radial-gradient(circle at 60% 50%, black 20%, transparent 85%);
  }}

  /* Soft ambient lighting */
  .glow-icon {{
    position: absolute;
    right: 40px;
    top: 50%;
    transform: translateY(-50%);
    width: 440px;
    height: 440px;
    background: radial-gradient(circle, rgba(120, 105, 255, 0.28) 0%, rgba(95, 75, 255, 0.12) 45%, transparent 70%);
    filter: blur(45px);
    pointer-events: none;
  }}

  .glow-beam {{
    position: absolute;
    top: -120px;
    left: 20%;
    width: 700px;
    height: 320px;
    background: radial-gradient(ellipse 50% 60% at 50% 30%, rgba(135, 125, 255, 0.16) 0%, transparent 70%);
    filter: blur(50px);
    pointer-events: none;
  }}

  /* Layout container */
  .container {{
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 84px;
  }}

  /* Left text side */
  .left-content {{
    max-width: 490px;
    display: flex;
    flex-direction: column;
    z-index: 2;
  }}

  .eyebrow {{
    font-size: 13px;
    font-weight: 700;
    letter-spacing: 2px;
    color: #9B8CFF;
    text-transform: uppercase;
    margin-bottom: 8px;
  }}

  .title {{
    font-size: 72px;
    font-weight: 800;
    line-height: 1.05;
    color: #FFFFFF;
    letter-spacing: -1.5px;
    margin-bottom: 12px;
  }}

  .subtitle {{
    font-size: 24px;
    font-weight: 600;
    color: #ECEFF8;
    letter-spacing: -0.3px;
    margin-bottom: 12px;
  }}

  .desc {{
    font-size: 14.5px;
    font-weight: 400;
    line-height: 1.55;
    color: #8E98AF;
    margin-bottom: 26px;
  }}

  /* Badges row */
  .badges-row {{
    display: flex;
    flex-wrap: wrap;
    gap: 9px;
  }}

  .badge {{
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.9px;
    color: #A6B0CA;
    background: rgba(255, 255, 255, 0.038);
    border: 1px solid rgba(255, 255, 255, 0.13);
    border-radius: 6px;
    padding: 6.5px 12px;
    text-transform: uppercase;
    backdrop-filter: blur(10px);
  }}

  /* Right icon side */
  .right-content {{
    position: relative;
    z-index: 2;
    display: flex;
    align-items: center;
    justify-content: center;
  }}

  .icon-wrapper {{
    width: 270px;
    height: 270px;
    border-radius: 62px;
    background: rgba(255, 255, 255, 0.05);
    box-shadow: 
      0 28px 75px -15px rgba(90, 75, 255, 0.48),
      0 12px 30px -8px rgba(0, 0, 0, 0.6),
      0 0 0 1px rgba(255, 255, 255, 0.15);
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
  }}

  .icon-img {{
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
    border-radius: 62px;
  }}
</style>
</head>
<body>
  <div class="grid"></div>
  <div class="glow-beam"></div>
  <div class="glow-icon"></div>

  <div class="container">
    <div class="left-content">
      <div class="eyebrow">VECVEL PRESENTS</div>
      <h1 class="title">Danaview</h1>
      <div class="subtitle">Pro HDR Media Player</div>
      <p class="desc">Universal hardware playback engine with 10-band equalizer, real-time stream diagnostics, and live frame color grading.</p>
      
      <div class="badges-row">
        <div class="badge">HDR PLAYBACK</div>
        <div class="badge">10-BAND EQ</div>
        <div class="badge">ZERO BUFFER</div>
        <div class="badge">PRIVACY FIRST</div>
      </div>
    </div>

    <div class="right-content">
      <div class="icon-wrapper">
        <img class="icon-img" src="{icon_b64}" alt="Danaview Icon">
      </div>
    </div>
  </div>
</body>
</html>
"""

html_path = "/tmp/feature_graphic.html"
with open(html_path, "w") as f:
    f.write(html_content)

chrome_cmd = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "--headless",
    "--disable-gpu",
    "--hide-scrollbars",
    "--window-size=1024,500",
    "--virtual-time-budget=3000",
    f"--screenshot={OUT_PATH}",
    html_path
]

print("Rendering feature graphic with Chrome headless...")
subprocess.run(chrome_cmd, check=True)

# Verify size with PIL
im = Image.open(OUT_PATH)
if im.size != (1024, 500):
    print(f"Resizing from {im.size} to (1024, 500)...")
    im = im.crop((0, 0, 1024, 500))
    im.save(OUT_PATH, "PNG", optimize=True)

print(f"Successfully generated: {OUT_PATH} (size: {im.size})")
