# LFS Wallpaper Generator – Usage Guide

The LFS Wallpaper Generator creates stunning wallpapers with themes, random designs, custom JSON configurations, and logo overlay support (SVG/PNG).

---

## 1. Install Dependencies

```bash
pip install Pillow
```

**Optional for SVG support:**
```bash
pip install cairosvg
```

---

## 2. Basic Commands

### Generate 15 random wallpapers (default theme)
```bash
python advanced-wallpaper-generator.py --random --count 15 --output-dir ./wallpapers
```

### Generate with a specific theme (neon, nature, dark, etc.)
```bash
python advanced-wallpaper-generator.py --theme neon --random --count 5
```

### Choose a custom resolution (e.g., 2560×1440)
```bash
python advanced-wallpaper-generator.py --width 2560 --height 1440 --theme nature --random --count 3
```

### Use a custom JSON configuration file
```bash
python advanced-wallpaper-generator.py --config my_designs.json --watermark "LFS v2.0"
```

### Add a watermark and metadata
```bash
python advanced-wallpaper-generator.py --random --watermark "LFS" --metadata "Build 2026-07-24" --output-dir ./out
```

### Apply effects (blur, noise, glow)
```bash
python advanced-wallpaper-generator.py --random --blur 2 --noise 0.05 --glow
```

### Reproduce the same series (fixed seed)
```bash
python advanced-wallpaper-generator.py --seed 42 --random --count 10
```

### Specify output format and JPEG quality
```bash
python advanced-wallpaper-generator.py --random --format jpg --quality 90
```

### Override main text
```bash
python advanced-wallpaper-generator.py --text "My LFS" --random --count 5
```

### Add a logo (SVG or PNG)
```bash
python advanced-wallpaper-generator.py --random --count 5 --logo logo.svg --logo-position bottom-right --logo-size 0.15 --logo-opacity 0.8
```

### Logo with rotation and scaling
```bash
python advanced-wallpaper-generator.py --config designs.json --logo logo.png --logo-position center --logo-rotate 15 --logo-scale 1.2
```

---

## 3. Main Options

| Option | Description |
|--------|-------------|
| `--theme` | Color theme: `default`, `dark`, `neon`, `nature`, `warm`, `cool`, `monochrome` |
| `--random` | Generate random patterns (otherwise uses built‑in designs or a JSON file) |
| `--count N` | Number of images to generate |
| `--width / --height` | Resolution in pixels |
| `--config file.json` | Load a custom design list (JSON format) |
| `--text "text"` | Main text to display (overrides config text) |
| `--watermark "text"` | Add text at the bottom‑right corner |
| `--metadata "text"` | Add text at the bottom‑left corner |
| `--seed N` | Fix random seed for reproducibility |
| `--blur R` | Apply Gaussian blur (radius in pixels) |
| `--noise 0..1` | Add noise (intensity) |
| `--glow` | Apply a global glow effect |
| `-o / --output-dir` | Output directory (default: `./wallpapers`) |
| `-f / --format` | `png` (default) or `jpg` |
| `-q / --quality` | JPEG quality (1‑100) |

### Logo Options

| Option | Description |
|--------|-------------|
| `--logo PATH` | Path to logo image (SVG or PNG) |
| `--logo-position POS` | Position: `center`, `top-left`, `top-right`, `bottom-left`, `bottom-right`, or `X,Y` (relative 0..1) |
| `--logo-size SIZE` | Size relative to wallpaper width (0..1) |
| `--logo-opacity OPACITY` | Opacity (0..1) |
| `--logo-rotate DEGREES` | Rotation in degrees |
| `--logo-scale SCALE` | Additional scale factor (1.0 = no extra scaling) |
| `--logo-margin MARGIN` | Relative margin from edges for corner positions (0..1) |

---

## 4. Example Custom JSON File (`my_designs.json`)

```json
[
  {
    "gradient": ["vertical", ["#2E8B57", "#1a1a2e"]],
    "circles": [[0.3, 0.4], [0.7, 0.6]],
    "circle_radius": 0.15,
    "circle_color": "#90EE90",
    "text": ["LFS", [0.5, 0.5], "#f0f0f0"],
    "dots": 150,
    "extra_lines": true
  },
  {
    "gradient": ["horizontal", ["#0a0a2e", "#3CB371"]],
    "circles": [[0.5, 0.5]],
    "circle_radius": 0.2,
    "circle_color": "#2E8B57",
    "text": ["LFS", [0.5, 0.5], "#ffffff"],
    "dots": 80,
    "grid": [60, "#90EE90"],
    "text_glow": true
  },
  {
    "gradient": ["diagonal", ["#1a0e0a", "#5C3D2E"]],
    "logo": {
      "path": "logo.svg",
      "position": "top-left",
      "size": 0.12,
      "opacity": 0.9,
      "rotate": -10,
      "scale": 1.0,
      "margin": 0.03
    }
  }
]
```

---

## 5. Design Fields (available per design)

- `gradient` : `["orientation", [color1, color2, ...]]` (orientation: `vertical`, `horizontal`, `diagonal`)
- `circles` : list of centers `[x, y]` (relative 0..1)
- `circle_radius` : radius relative to width
- `circle_color` : color (name, hex, or RGB tuple)
- `triangles` : list of `[points, fill, outline, width]` (points relative)
- `text` : `["text", [x, y], color]`
- `text_shadow` : `true`/`false` (shadow)
- `text_glow` : `true`/`false` (glow)
- `dots` : number of decorative dots
- `dot_color` : color of dots
- `extra_lines` : `true`/`false`
- `grid` : `[spacing, color]`
- `checks` : `[size, color1, color2]` (checkerboard)
- `concentric` : `[[cx, cy], max_radius, circle_count, color]`
- `waves` : `[[amplitude_relative, frequency_relative, color, phase]]`
- `stars` : `[[cx, cy], radius, points, fill, outline, width]`
- `rounded_rects` : `[[x1,y1,x2,y2], radius, fill, outline, width]`
- `logo` : object with `path`, `position`, `size`, `opacity`, `rotate`, `scale`, `margin`
- `noise`, `blur`, `glow` (global effects)
- `watermark`, `metadata` (texts)

---

## 6. Notes

- All shape coordinates are **relative** (0..1) to support any resolution.
- Colors can be specified as: theme names (e.g. `"primary"`), hex strings (`#RRGGBB`), or RGB tuples `[r,g,b]`.
- The generator uses `Pillow`. If a TrueType font is not found, a default fallback font will be used.
- **SVG support** requires `cairosvg` (install with `pip install cairosvg`). PNG/JPEG logos work without it.

---

## 7. Complete Examples

### Neon theme with logo, 4K, reproducible

```bash
python advanced-wallpaper-generator.py --text "LFS" --theme neon --random --count 20 --width 3840 --height 2160 --format png --quality 95 --watermark "LFS" --metadata "v3.0" --seed 123 --logo mon_logo.svg --logo-position bottom-right --logo-size 0.15 --logo-opacity 0.8 --logo-rotate 15 --logo-scale 1.2
```

### Dark theme with logo from a subfolder

```bash
python advanced-wallpaper-generator.py --text "LFS" --theme dark --random --count 20 --width 3840 --height 2160 --format png --quality 95 --watermark "LFS" --metadata "v3.0" --seed 123 --logo logo/logo.svg --logo-position bottom-right --logo-size 0.15 --logo-opacity 0.8 --logo-rotate 15 --logo-scale 1.2
```

### Custom config with watermark and metadata

```bash
python advanced-wallpaper-generator.py --config my_designs.json --output-dir ./custom --watermark "LFS 2026" --metadata "v3.0"
```

---