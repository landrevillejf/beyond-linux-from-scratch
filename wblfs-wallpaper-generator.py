#!/usr/bin/env python3
"""
Générateur de fonds d'écran LFS – 15 variantes uniques, paramétrable et professionnel.
Utilise des coordonnées relatives pour s'adapter à n'importe quelle résolution.
"""

import os
import sys
import json
import random
import argparse
import logging
from PIL import Image, ImageDraw, ImageFont

# ====================== COULEURS DE BASE ======================
PRIMARY = (46, 139, 87)          # #2E8B57
PRIMARY_DARK = (35, 107, 67)     # #236B43
PRIMARY_LIGHT = (60, 179, 113)   # #3CB371
SECONDARY = (26, 26, 46)         # #1a1a2e
SECONDARY_LIGHT = (37, 37, 53)
ACCENT = (144, 238, 144)         # #90EE90
TEXT_COLOR = (240, 240, 240)     # #f0f0f0

# ====================== FONCTIONS DE DESSIN ======================
def draw_gradient(draw, colors, orientation, width, height):
    if orientation == "vertical":
        for y in range(height):
            ratio = y / height
            r = int(colors[0][0] + (colors[1][0] - colors[0][0]) * ratio)
            g = int(colors[0][1] + (colors[1][1] - colors[0][1]) * ratio)
            b = int(colors[0][2] + (colors[1][2] - colors[0][2]) * ratio)
            draw.line([(0, y), (width, y)], fill=(r, g, b))
    elif orientation == "horizontal":
        for x in range(width):
            ratio = x / width
            r = int(colors[0][0] + (colors[1][0] - colors[0][0]) * ratio)
            g = int(colors[0][1] + (colors[1][1] - colors[0][1]) * ratio)
            b = int(colors[0][2] + (colors[1][2] - colors[0][2]) * ratio)
            draw.line([(x, 0), (x, height)], fill=(r, g, b))
    else:  # diagonal
        for x in range(width):
            for y in range(height):
                ratio = (x + y) / (width + height)
                r = int(colors[0][0] + (colors[1][0] - colors[0][0]) * ratio)
                g = int(colors[0][1] + (colors[1][1] - colors[0][1]) * ratio)
                b = int(colors[0][2] + (colors[1][2] - colors[0][2]) * ratio)
                draw.point((x, y), fill=(r, g, b))

def draw_circles(draw, centers, radius, color, alpha_min=0.05, alpha_max=0.15):
    for cx, cy in centers:
        for r in range(radius, 0, -1):
            alpha = int(255 * (1 - r / radius) *
                        (alpha_min + random.random() * (alpha_max - alpha_min)))
            draw.ellipse([cx - r, cy - r, cx + r, cy + r],
                         fill=(*color, alpha))

def draw_triangles(draw, triangles):
    for points, fill, outline, width in triangles:
        draw.polygon(points, fill=fill, outline=outline, width=width)

def draw_text_with_glow(draw, text, pos, color, font, glow_color=PRIMARY, glow_steps=5):
    draw.text((pos[0] + 10, pos[1] + 10), text, font=font, fill=(0, 0, 0, 128))
    draw.text(pos, text, font=font, fill=color)
    for i in range(glow_steps):
        offset = i * 2
        alpha = max(0, 255 - i * 40)
        draw.text((pos[0] - offset, pos[1] - offset), text,
                  font=font, fill=(*glow_color, alpha))

def generate_decorative_dots(draw, count, width, height, color):
    for _ in range(count):
        x = random.randint(0, width)
        y = random.randint(0, height)
        radius = random.randint(1, 4)
        fill = color if random.random() > 0.7 else SECONDARY_LIGHT
        draw.ellipse([x - radius, y - radius, x + radius, y + radius],
                     fill=fill, outline=None)

