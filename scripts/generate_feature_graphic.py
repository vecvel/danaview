#!/usr/bin/env python3
"""Regenerates the Google Play feature graphic.

The feature graphic is now part of the brand generator (6B mark, outlined Figtree text, no
network or headless browser). Its SVG source is assets/branding/store/feature_graphic.svg.
This wrapper is kept so old instructions still work; it runs:

    python3 assets/branding/generate_brand.py store
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.exit(subprocess.call([sys.executable, os.path.join(ROOT, "assets", "branding", "generate_brand.py"), "store"]))
