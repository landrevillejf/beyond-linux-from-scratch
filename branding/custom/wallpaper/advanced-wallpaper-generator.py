#!/usr/bin/env python3
"""
LFS Wallpaper Generator – Advanced Edition
Supports logo overlay (SVG/PNG), position, size, opacity, rotation.
"""

import os
import sys
import json
import random
import math
import argparse
import logging
import io
from typing import List, Tuple, Optional, Dict, Any
from pathlib import Path
from datetime import datetime

from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageColor, ImageOps

# Optional SVG support
try:
    import cairosvg
    HAS_CAIRO = True
except ImportError:
    HAS_CAIRO = False

# ============================================================================
# THEMES & COLOR UTILITIES
# ============================================================================
THEMES = {
    "default": {
        "primary": (46, 139, 87), "primary_dark": (35, 107, 67),
        "primary_light": (60, 179, 113), "secondary": (26, 26, 46),
        "secondary_light": (37, 37, 53), "accent": (144, 238, 144),
        "text": (240, 240, 240)
    },
    "dark": {
        "primary": (70, 130, 180), "primary_dark": (50, 90, 130),
        "primary_light": (100, 160, 210), "secondary": (10, 10, 20),
        "secondary_light": (20, 20, 35), "accent": (200, 200, 255),
        "text": (240, 240, 255)
    },
    "neon": {
        "primary": (0, 255, 0), "primary_dark": (0, 200, 0),
        "primary_light": (100, 255, 100), "secondary": (0, 0, 20),
        "secondary_light": (10, 10, 40), "accent": (255, 0, 255),
        "text": (0, 255, 255)
    },
    "nature": {
        "primary": (60, 120, 60), "primary_dark": (40, 90, 40),
        "primary_light": (90, 180, 90), "secondary": (30, 40, 20),
        "secondary_light": (50, 60, 30), "accent": (200, 180, 100),
        "text": (255, 240, 200)
    },
    "warm": {
        "primary": (200, 80, 40), "primary_dark": (150, 50, 20),
        "primary_light": (230, 140, 80), "secondary": (40, 20, 20),
        "secondary_light": (60, 30, 30), "accent": (255, 180, 100),
        "text": (255, 240, 220)
    },
    "cool": {
        "primary": (40, 80, 200), "primary_dark": (20, 50, 150),
        "primary_light": (80, 140, 230), "secondary": (20, 20, 40),
        "secondary_light": (30, 30, 60), "accent": (180, 200, 255),
        "text": (230, 240, 255)
    },
    "monochrome": {
        "primary": (180, 180, 180), "primary_dark": (100, 100, 100),
        "primary_light": (220, 220, 220), "secondary": (20, 20, 20),
        "secondary_light": (40, 40, 40), "accent": (240, 240, 240),
        "text": (255, 255, 255)
    }
}

def random_color():
    return (random.randint(0, 255), random.randint(0, 255), random.randint(0, 255))

def blend_colors(c1, c2, t):
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))

def parse_color(color, theme_colors=None):
    if color is None:
        return None
    if isinstance(color, (list, tuple)):
        if len(color) == 3:
            return tuple(color) + (255,)
        elif len(color) == 4:
            return tuple(color)
        return tuple(color)
    if isinstance(color, str):
        if theme_colors and color in theme_colors:
            c = theme_colors[color]
            return c if len(c) == 4 else (*c, 255)
        try:
            return ImageColor.getcolor(color, "RGBA")
        except ValueError:
            if color.startswith('#'):
                return tuple(int(color[i:i+2], 16) for i in (1,3,5)) + (255,)
            return (0,0,0,255)
    return (0,0,0,255)

