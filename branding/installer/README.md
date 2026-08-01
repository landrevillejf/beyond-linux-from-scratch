# Installer Branding System

This directory contains branding assets and configuration for the BLFS installer ISO.

## Structure

```
installer/
├── installer-branding.conf      # Branding configuration (colors, fonts, settings)
├── generate-installer-branding.py  # Script to generate images
├── backgrounds/                 # GRUB background and splash images
│   ├── grub-background.png     # GRUB menu background (800x600)
│   └── installer-splash.png    # Installer splash screen (1024x768)
└── logo/                        # Logo assets for installer
```

## Configuration

The `installer-branding.conf` file contains all branding settings:
- **Colors**: Primary, accent, text colors in hex format
- **ISO label**: Volume label displayed in file managers
- **GRUB settings**: Menu timeout, default selection, colors
- **Splash settings**: Boot splash theme configuration
- **Asset paths**: Where to find logo, backgrounds, and fonts

## Image Generation

### Option 1: During Build (Recommended)
Images are automatically generated during the LFS build process using `generate-installer-branding.py`. The script:
- Creates GRUB background (800x600 gradient with accent bar)
- Creates installer splash screen (1024x768 with branding)
- Supports custom colors from configuration
- Requires Python 3 with Pillow library

### Option 2: Pre-generate
```bash
cd branding/installer
python3 generate-installer-branding.py
```

Requires:
- Python 3.8+
- Pillow (PIL): `pip install Pillow`

## Installer Integration

The installer script (`final/14-create-installer.sh`) will:
1. Load this branding configuration
2. Ensure images exist (generate if needed)
3. Embed GRUB background in ISO
4. Configure GRUB menu with branding colors
5. Create branded ISO volume label
6. Set boot messages with branding

## Color Palette

The installer uses the professional BLFS color scheme:
- **Primary**: Forest Green (#2E8B57)
- **Primary Dark**: Dark Green (#236B43)
- **Primary Light**: Light Green (#3CB371)
- **Secondary**: Dark Blue (#1a1a2e)
- **Accent**: Light Green (#90EE90)
- **Text**: Light Gray (#f0f0f0)
- **Background**: Very Dark (#0d0d14)

## GRUB Customization

The GRUB menu is customized with:
- Branded background image
- Color-coded menu items (normal/highlight)
- Custom timeout (10 seconds default)
- LFS-branded boot options

```
Normal text: Light gray on black
Highlighted: Black on light green
```

## Boot Messages

During boot, the installer will display:
- Branded boot splash (if Plymouth is available)
- LFS Linux logo and version
- Custom boot messages
- Installation instructions

## Splash Screen

The installer splash screen shows:
- Title: "Beyond Linux From Scratch"
- Subtitle: "Professional Linux Distribution"
- Version: Read from VERSION file
- Accent stripe on left side
- Gradient background (green to dark)

## Testing

To test the branding:

1. **Generate images**:
   ```bash
   python3 generate-installer-branding.py
   ```

2. **Build ISO with branding**:
   ```bash
   ./final/14-create-installer.sh
   ```

3. **Boot the ISO**:
   - GRUB menu should show branded background and colors
   - Splash screen should appear with LFS branding
   - Boot messages should reference LFS Linux

4. **Verify in running system**:
   ```bash
   # Check branding manifest
   cat /etc/lfs-branding-manifest.txt
   
   # Verify configuration was applied
   source /etc/lfs-branding.conf
   ```

## Customization

To customize installer branding:

1. **Edit colors**: Modify hex values in `installer-branding.conf`
2. **Change fonts**: Update font paths in configuration
3. **Custom logo**: Place logo image in `logo/` directory
4. **Custom backgrounds**: Generate or place PNG images in `backgrounds/`

## Technical Details

### Image Formats
- **GRUB background**: PNG, recommended 800x600 (BIOS boot compatibility)
- **Splash screen**: PNG, recommended 1024x768
- **Logo**: PNG with transparency, recommended 512x512

### Build Dependencies
The installer script automatically:
1. Checks for image files
2. Generates them if missing using `generate-installer-branding.py`
3. Embeds them in the ISO
4. Configures GRUB to use the background

### Integration with Final System

The installer branding is separate from the final system branding:
- **Installer** (`branding/installer/`): Used during boot and installation
- **Live System** (`branding/default/`): Applied after boot/installation
- **System** (`blfs/21-branding.sh`): Applied during LFS build

## Future Enhancements

- [ ] Plymouth boot animation
- [ ] Animated GRUB menu background
- [ ] Localized boot messages (French, English, Spanish)
- [ ] Theme selector in installer UI
- [ ] Custom splash screen per profile (XFCE, GNOME, KDE, LXQt)