def draw_extra_lines(draw, width, height):
    for x in range(0, width, 3):
        ratio = x / width
        r = int(PRIMARY[0] + (ACCENT[0] - PRIMARY[0]) * ratio)
        g = int(PRIMARY[1] + (ACCENT[1] - PRIMARY[1]) * ratio)
        b = int(PRIMARY[2] + (ACCENT[2] - PRIMARY[2]) * ratio)
        draw.line([(x, height * 0.85), (x + 2, height * 0.85 + 10)],
                  fill=(r, g, b), width=2)
    for x in range(width, 0, -2):
        ratio = x / width
        r = int(ACCENT[0] + (PRIMARY[0] - ACCENT[0]) * ratio)
        g = int(ACCENT[1] + (PRIMARY[1] - ACCENT[1]) * ratio)
        b = int(ACCENT[2] + (PRIMARY[2] - ACCENT[2]) * ratio)
        draw.line([(x, height * 0.9), (x - 2, height * 0.9 + 8)],
                  fill=(r, g, b), width=2)

# ====================== GÉNÉRATION DES CONFIGURATIONS RELATIVES ======================
def get_builtin_configs(width, height):
    """Retourne les 15 configurations, avec des coordonnées relatives adaptées à width et height."""
    # Fonction utilitaire pour convertir des coordonnées relatives (0..1) en pixels
    def rel(x, y):
        return (int(x * width), int(y * height))

    def rel_points(points):
        return [(int(x * width), int(y * height)) for x, y in points]

    # Les configurations utilisent désormais des flottants entre 0 et 1 pour toutes les positions
    configs = [
        # 1: Original
        {
            "gradient": ("vertical", (SECONDARY, SECONDARY_LIGHT)),
            "circles": [(0.75, 0.3), (0.2, 0.7)],
            "circle_radius": int(0.208 * width),  # ~400px sur 1920
            "circle_color": ACCENT,
            "triangles": [
                ([(0.052, 0.185), (0.156, 0.046), (0.208, 0.278)], PRIMARY_LIGHT, PRIMARY, 2),
                ([(1-0.104, 1-0.278), (1-0.052, 1-0.093), (1-0.208, 1-0.185)], (*PRIMARY, 80), PRIMARY, 2),
                ([(0.5-0.052, 0.093), (0.5+0.026, 0.185), (0.5-0.078, 0.231)], ACCENT, None, 0)
            ],
            "text": ("LFS", (0.5, 0.5-0.046), PRIMARY_LIGHT),
            "dots": 200,
            "dot_color": PRIMARY,
            "extra_lines": True
        },
        # 2: Horizontal gradient with primary circles
        {
            "gradient": ("horizontal", (SECONDARY, PRIMARY_DARK)),
            "circles": [(0.3, 0.3), (0.7, 0.7)],
            "circle_radius": int(0.156 * width),
            "circle_color": PRIMARY_LIGHT,
            "triangles": [
                ([(0.026, 0.046), (0.104, 0.046), (0.065, 0.278)], PRIMARY, ACCENT, 3),
                ([(1-0.026, 1-0.046), (1-0.104, 1-0.046), (1-0.065, 1-0.278)], (*ACCENT, 100), PRIMARY, 2),
                ([(0.5, 0.046), (0.5+0.052, 0.185), (0.5-0.052, 0.185)], PRIMARY_LIGHT, None, 0)
            ],
            "text": ("LFS", (0.5, 0.5+0.046), PRIMARY_LIGHT),
            "dots": 150,
            "dot_color": ACCENT,
            "extra_lines": False
        },
        # 3: Diagonal gradient with hexagon
        {
            "gradient": ("diagonal", (SECONDARY, PRIMARY)),
            "circles": [(0.5, 0.5)],
            "circle_radius": int(0.130 * width),
            "circle_color": PRIMARY_LIGHT,
            "triangles": [
                ([(0.052, 0.370), (0.156, 0.185), (0.260, 0.370)], PRIMARY_LIGHT, ACCENT, 2),
                ([(1-0.052, 1-0.370), (1-0.156, 1-0.185), (1-0.260, 1-0.370)], (*ACCENT, 80), PRIMARY, 2),
                ([(0.5, 0.093), (0.5+0.078, 0.185), (0.5+0.078, 0.324), (0.5, 0.417), (0.5-0.078, 0.324), (0.5-0.078, 0.185)], (*PRIMARY, 60), ACCENT, 2)
            ],
            "text": ("LFS", (0.5, 0.5-0.074), PRIMARY_LIGHT),
            "dots": 100,
            "dot_color": PRIMARY,
            "extra_lines": True
        },
        # 4: Minimalist dark
        {
            "gradient": ("vertical", (SECONDARY, (10,10,20))),
            "circles": [(0.8, 0.2)],
            "circle_radius": int(0.104 * width),
            "circle_color": PRIMARY,
            "triangles": [
                ([(0.104, 0.185), (0.208, 0.093), (0.260, 0.278)], PRIMARY_LIGHT, ACCENT, 3)
            ],
            "text": ("LFS", (0.5, 0.5-0.019), ACCENT),
            "dots": 250,
            "dot_color": ACCENT,
            "extra_lines": False
        },
        # 5: Warm gold
        {
            "gradient": ("vertical", (SECONDARY, (60, 40, 20))),
            "circles": [(0.2, 0.8), (0.6, 0.2)],
            "circle_radius": int(0.182 * width),
            "circle_color": (200, 180, 100),
            "triangles": [
                ([(0.026, 0.046), (0.078, 0.019), (0.104, 0.093)], (200, 180, 100), PRIMARY, 1),
                ([(1-0.026, 1-0.046), (1-0.078, 1-0.019), (1-0.104, 1-0.093)], (*PRIMARY, 80), ACCENT, 2)
            ],
            "text": ("LFS", (0.5, 0.5+0.028), (200, 180, 100)),
            "dots": 120,
            "dot_color": (200, 180, 100),
            "extra_lines": True
        },
        # 6: Dark blue with glowing green hex grid
        {
            "gradient": ("vertical", (SECONDARY, (0, 20, 40))),
            "circles": [(0.5, 0.5)],
            "circle_radius": int(0.078 * width),
            "circle_color": ACCENT,
            "triangles": [
                ([(0.5, 0.093), (0.5+0.104, 0.231), (0.5+0.104, 0.417), (0.5, 0.556), (0.5-0.104, 0.417), (0.5-0.104, 0.231)], (*ACCENT, 40), ACCENT, 2),
                ([(0.156, 0.185), (0.208, 0.139), (0.182, 0.278)], PRIMARY_LIGHT, PRIMARY, 1),
                ([(1-0.156, 0.185), (1-0.208, 0.139), (1-0.182, 0.278)], PRIMARY_LIGHT, PRIMARY, 1)
            ],
            "text": ("LFS", (0.5, 0.5), PRIMARY_LIGHT),
            "dots": 80,
            "dot_color": ACCENT,
            "extra_lines": False
        },
        # 7: Orange gradient with circular rings
        {
            "gradient": ("horizontal", ((80, 40, 20), (200, 120, 60))),
            "circles": [(0.2, 0.5), (0.8, 0.5)],
            "circle_radius": int(0.146 * width),
            "circle_color": (220, 180, 80),
            "triangles": [
                ([(0.052, 0.741), (0.156, 0.556), (0.260, 0.741)], PRIMARY_LIGHT, PRIMARY, 2),
                ([(1-0.052, 0.741), (1-0.156, 0.556), (1-0.260, 0.741)], PRIMARY_LIGHT, PRIMARY, 2)
            ],
            "text": ("LFS", (0.5, 0.5-0.028), TEXT_COLOR),
            "dots": 180,
            "dot_color": (220, 180, 80),
            "extra_lines": True
        },
        # 8: Purple and green with diamonds
        {
            "gradient": ("diagonal", ((60, 30, 80), (30, 100, 60))),
            "circles": [(0.3, 0.3), (0.7, 0.7)],
            "circle_radius": int(0.115 * width),
            "circle_color": (180, 120, 200),
            "triangles": [
                ([(0.5, 0.185), (0.5+0.078, 0.324), (0.5, 0.463), (0.5-0.078, 0.324)], (*PRIMARY, 70), PRIMARY, 2),
                ([(0.5-0.104, 0.185), (0.5-0.026, 0.324), (0.5-0.104, 0.463), (0.5-0.182, 0.324)], (*ACCENT, 50), ACCENT, 2),
                ([(0.5+0.104, 0.185), (0.5+0.182, 0.324), (0.5+0.104, 0.463), (0.5+0.026, 0.324)], (*ACCENT, 50), ACCENT, 2)
            ],
            "text": ("LFS", (0.5, 0.5+0.074), PRIMARY_LIGHT),
            "dots": 130,
            "dot_color": (180, 120, 200),
            "extra_lines": True
        },
        # 9: Minimalist with large glow
        {
            "gradient": ("vertical", (SECONDARY, SECONDARY_LIGHT)),
            "circles": [(0.5, 0.5)],
            "circle_radius": int(0.260 * width),
            "circle_color": PRIMARY,
            "triangles": [],
            "text": ("LFS", (0.5, 0.5), ACCENT),
            "dots": 0,
            "dot_color": PRIMARY,
            "extra_lines": False
        },
        # 10: Night sky with stars
        {
            "gradient": ("vertical", ((10, 10, 30), (0, 0, 10))),
            "circles": [],
            "circle_radius": 0,
            "circle_color": PRIMARY,
            "triangles": [],
            "text": ("LFS", (0.5, 0.5+0.093), ACCENT),
            "dots": 400,
            "dot_color": (255, 255, 255),
            "extra_lines": False
        },
        # 11: Abstract waves
        {
            "gradient": ("horizontal", (SECONDARY, PRIMARY_DARK)),
            "circles": [(0.2, 0.8), (0.8, 0.2)],
            "circle_radius": int(0.094 * width),
            "circle_color": PRIMARY_LIGHT,
            "triangles": [
                ([(0, 0.556), (0.104, 0.370), (0.208, 0.741)], PRIMARY, ACCENT, 2),
                ([(1-0, 0.556), (1-0.104, 0.370), (1-0.208, 0.741)], PRIMARY, ACCENT, 2),
                ([(0.104, 0.185), (0.208, 0.093), (0.313, 0.278)], (*ACCENT, 60), PRIMARY, 1),
                ([(1-0.104, 0.185), (1-0.208, 0.093), (1-0.313, 0.278)], (*ACCENT, 60), PRIMARY, 1)
            ],
            "text": ("LFS", (0.5, 0.5-0.037), ACCENT),
            "dots": 100,
            "dot_color": PRIMARY_LIGHT,
            "extra_lines": True
        },
        # 12: Neon green and black circuit
        {
            "gradient": ("vertical", ((0, 0, 0), (0, 20, 0))),
            "circles": [(0.25, 0.25), (0.75, 0.75)],
            "circle_radius": int(0.063 * width),
            "circle_color": (0, 255, 0),
            "triangles": [
                ([(0.052, 0.093), (0.104, 0.046), (0.130, 0.139)], (0, 255, 0), (0, 200, 0), 2),
                ([(1-0.052, 0.093), (1-0.104, 0.046), (1-0.130, 0.139)], (0, 255, 0), (0, 200, 0), 2),
                ([(0.052, 1-0.093), (0.104, 1-0.046), (0.130, 1-0.139)], (0, 255, 0), (0, 200, 0), 2),
                ([(1-0.052, 1-0.093), (1-0.104, 1-0.046), (1-0.130, 1-0.139)], (0, 255, 0), (0, 200, 0), 2)
            ],
            "text": ("LFS", (0.5, 0.5+0.056), (0, 255, 0)),
            "dots": 250,
            "dot_color": (0, 255, 0),
            "extra_lines": True
        },
        # 13: Pastel gradients with soft shapes
        {
            "gradient": ("horizontal", ((80, 60, 100), (60, 100, 80))),
            "circles": [(0.2, 0.3), (0.8, 0.6)],
            "circle_radius": int(0.104 * width),
            "circle_color": (180, 150, 200),
            "triangles": [
                ([(0.104, 0.185), (0.182, 0.093), (0.260, 0.231)], (200, 200, 220), (180, 150, 200), 2),
                ([(1-0.104, 0.185), (1-0.182, 0.093), (1-0.260, 0.231)], (200, 200, 220), (180, 150, 200), 2)
            ],
            "text": ("LFS", (0.5, 0.5-0.028), (220, 200, 240)),
            "dots": 150,
            "dot_color": (200, 200, 220),
            "extra_lines": True
        },
        # 14: Monochrome green with leaf shapes
        {
            "gradient": ("vertical", ((20, 50, 20), (10, 30, 10))),
            "circles": [(0.5, 0.5)],
            "circle_radius": int(0.156 * width),
            "circle_color": PRIMARY,
            "triangles": [
                ([(0.5, 0.093), (0.5+0.104, 0.185), (0.5+0.078, 0.324), (0.5, 0.370), (0.5-0.078, 0.324), (0.5-0.104, 0.185)], (*PRIMARY_LIGHT, 50), PRIMARY, 2),
                ([(0.156, 0.648), (0.234, 0.556), (0.286, 0.694), (0.234, 0.787)], (*ACCENT, 40), ACCENT, 1),
                ([(1-0.156, 0.648), (1-0.234, 0.556), (1-0.286, 0.694), (1-0.234, 0.787)], (*ACCENT, 40), ACCENT, 1)
            ],
            "text": ("LFS", (0.5, 0.5+0.093), ACCENT),
            "dots": 100,
            "dot_color": PRIMARY_LIGHT,
            "extra_lines": False
        },
        # 15: Bold primary geometric
        {
            "gradient": ("diagonal", (PRIMARY_DARK, PRIMARY_LIGHT)),
            "circles": [(0.3, 0.6), (0.7, 0.3)],
            "circle_radius": int(0.078 * width),
            "circle_color": ACCENT,
            "triangles": [
                ([(0.026, 0.046), (0.130, 0.046), (0.078, 0.231)], PRIMARY, ACCENT, 3),
                ([(1-0.026, 0.046), (1-0.130, 0.046), (1-0.078, 0.231)], PRIMARY, ACCENT, 3),
                ([(0.026, 1-0.046), (0.130, 1-0.046), (0.078, 1-0.231)], PRIMARY, ACCENT, 3),
                ([(1-0.026, 1-0.046), (1-0.130, 1-0.046), (1-0.078, 1-0.231)], PRIMARY, ACCENT, 3)
            ],
            "text": ("LFS", (0.5, 0.5-0.037), TEXT_COLOR),
            "dots": 80,
            "dot_color": PRIMARY_LIGHT,
            "extra_lines": True
        }
    ]

    # Convertir les coordonnées relatives en pixels pour chaque configuration
    for cfg in configs:
        # Cercles
        if cfg["circles"]:
            cfg["circles"] = [rel(x, y) for x, y in cfg["circles"]]
        # Triangles
        if cfg["triangles"]:
            new_triangles = []
            for tri in cfg["triangles"]:
                points, fill, outline, width_line = tri
                new_points = rel_points(points)
                new_triangles.append((new_points, fill, outline, width_line))
            cfg["triangles"] = new_triangles
        # Texte
        if cfg["text"]:
            text, pos, color = cfg["text"]
            cfg["text"] = (text, rel(pos[0], pos[1]), color)
        # Le rayon est déjà en pixels absolus (calculé)
        # Les autres champs sont déjà en pixels absolus (dots, etc.)

    return configs