# ============================================================================
# LOGO LOADING & OVERLAY
# ============================================================================
def load_logo_image(path, target_size=None, rotate=0, scale=1.0):
    if not os.path.exists(path):
        raise FileNotFoundError(f"Logo file not found: {path}")

    ext = os.path.splitext(path)[1].lower()
    if ext == '.svg':
        if not HAS_CAIRO:
            raise RuntimeError("cairosvg not installed. Please install it to use SVG logos: pip install cairosvg")
        png_data = cairosvg.svg2png(url=path)
        img = Image.open(io.BytesIO(png_data))
    else:
        img = Image.open(path)

    if img.mode != 'RGBA':
        img = img.convert('RGBA')

    if target_size is not None:
        img.thumbnail(target_size, Image.Resampling.LANCZOS)

    if rotate != 0:
        img = img.rotate(rotate, expand=True, resample=Image.Resampling.BICUBIC)

    if scale != 1.0:
        w, h = img.size
        new_w = int(w * scale)
        new_h = int(h * scale)
        img = img.resize((new_w, new_h), Image.Resampling.LANCZOS)

    return img

def apply_logo_to_image(base_img, logo_params, width, height):
    if not logo_params:
        return base_img

    path = logo_params.get('path')
    if not path:
        return base_img

    position = logo_params.get('position', 'center')
    size_rel = logo_params.get('size', 0.1)
    opacity = logo_params.get('opacity', 1.0)
    rotate = logo_params.get('rotate', 0)
    scale = logo_params.get('scale', 1.0)
    margin = logo_params.get('margin', 0.02)

    target_w = int(width * size_rel)
    target_h = int(target_w)

    logo = load_logo_image(path, target_size=(target_w, target_w), rotate=rotate, scale=scale)
    logo_w, logo_h = logo.size
    if logo_w > width or logo_h > height:
        ratio = min(width / logo_w, height / logo_h)
        new_w = int(logo_w * ratio)
        new_h = int(logo_h * ratio)
        logo = logo.resize((new_w, new_h), Image.Resampling.LANCZOS)
        logo_w, logo_h = logo.size

    x, y = 0, 0
    if isinstance(position, (list, tuple)) and len(position) == 2:
        x = int(position[0] * width - logo_w / 2)
        y = int(position[1] * height - logo_h / 2)
    elif isinstance(position, str):
        pos = position.lower()
        margin_px = int(min(width, height) * margin)
        if pos == 'center':
            x = (width - logo_w) // 2
            y = (height - logo_h) // 2
        elif pos == 'top-left':
            x = margin_px
            y = margin_px
        elif pos == 'top-right':
            x = width - logo_w - margin_px
            y = margin_px
        elif pos == 'bottom-left':
            x = margin_px
            y = height - logo_h - margin_px
        elif pos == 'bottom-right':
            x = width - logo_w - margin_px
            y = height - logo_h - margin_px
        else:
            try:
                parts = pos.split(',')
                if len(parts) == 2:
                    fx = float(parts[0].strip())
                    fy = float(parts[1].strip())
                    x = int(fx * width - logo_w / 2)
                    y = int(fy * height - logo_h / 2)
            except:
                pass

    if opacity < 1.0:
        alpha = logo.getchannel('A')
        alpha = alpha.point(lambda p: int(p * opacity))
        logo.putalpha(alpha)

    if base_img.mode != 'RGBA':
        base_img = base_img.convert('RGBA')
    base_img.paste(logo, (x, y), logo)
    return base_img

# ============================================================================
# DRAWING HELPERS (ALL ORIGINAL FUNCTIONS)
# ============================================================================
def generate_decorative_dots(draw, count, width, height, color):
    for _ in range(count):
        x = random.randint(0, width)
        y = random.randint(0, height)
        radius = random.randint(1, 4)
        if isinstance(color, tuple) and len(color) >= 3:
            alpha = random.randint(80, 200) if len(color) == 3 else color[3]
            fill = (*color[:3], alpha) if len(color) == 3 else color
        else:
            fill = color
        draw.ellipse([x - radius, y - radius, x + radius, y + radius],
                     fill=fill, outline=None)

