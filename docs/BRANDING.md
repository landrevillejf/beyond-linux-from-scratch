# Beyond Linux From Scratch - Professional Branding System

**Version**: 0.4.5  
**Status**: Complete and Professional  
**Last Updated**: 2026-07-20

## 📋 Overview

The BLFS branding system is a comprehensive, professional visual identity system that extends throughout the entire build process, installer, and desktop environment.

### Key Features

✅ **Fully Configurable** - All branding settings in `branding/branding.toml`  
✅ **Dark Theme First** - Professional dark theme with light alternative  
✅ **Consistent Colors** - Forest green (#2E8B57) primary across all components  
✅ **Professional Typography** - Inter font for UI, Courier for code  
✅ **Auto-Generated Wallpapers** - 15 professional wallpaper variants  
✅ **Multi-Desktop Support** - XFCE, GNOME, KDE, LXQt, Phosh  
✅ **Theme Manager** - Central management via Python script  

---

## 🎨 Visual Identity

### Color Palette

| Color | Hex | RGB | Usage |
|-------|-----|-----|-------|
| **Primary** | #2E8B57 | 46, 139, 87 | Main actions, headers, highlights |
| **Primary Dark** | #236B43 | 35, 107, 67 | Hover states, dark backgrounds |
| **Primary Light** | #3CB371 | 60, 179, 113 | Active states, secondary highlights |
| **Secondary** | #1a1a2e | 26, 26, 46 | Main background |
| **Secondary Light** | #252535 | 37, 37, 53 | Component backgrounds |
| **Accent** | #90EE90 | 144, 238, 144 | Borders, active indicators |
| **Text Primary** | #f0f0f0 | 240, 240, 240 | Main text |
| **Text Secondary** | #cccccc | 204, 204, 204 | Secondary text |
| **Background** | #0d0d14 | 13, 13, 20 | System background |
| **Success** | #27AE60 | 39, 174, 96 | Positive feedback |
| **Warning** | #F39C12 | 243, 156, 18 | Warnings |
| **Error** | #E74C3C | 231, 76, 60 | Errors |

### Typography

```
Font Families:
  - Sans Serif: Inter, Helvetica, Arial
  - Monospace: JetBrains Mono, Courier New
  - Serif: Georgia (for documentation)

Font Sizes:
  - H1 (Titles):       42px | Weight: 700
  - H2 (Sections):     36px | Weight: 700
  - H3 (Subsections):  28px | Weight: 600
  - H4 (Labels):       24px | Weight: 600
  - Body (Text):       16px | Weight: 400
  - Small (Captions):  12px | Weight: 400
  - Mono (Code):       14px | Weight: 400
```

### Component Standards

**Buttons**
- Padding: 8px 16px
- Border-radius: 4px
- Border: 1px solid #3a3a4a (default)
- Hover: background changes to primary, border to primary light
- Active: background primary, border accent

**Input Fields**
- Background: #252535
- Border: 1px solid #3a3a4a
- Border-radius: 4px
- Focus: border color changes to accent
- Padding: 8px 12px

**Cards/Containers**
- Background: #1a1a2e or #252535
- Border: 1px solid #3a3a4a
- Border-radius: 6px
- Padding: 16-20px
- Shadow: 0 4px 12px rgba(0, 0, 0, 0.2)

**Alerts**
- Success: border-left 3px #27AE60, bg rgba(39, 174, 96, 0.1)
- Warning: border-left 3px #F39C12, bg rgba(243, 156, 18, 0.1)
- Error: border-left 3px #E74C3C, bg rgba(231, 76, 60, 0.1)

---

## 🖼️ Visual Elements

### 1. Splash Screen
Shown during system boot before login.

**Components:**
- Penguin logo (🐧)
- Title: "Beyond Linux From Scratch"
- Subtitle: "Building your custom Linux distribution"
- Animated progress bar
- Version number (v0.4.5)
- Duration: 3 seconds with fade in/out

**Design:**
- Background: Gradient from #0d0d14 to #1a1a2e
- Overlay: Radial gradient with primary color at center
- Smooth fade transitions
- Professional and clean

### 2. Boot Screen
Terminal-based boot messages.

**Style:**
- Monospace font (Courier New)
- Text color: #2E8B57 (primary green)
- Success messages: #27AE60
- Info messages: #3CB371
- Black background: #0d0d14

**Example Output:**
```
BLFS Kernel 6.10.0 #1 x86_64 GNU/Linux
[  OK  ] Started BLFS Build System.
[  OK  ] Started Network configuration.
[SUCCESS] System initialization (4.2s).
```

### 3. Installation Wizard
Professional multi-step installer with BLFS branding.

**Layout:**
- Left sidebar: Step indicators and navigation
- Main content: Current step details and options
- Background: Gradient dark theme
- Header: BLFS branding bar

**Steps:**
1. Welcome & License
2. Disk Configuration
3. **Profile Selection** (current)
4. Desktop Environment
5. Package Selection
6. Confirmation & Begin Build

**Styling:**
- Active step: #2E8B57 background
- Completed step: Checkmark (✓)
- Current step: Arrow (→)
- Future step: Bullet (•)

### 4. Desktop Environments

#### XFCE Dark Theme
- GTK Theme: LFS-Dark
- Icon Theme: Papirus-Dark
- Wallpaper: Professional BLFS-branded wallpaper
- Panel Color: #1a1a2e
- Text Color: #f0f0f0
- Accent: #2E8B57 for selection/hover

#### GNOME
- Shell Theme: LFS-Dark
- Icon Theme: Papirus-Dark
- GTK Theme: LFS-Dark
- Wallpaper: Auto-selected from branding assets
- Activities Overview: Dark background with green accents

#### KDE Plasma
- Plasma Theme: LFS-Dark
- Window Decoration: Breeze with green customization
- Icon Theme: Papirus-Dark
- Taskbar: Dark with green highlights
- Application Launcher: Green accents

#### LXQt
- Widget Style: Fusion
- Icon Theme: Papirus-Dark
- Theme: LFS-Dark
- Panel: Dark background with green accents
- Window Manager: Openbox

### 5. Wallpapers

**Generated Variants:** 15 professional wallpapers
- Resolutions: 1920x1080, 2560x1440, 3840x2160, 1366x768, 1024x768
- Styles: Minimal, Geometric, Gradient, Abstract, Modern
- Features:
  - BLFS logo overlay (optional)
  - Brand colors integrated throughout
  - Professional gradients and patterns
  - Text-free designs
  - High contrast and visibility

**Default Wallpaper:**
- Path: `branding/default/wallpaper/lfs-wallpaper.png`
- Resolution: 1920x1080
- Featuring: BLFS logo + professional gradient background
- License: Part of BLFS project

---

## 📁 Directory Structure

```
branding/
├── branding.toml                    # ← Central configuration file
├── branding-manager.py              # ← Configuration manager
├── branding.env                     # ← Generated shell variables
├── branding-manifest.json           # ← Generated JSON manifest
│
├── default/
│   ├── logo/
│   │   ├── logo.svg                 # Main logo
│   │   ├── icon.svg                 # Icon variant
│   │   ├── text-logo.svg            # Text-only logo
│   │   ├── horizontal-logo.svg      # Horizontal layout
│   │   └── vertical-logo.svg        # Vertical layout
│   │
│   ├── wallpaper/
│   │   ├── lfs-wallpaper.png        # Default wallpaper
│   │   ├── lfs-wallpaper-[1-15].png # 15 variants
│   │   └── lfs-wallpaper-with-logo.png
│   │
│   ├── themes/
│   │   ├── LFS-Dark/
│   │   │   ├── index.theme          # GTK theme metadata
│   │   │   ├── gtk-3.0/gtk.css      # GTK3 CSS
│   │   │   └── gtk-4.0/gtk.css      # GTK4 CSS
│   │   │
│   │   ├── LFS-Light/
│   │   │   ├── index.theme
│   │   │   ├── gtk-3.0/gtk.css
│   │   │   └── gtk-4.0/gtk.css
│   │   │
│   │   ├── gtk-3.20/gtk.css         # Base GTK3 CSS
│   │   ├── gtk-4.0/gtk.css          # Base GTK4 CSS
│   │   └── xfce.xml                 # XFCE theme config
│   │
│   ├── icons/
│   │   └── [icon sets]
│   │
│   └── fonts/
│       └── [custom fonts]
│
├── custom/
│   ├── wallpaper/
│   ├── themes/
│   └── logo/
│
└── installer/
    └── [installer branding]
```

---

## ⚙️ Configuration

### Main Configuration File: `branding.toml`

```toml
[brand]
name = "Beyond Linux From Scratch"
short_name = "BLFS"
version = "0.4.5"

[colors.primary]
hex = "#2E8B57"
rgb = [46, 139, 87]

[wallpapers]
generate_on_build = true
variants = 15

[desktop_environments.xfce]
theme = "LFS-Dark"
wallpaper = "branding/default/wallpaper/lfs-wallpaper.png"
```

### Using the Configuration

**Load in shell scripts:**
```bash
source branding/branding.env
echo "Primary color: $PRIMARY_COLOR_HEX"
```

**Load in Python:**
```python
from branding.branding_manager import BrandingManager

manager = BrandingManager()
colors = manager.get_colors()
print(manager.get("colors.primary.hex"))  # #2E8B57
```

---

## 🚀 Integration Points

### 1. Build System
- Configuration loaded during build initialization
- Wallpapers generated if configured (`LFS_CONFIG_BRANDING_GENERATE_WALLPAPERS=true`)
- Themes copied to final image
- Branding manifest written to `/etc/lfs-branding-manifest.txt`

### 2. Installation Process
- Splash screen shown during boot
- Installer wizard displays BLFS branding
- Desktop environments configured with BLFS theme
- Wallpapers installed to `/usr/share/backgrounds/lfs/`

### 3. Desktop Environment
- Themes applied on first login
- Wallpaper set automatically
- Panel colors matched to branding
- Window manager decorations styled

### 4. System Runtime
- Branding configuration loaded from `/etc/lfs-branding-manifest.txt`
- Users can override with custom themes
- System respects branding presets

---

## 📖 Usage Examples

### Generate Branding Configuration
```bash
cd branding/
python3 branding-manager.py
```

Output:
- `branding.env` - Shell variables
- `branding-manifest.json` - JSON manifest
- Console: Brand information and validation status

### Export Branding for Build
```bash
cd branding/
python3 branding-manager.py --export-shell
```

### Auto-Generate Wallpapers
```bash
python3 wblfs-wallpaper-generator.py \
    --output branding/default/wallpaper \
    --variants 15 \
    --include-logo \
    --include-branding
```

### Use Branding in Shell Scripts
```bash
#!/bin/bash
source branding/branding.env

echo "Building $BRANDING_NAME v$BRANDING_VERSION"
echo "Using primary color: $PRIMARY_COLOR_HEX"

# Apply theme
export GTK_THEME="$GTK_THEME_DARK"
export ICON_THEME="$ICON_THEME_DARK"
```

---

## 🎯 Implementation Status

| Component | Status | Details |
|-----------|--------|---------|
| Configuration | ✅ | `branding.toml` complete |
| Color System | ✅ | 12 colors defined |
| Typography | ✅ | Font families and sizes specified |
| Themes | ✅ | Dark/Light themes created |
| Wallpapers | ✅ | 15 variants generated |
| Manager Script | ✅ | Python manager implemented |
| Build Integration | ✅ | Integrated into `21-branding.sh` |
| Desktop Themes | ✅ | XFCE, GNOME, KDE, LXQt configured |
| Installer | ✅ | Branding applied to installer |
| Documentation | ✅ | This guide complete |

---

## 📱 Future Enhancements

- [ ] Dynamic theme generation based on primary color
- [ ] User theme editor GUI
- [ ] Mobile device support (Android, iOS)
- [ ] Web portal for BLFS
- [ ] CI/CD pipeline integration
- [ ] Automatic contrast validation
- [ ] Accessibility features (WCAG compliance)
- [ ] Multi-language support for UI strings

---

## 📞 Support & Customization

To customize branding:

1. Edit `branding/branding.toml`
2. Run `python3 branding/branding-manager.py` to validate
3. Regenerate wallpapers if colors changed
4. Rebuild system to apply changes

For custom logos or assets, add files to `branding/custom/` and update configuration.

---

## 📄 License

BLFS Branding System is part of the Linux From Scratch project.  
Licensed under: **GPL v2**

---

**Document Version**: 1.0  
**Last Updated**: 2026-07-20  
**Maintained by**: BLFS Project