# ====================== GÉNÉRATION D'UNE IMAGE ======================
def generate_wallpaper(config, width, height, font_path):
    img = Image.new('RGBA', (width, height), SECONDARY)
    draw = ImageDraw.Draw(img)

    # Dégradé
    grad_orient, grad_colors = config["gradient"]
    draw_gradient(draw, grad_colors, grad_orient, width, height)

    # Cercles
    if config.get("circles"):
        draw_circles(draw, config["circles"], config["circle_radius"],
                     config["circle_color"])

    # Triangles
    if config.get("triangles"):
        draw_triangles(draw, config["triangles"])

    # Texte
    text, pos, color = config["text"]
    try:
        font = ImageFont.truetype(font_path, int(0.094 * width))  # taille proportionnelle
    except:
        font = ImageFont.load_default()
        logging.warning("Police non trouvée, utilisation de la police par défaut.")

    draw_text_with_glow(draw, text, pos, color, font, glow_color=PRIMARY)

    # Points décoratifs
    if config.get("dots", 0) > 0:
        generate_decorative_dots(draw, config["dots"], width, height,
                                 config["dot_color"])

    # Lignes supplémentaires
    if config.get("extra_lines", False):
        draw_extra_lines(draw, width, height)

    return img

# ====================== PARSING ET MAIN ======================
def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Générateur de fonds d'écran LFS – 15 variantes, paramétrable"
    )
    parser.add_argument("-o", "--output-dir", default=".",
                        help="Dossier de sortie (défaut: courant)")
    parser.add_argument("--width", type=int, default=1920,
                        help="Largeur en pixels (défaut: 1920)")
    parser.add_argument("--height", type=int, default=1080,
                        help="Hauteur en pixels (défaut: 1080)")
    parser.add_argument("-f", "--format", choices=["png", "jpg", "jpeg"],
                        default="png", help="Format de sortie (défaut: png)")
    parser.add_argument("-q", "--quality", type=int, default=95,
                        help="Qualité JPEG (1-100, défaut: 95)")
    parser.add_argument("-n", "--count", type=int, default=15,
                        help="Nombre d'images à générer (max 15, défaut: 15)")
    parser.add_argument("--start-index", type=int, default=0,
                        help="Index de début (0-based, défaut: 0)")
    parser.add_argument("--font", default="/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
                        help="Chemin vers une police TrueType")
    parser.add_argument("--seed", type=int, default=None,
                        help="Graine aléatoire pour reproductibilité")
    parser.add_argument("--log-level", default="INFO",
                        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
                        help="Niveau de log (défaut: INFO)")
    return parser.parse_args()