def draw_gradient(img, colors, orientation='vertical'):
    width, height = img.size
    draw = ImageDraw.Draw(img)
    if len(colors) == 2:
        c1, c2 = colors
        if orientation == 'vertical':
            for y in range(height):
                t = y / height
                draw.line([(0, y), (width, y)], fill=blend_colors(c1, c2, t))
        elif orientation == 'horizontal':
            for x in range(width):
                t = x / width
                draw.line([(x, 0), (x, height)], fill=blend_colors(c1, c2, t))
        else:
            for x in range(width):
                for y in range(height):
                    t = (x + y) / (width + height)
                    draw.point((x, y), fill=blend_colors(c1, c2, t))
    else:
        stops = len(colors)
        if orientation == 'vertical':
            for y in range(height):
                pos = y / height
                seg = pos * (stops - 1)
                idx = int(seg)
                frac = seg - idx
                if idx >= stops - 1:
                    c = colors[-1]
                else:
                    c = blend_colors(colors[idx], colors[idx+1], frac)
                draw.line([(0, y), (width, y)], fill=c)
        elif orientation == 'horizontal':
            for x in range(width):
                pos = x / width
                seg = pos * (stops - 1)
                idx = int(seg)
                frac = seg - idx
                if idx >= stops - 1:
                    c = colors[-1]
                else:
                    c = blend_colors(colors[idx], colors[idx+1], frac)
                draw.line([(x, 0), (x, height)], fill=c)

def draw_circles(draw, centers, radius, color, alpha_min=0.05, alpha_max=0.15):
    for cx, cy in centers:
        for r in range(radius, 0, -1):
            alpha = int(255 * (1 - r / radius) * (alpha_min + random.random() * (alpha_max - alpha_min)))
            draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(*color[:3], alpha))

def draw_triangles(draw, triangles):
    for tri in triangles:
        if len(tri) < 4:
            continue
        points, fill, outline, width_line = tri[0], tri[1], tri[2], tri[3]
        draw.polygon(points, fill=fill, outline=outline, width=width_line)

def draw_grid(draw, width, height, spacing, color, thickness=1):
    for x in range(0, width, spacing):
        draw.line([(x, 0), (x, height)], fill=color, width=thickness)
    for y in range(0, height, spacing):
        draw.line([(0, y), (width, y)], fill=color, width=thickness)

