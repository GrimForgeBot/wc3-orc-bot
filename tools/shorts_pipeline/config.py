"""GrimForge Shorts Pipeline — central configuration.

All secrets come from environment variables — never hardcode keys.
Copy .env.example to .env and source it before running the pipeline.
"""
from __future__ import annotations
import os
from pathlib import Path

# ── Project paths ──────────────────────────────────────────────────────────────

PROJECT_ROOT  = Path(__file__).parent.parent.parent
RECORDINGS_DIR = PROJECT_ROOT / "recordings"
RECORDINGS_DIR.mkdir(exist_ok=True)

# ── OBS WebSocket ──────────────────────────────────────────────────────────────

OBS_HOST     = os.getenv("OBS_HOST", "localhost")
OBS_PORT     = int(os.getenv("OBS_PORT", "4455"))
OBS_PASSWORD = os.getenv("OBS_PASSWORD", "")          # set in OBS Tools > WebSocket Server Settings

# OBS scene names — configure these in OBS to match your layout
OBS_SCENE_GAMEPLAY = os.getenv("OBS_SCENE_GAMEPLAY", "WC3 Gameplay")

# ── API keys ───────────────────────────────────────────────────────────────────

ANTHROPIC_API_KEY  = os.getenv("ANTHROPIC_API_KEY", "")   # for script generation
ELEVENLABS_API_KEY = os.getenv("ELEVENLABS_API_KEY", "")   # optional; falls back to edge-tts
ELEVENLABS_VOICE_ID = os.getenv("ELEVENLABS_VOICE_ID", "")

# ── Voice settings ─────────────────────────────────────────────────────────────

EDGE_TTS_VOICE = "en-US-DavisNeural"   # cold, precise delivery
VOICE_RATE     = "-5%"                  # slight slow-down for clarity

# ── Video settings ─────────────────────────────────────────────────────────────

VIDEO_FPS        = 30
VIDEO_WIDTH      = 1080    # Shorts: 9:16
VIDEO_HEIGHT     = 1920
SOURCE_WIDTH     = 1920    # OBS capture resolution
SOURCE_HEIGHT    = 1080
MAX_SHORT_SECS   = 59      # YouTube Shorts ≤ 60s; leave 1s margin

# ── Thumbnail ──────────────────────────────────────────────────────────────────

THUMB_WIDTH  = 1280
THUMB_HEIGHT = 720
THUMB_FONT_SIZE  = 72
THUMB_COLOR_BG   = (26, 26, 26)         # charcoal
THUMB_COLOR_TEXT = (255, 107, 43)       # ember orange
THUMB_COLOR_SUB  = (77, 208, 225)       # cold blue

# ── YouTube ────────────────────────────────────────────────────────────────────

YT_CLIENT_SECRETS = PROJECT_ROOT / ".secrets" / "yt_client_secrets.json"
YT_TOKEN_FILE     = PROJECT_ROOT / ".secrets" / "yt_token.json"
YT_CATEGORY_GAMING = "20"
YT_DEFAULT_TAGS    = [
    "WC3", "Warcraft3", "WarcraftIII", "WC3Reforged",
    "AIBot", "GameDev", "PythonBot", "GrimForge",
    "Blademaster", "OrcBot", "GameAI",
]
YT_DEFAULT_PRIVACY  = "private"    # "private" → review before making public