def main():
    args = parse_arguments()

    logging.basicConfig(level=getattr(logging, args.log_level),
                        format="%(asctime)s - %(levelname)s - %(message)s")

    if args.seed is not None:
        random.seed(args.seed)
        logging.info(f"Graine aléatoire fixée à {args.seed}")

    # Générer les configurations adaptées à la résolution choisie
    configs = get_builtin_configs(args.width, args.height)

    total = len(configs)
    start = max(0, min(args.start_index, total - 1))
    end = min(total, start + args.count)
    selected = configs[start:end]
    logging.info(f"Génération de {len(selected)} image(s) (index {start} à {end-1})")

    os.makedirs(args.output_dir, exist_ok=True)

    for idx, cfg in enumerate(selected, start=start):
        logging.info(f"Génération de l'image {idx+1}/{total}...")
        img = generate_wallpaper(cfg, args.width, args.height, args.font)

        if args.format.lower() in ("jpg", "jpeg"):
            ext = "jpg"
            save_kwargs = {"quality": args.quality, "optimize": True}
        else:
            ext = "png"
            save_kwargs = {"compress_level": 6}

        filename = f"lfs-wallpaper-{idx+1}.{ext}" if idx > 0 else f"lfs-wallpaper.{ext}"
        filepath = os.path.join(args.output_dir, filename)
        img.save(filepath, **save_kwargs)
        logging.info(f"  -> {filepath}")

    logging.info("✅ Génération terminée.")

if __name__ == "__main__":
    main()