def draw_checks(draw, width, height, size, color1, color2):
    for y in range(0, height, size):
        for x in range(0, width, size):
            if (x // size + y // size) % 2 == 0:
                draw.rectangle([x, y, x+size, y+size], fill=color1)
            else:
                draw.rectangle([x, y, x+size, y+size], fill=color2)

def draw_concentric_circles(draw, center, max_radius, count, color):
    for i in range(count):
        r = max_radius * (i / count)
        draw.ellipse([center[0]-r, center[1]-r, center[0]+r, center[1]+r], outline=color, width=1)

def draw_wave(draw, width, height, amplitude, frequency, color, phase=0, thickness=2):
    y0 = height // 2
    for x in range(width):
        y = y0 + amplitude * math.sin(2 * math.pi * x / frequency + phase)
        draw.line([(x, int(y)), (x, int(y)+thickness)], fill=color)

def draw_watermark(draw, text, width, height, font, color=(255,255,255,100)):
    draw.text((width - 150, height - 60), text, font=font, fill=color)

def draw_metadata(draw, text, width, height, font, color=(255,255,255,80)):
    draw.text((20, height - 30), text, font=font, fill=color)

def draw_extra_lines(draw, width, height, primary, accent):
    for x in range(0, width, 3):
        ratio = x / width
        r = int(primary[0] + (accent[0] - primary[0]) * ratio)
        g = int(primary[1] + (accent[1] - primary[1]) * ratio)
        b = int(primary[2] + (accent[2] - primary[2]) * ratio)
        draw.line([(x, height * 0.85), (x + 2, height * 0.85 + 10)],
                  fill=(r, g, b), width=2)
    for x in range(width, 0, -2):
        ratio = x / width
        r = int(accent[0] + (primary[0] - accent[0]) * ratio)
        g = int(accent[1] + (primary[1] - accent[1]) * ratio)
        b = int(accent[2] + (primary[2] - accent[2]) * ratio)
        draw.line([(x, height * 0.9), (x - 2, height * 0.9 + 8)],
                  fill=(r, g, b), width=2)

def draw_rounded_rect(draw, xy, radius, fill=None, outline=None, width=1):
    x1, y1, x2, y2 = xy
    if x1 > x2:
        x1, x2 = x2, x1
    if y1 > y2:
        y1, y2 = y2, y1
    if radius < 0: radius = 0
    if radius > (x2 - x1) // 2: radius = (x2 - x1) // 2
    if radius > (y2 - y1) // 2: radius = (y2 - y1) // 2
    draw.rectangle([x1+radius, y1, x2-radius, y2], fill=fill, outline=outline, width=width)
    draw.rectangle([x1, y1+radius, x2, y2-radius], fill=fill, outline=outline, width=width)
    draw.ellipse([x1, y1, x1+2*radius, y1+2*radius], fill=fill, outline=outline, width=width)
    draw.ellipse([x2-2*radius, y1, x2, y1+2*radius], fill=fill, outline=outline, width=width)
    draw.ellipse([x1, y2-2*radius, x1+2*radius, y2], fill=fill, outline=outline, width=width)
    draw.ellipse([x2-2*radius, y2-2*radius, x2, y2], fill=fill, outline=outline, width=width)

def draw_star(draw, center, radius, points=5, fill=None, outline=None, width=1):
    cx, cy = center
    angle = -math.pi / 2
    outer_radius = radius
    inner_radius = radius * 0.4
    pts = []
    for i in range(points * 2):
        r = outer_radius if i % 2 == 0 else inner_radius
        theta = angle + i * math.pi / points
        x = cx + r * math.cos(theta)
        y = cy + r * math.sin(theta)
        pts.append((x, y))
    draw.polygon(pts, fill=fill, outline=outline, width=width)

# ============================================================================
# CONFIGURATION GENERATOR
# ============================================================================
def generate_random_config(width, height, theme_colors):
    primary = theme_colors['primary']
    accent = theme_colors['accent']
    secondary = theme_colors['secondary']
    primary = tuple(max(0, min(255, c + random.randint(-30,30))) for c in primary)
    accent = tuple(max(0, min(255, c + random.randint(-30,30))) for c in accent)
    config = {
        "gradient": (random.choice(["vertical", "horizontal", "diagonal"]),
                     [primary, secondary]),
        "circles": [(random.random(), random.random()) for _ in range(random.randint(1, 3))],
        "circle_radius": random.uniform(0.05, 0.25),
        "circle_color": accent,
        "triangles": [],
        "text": ("", (0.5, 0.5), theme_colors['text']),
        "dots": random.randint(50, 300),
        "dot_color": accent,
        "extra_lines": random.choice([True, False])
    }
    for _ in range(random.randint(0, 2)):
        points = [(random.random(), random.random()) for _ in range(3)]
        fill = primary if random.random() > 0.5 else accent
        outline = primary if random.random() > 0.5 else accent
        config["triangles"].append((points, fill, outline, random.randint(1, 3)))
    if random.random() > 0.8:
        config["grid"] = (random.randint(30, 80), accent)
    if random.random() > 0.85:
        config["checks"] = (random.randint(30, 60), primary, accent)
    if random.random() > 0.75:
        config["concentric"] = ((0.5, 0.5), random.uniform(0.1, 0.4), random.randint(5,15), accent)
    if random.random() > 0.7:
        config["stars"] = [
            ((random.random(), random.random()), random.uniform(0.02, 0.06), random.randint(4, 6),
             primary if random.random()>0.5 else accent, None, 1)
        ]
    if random.random() > 0.7:
        x1 = random.uniform(0.1, 0.8)
        y1 = random.uniform(0.1, 0.8)
        x2 = x1 + random.uniform(0.05, 0.3)
        y2 = y1 + random.uniform(0.05, 0.3)
        x1 = max(0, min(1, x1))
        y1 = max(0, min(1, y1))
        x2 = max(0, min(1, x2))
        y2 = max(0, min(1, y2))
        config["rounded_rects"] = [
            ((x1, y1, x2, y2), random.randint(10, 30),
             primary if random.random()>0.5 else accent, None, 1)
        ]
    return config

# ============================================================================
# MAIN GENERATOR CLASS
# ============================================================================
class AdvancedWallpaperGenerator:
    def __init__(self, width=1920, height=1080, theme="default", seed=None):
        self.width = width
        self.height = height
        self.theme = theme
        self.theme_colors = THEMES.get(theme, THEMES["default"])
        if seed is not None:
            random.seed(seed)
        self._preload_fonts()

    def _preload_fonts(self):
        self.font_paths = [
            "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
            "/Library/Fonts/Arial Bold.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
            "C:/Windows/Fonts/Arialbd.ttf",
        ]

    def get_font(self, size):
        for path in self.font_paths:
            if os.path.exists(path):
                try:
                    return ImageFont.truetype(path, size)
                except:
                    continue
        return ImageFont.load_default()

    def generate_from_config(self, config: Dict[str, Any]) -> Image.Image:
        bg_color = self.theme_colors['secondary']
        img = Image.new('RGBA', (self.width, self.height), bg_color)
        draw = ImageDraw.Draw(img)

        # ---- Gradient ----
        if "gradient" in config:
            grad_orient, grad_colors = config["gradient"]
            parsed_grad = [parse_color(c, self.theme_colors) for c in grad_colors]
            draw_gradient(img, parsed_grad, grad_orient)

        # ---- Grid ----
        if config.get("grid"):
            spacing, color = config["grid"]
            color = parse_color(color, self.theme_colors)
            draw_grid(draw, self.width, self.height, spacing, color, thickness=1)

        # ---- Checks ----
        if config.get("checks"):
            size, c1, c2 = config["checks"]
            c1 = parse_color(c1, self.theme_colors)
            c2 = parse_color(c2, self.theme_colors)
            draw_checks(draw, self.width, self.height, size, c1, c2)

        # ---- Concentric circles ----
        if config.get("concentric"):
            center, radius, count, color = config["concentric"]
            cx, cy = int(center[0]*self.width), int(center[1]*self.height)
            max_r = int(radius * self.width)
            color = parse_color(color, self.theme_colors)
            draw_concentric_circles(draw, (cx, cy), max_r, count, color)

        # ---- Waves ----
        if config.get("waves"):
            for amplitude, frequency, color, phase in config["waves"]:
                color = parse_color(color, self.theme_colors)
                amp = int(amplitude * self.height)
                freq = int(frequency * self.width)
                draw_wave(draw, self.width, self.height, amp, freq, color, phase=phase, thickness=2)

        # ---- Circles ----
        if config.get("circles"):
            centers = [(int(x*self.width), int(y*self.height)) for x,y in config["circles"]]
            radius = int(config.get("circle_radius", 0.15) * self.width)
            color = parse_color(config.get("circle_color", self.theme_colors["primary"]), self.theme_colors)
            draw_circles(draw, centers, radius, color, alpha_min=0.05, alpha_max=0.15)

        # ---- Triangles ----
        if config.get("triangles"):
            triangles = []
            for tri in config["triangles"]:
                if len(tri) < 4:
                    continue
                points = tri[0]
                fill = tri[1] if len(tri) > 1 else None
                outline = tri[2] if len(tri) > 2 else None
                width_line = tri[3] if len(tri) > 3 else 1
                try:
                    points_abs = [(int(x*self.width), int(y*self.height)) for x,y in points]
                except:
                    continue
                fill = parse_color(fill, self.theme_colors) if fill else None
                outline = parse_color(outline, self.theme_colors) if outline else None
                triangles.append((points_abs, fill, outline, width_line))
            draw_triangles(draw, triangles)

        # ---- Rounded rectangles ----
        if config.get("rounded_rects"):
            for rect in config["rounded_rects"]:
                if len(rect) < 5:
                    continue
                xy, radius, fill, outline, width_line = rect[0], rect[1], rect[2], rect[3], rect[4]
                x1, y1, x2, y2 = xy
                if x1 > x2:
                    x1, x2 = x2, x1
                if y1 > y2:
                    y1, y2 = y2, y1
                x1, y1, x2, y2 = int(x1*self.width), int(y1*self.height), int(x2*self.width), int(y2*self.height)
                fill = parse_color(fill, self.theme_colors) if fill else None
                outline = parse_color(outline, self.theme_colors) if outline else None
                draw_rounded_rect(draw, (x1,y1,x2,y2), radius, fill=fill, outline=outline, width=width_line)

        # ---- Stars ----
        if config.get("stars"):
            for star in config["stars"]:
                if len(star) < 6:
                    continue
                center, radius, points, fill, outline, width_line = star[0], star[1], star[2], star[3], star[4], star[5]
                cx, cy = int(center[0]*self.width), int(center[1]*self.height)
                radius = int(radius * self.width)
                fill = parse_color(fill, self.theme_colors) if fill else None
                outline = parse_color(outline, self.theme_colors) if outline else None
                draw_star(draw, (cx, cy), radius, points, fill=fill, outline=outline, width=width_line)

        # ---- Text with shadow and glow ----
        if config.get("text"):
            text, pos, color = config["text"]
            if not text:
                text = ""
            color = parse_color(color, self.theme_colors)
            font_size = int(0.08 * self.width)
            font = self.get_font(font_size)
            pos = (int(pos[0]*self.width), int(pos[1]*self.height))

            if config.get("text_shadow", True):
                shadow_color = (0, 0, 0, 180)
                draw.text((pos[0]+5, pos[1]+5), text, font=font, fill=shadow_color)

            if config.get("text_glow", False):
                glow_color = self.theme_colors['accent']
                for i in range(1, 6):
                    alpha = max(0, 80 - i*15)
                    draw.text((pos[0]-i*2, pos[1]-i*2), text, font=font, fill=(*glow_color[:3], alpha))

            draw.text(pos, text, font=font, fill=color)

        # ---- Dots ----
        if config.get("dots", 0) > 0:
            dot_color = parse_color(config.get("dot_color", self.theme_colors["primary"]), self.theme_colors)
            generate_decorative_dots(draw, config["dots"], self.width, self.height, dot_color)

        # ---- Extra lines ----
        if config.get("extra_lines", False):
            draw_extra_lines(draw, self.width, self.height,
                             self.theme_colors["primary"], self.theme_colors["accent"])

        # ---- Watermark ----
        if config.get("watermark"):
            wm_font = self.get_font(int(0.025 * self.width))
            draw_watermark(draw, config["watermark"], self.width, self.height, wm_font)

        # ---- Metadata ----
        if config.get("metadata"):
            meta_font = self.get_font(int(0.02 * self.width))
            draw_metadata(draw, config["metadata"], self.width, self.height, meta_font)

        # ---- Logo overlay ----
        if config.get("logo"):
            img = apply_logo_to_image(img, config["logo"], self.width, self.height)

        # ---- Global effects ----
        if config.get("noise", 0) > 0:
            apply_noise(img, config["noise"])
        if config.get("blur", 0) > 0:
            img = img.filter(ImageFilter.GaussianBlur(config["blur"]))
        if config.get("glow", False):
            glow_color = parse_color(config.get("glow_color", (255,255,255,30)), self.theme_colors)
            img = apply_glow(img, glow_color, radius=10)

        return img

    def generate_random_wallpaper(self, count=1):
        wallpapers = []
        for i in range(count):
            config = generate_random_config(self.width, self.height, self.theme_colors)
            config["watermark"] = f"LFS {datetime.now().year}"
            wallpapers.append(self.generate_from_config(config))
        return wallpapers

# ============================================================================
# EFFECTS HELPERS
# ============================================================================
def apply_noise(img, intensity=0.05):
    pixels = img.load()
    width, height = img.size
    for x in range(width):
        for y in range(height):
            r, g, b, a = pixels[x, y]
            noise = random.randint(-int(255*intensity), int(255*intensity))
            r = max(0, min(255, r + noise))
            g = max(0, min(255, g + noise))
            b = max(0, min(255, b + noise))
            pixels[x, y] = (r, g, b, a)

def apply_glow(img, color=(255,255,255,50), radius=5):
    glow = Image.new('RGBA', img.size, (0,0,0,0))
    draw = ImageDraw.Draw(glow)
    draw.rectangle([(0,0), img.size], fill=color)
    glow = glow.filter(ImageFilter.GaussianBlur(radius))
    return Image.alpha_composite(img, glow)

# ============================================================================
# COMMAND LINE INTERFACE
# ============================================================================
def parse_arguments():
    parser = argparse.ArgumentParser(
        description="LFS Wallpaper Generator Pro – Create stunning wallpapers",
        epilog="Examples:\n"
               "  python advanced-wallpaper-generator.py --theme neon --random --count 10\n"
               "  python advanced-wallpaper-generator.py --width 2560 --height 1440 --theme nature\n"
               "  python advanced-wallpaper-generator.py --logo logo.svg --logo-position bottom-right --logo-size 0.12"
    )
    parser.add_argument("-o", "--output-dir", default="./wallpapers",
                        help="Parent output directory (a subfolder named after the theme will be created)")
    parser.add_argument("--width", type=int, default=1920, help="Width in pixels")
    parser.add_argument("--height", type=int, default=1080, help="Height in pixels")
    parser.add_argument("-f", "--format", choices=["png", "jpg", "jpeg"], default="png", help="Output format")
    parser.add_argument("-q", "--quality", type=int, default=95, help="JPEG quality (1-100)")
    parser.add_argument("-n", "--count", type=int, default=15, help="Number of images")
    parser.add_argument("--start-index", type=int, default=0, help="Start index for naming")
    parser.add_argument("--theme", choices=list(THEMES.keys()), default="default",
                        help="Color theme (used as subfolder name)")
    parser.add_argument("--random", action="store_true", help="Generate random designs")
    parser.add_argument("--config", "-c", type=str, help="JSON config file with list of designs")
    parser.add_argument("--seed", type=int, default=None, help="Random seed for reproducibility")
    parser.add_argument("--watermark", type=str, default="", help="Watermark text (overrides per-design)")
    parser.add_argument("--metadata", type=str, default="", help="Metadata text (overrides per-design)")
    parser.add_argument("--text", type=str, default="", help="Main text to display (overrides config text)")
    parser.add_argument("--blur", type=float, default=0.0, help="Apply Gaussian blur radius (global)")
    parser.add_argument("--noise", type=float, default=0.0, help="Apply noise intensity (0-1, global)")
    parser.add_argument("--glow", action="store_true", help="Apply glow effect (global)")

    # Logo options
    parser.add_argument("--logo", type=str, help="Path to logo image (SVG/PNG)")
    parser.add_argument("--logo-position", type=str, default="center",
                        help="Logo position: center, top-left, top-right, bottom-left, bottom-right, or X,Y (relative 0..1)")
    parser.add_argument("--logo-size", type=float, default=0.1,
                        help="Logo size relative to wallpaper width (0..1)")
    parser.add_argument("--logo-opacity", type=float, default=1.0,
                        help="Logo opacity (0..1)")
    parser.add_argument("--logo-rotate", type=float, default=0,
                        help="Logo rotation in degrees")
    parser.add_argument("--logo-scale", type=float, default=1.0,
                        help="Additional scale factor for the logo")
    parser.add_argument("--logo-margin", type=float, default=0.02,
                        help="Relative margin from edges for corner positions (0..1)")

    parser.add_argument("--log-level", default="INFO", choices=["DEBUG","INFO","WARNING","ERROR"])
    parser.add_argument("--version", action="version", version="LFS Wallpaper Generator v3.0")
    return parser.parse_args()

def main():
    args = parse_arguments()
    logging.basicConfig(level=getattr(logging, args.log_level),
                        format="%(asctime)s - %(levelname)s - %(message)s")

    if args.seed is not None:
        random.seed(args.seed)
        logging.info(f"Using seed: {args.seed}")

    # Determine designs
    if args.config:
        with open(args.config, 'r') as f:
            designs = json.load(f)
            if isinstance(designs, dict):
                designs = [designs]
    elif args.random:
        temp_gen = AdvancedWallpaperGenerator(args.width, args.height, args.theme, args.seed)
        designs = [generate_random_config(args.width, args.height, temp_gen.theme_colors)
                   for _ in range(args.count)]
    else:
        logging.warning("No config or random specified, generating random designs.")
        temp_gen = AdvancedWallpaperGenerator(args.width, args.height, args.theme, args.seed)
        designs = [generate_random_config(args.width, args.height, temp_gen.theme_colors)
                   for _ in range(args.count)]

    total = len(designs)
    start = max(0, min(args.start_index, total - 1))
    end = min(total, start + args.count)
    selected = designs[start:end]

    # Build logo parameters from CLI (if provided)
    logo_params = None
    if args.logo:
        logo_params = {
            "path": args.logo,
            "position": args.logo_position,
            "size": args.logo_size,
            "opacity": args.logo_opacity,
            "rotate": args.logo_rotate,
            "scale": args.logo_scale,
            "margin": args.logo_margin
        }

    for cfg in selected:
        # Override with CLI logo if provided
        if logo_params:
            cfg["logo"] = logo_params
        if args.watermark:
            cfg["watermark"] = args.watermark
        if args.metadata:
            cfg["metadata"] = args.metadata
        if args.text:
            if "text" in cfg and isinstance(cfg["text"], (list, tuple)) and len(cfg["text"]) >= 3:
                text_parts = list(cfg["text"])
                text_parts[0] = args.text
                cfg["text"] = tuple(text_parts)
            else:
                cfg["text"] = (args.text, (0.5, 0.5), THEMES.get(args.theme, THEMES["default"])["text"])
        if args.blur > 0:
            cfg["blur"] = args.blur
        if args.noise > 0:
            cfg["noise"] = args.noise
        if args.glow:
            cfg["glow"] = True

    output_dir = os.path.join(args.output_dir, args.theme)
    os.makedirs(output_dir, exist_ok=True)
    logging.info(f"Saving wallpapers to: {output_dir}")

    generator = AdvancedWallpaperGenerator(args.width, args.height, args.theme, args.seed)

    for idx, cfg in enumerate(selected, start=start):
        logging.info(f"Generating {idx+1}/{total}...")
        img = generator.generate_from_config(cfg)
        ext = "jpg" if args.format.lower() in ("jpg", "jpeg") else "png"
        fname = f"lfs-wallpaper-{idx+1:02d}.{ext}"
        outpath = os.path.join(output_dir, fname)
        if ext == "jpg":
            img = img.convert("RGB")
        save_kwargs = {"quality": args.quality, "optimize": True} if ext == "jpg" else {"compress_level": 6}
        img.save(outpath, **save_kwargs)
        logging.info(f"  -> {outpath}")

    logging.info(f"✅ Wallpaper generation complete. Files saved in {output_dir}")

if __name__ == "__main__":
    main()