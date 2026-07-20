#!/usr/bin/env python3
"""
Generate branded images for GRUB boot menu and installer splash screen.
Creates gradient backgrounds with LFS branding - no external dependencies required.
Uses PPM format for maximum compatibility.
"""

import sys
import struct
from pathlib import Path


def hex_to_rgb(hex_color):
    """Convert hex color to RGB tuple."""
    hex_color = hex_color.lstrip('#')
    return tuple(int(hex_color[i:i+2], 16) for i in (0, 2, 4))


def create_gradient_ppm(width, height, rgb_top, rgb_bottom, output_path):
    """Create a gradient PPM image (no external dependencies)."""
    with open(output_path, 'wb') as f:
        # PPM header (P6 = binary RGB)
        header = f"P6\n{width} {height}\n255\n".encode('ascii')
        f.write(header)
        
        # Write gradient pixel data
        for y in range(height):
            ratio = y / height
            r = int(rgb_top[0] * (1 - ratio) + rgb_bottom[0] * ratio)
            g = int(rgb_top[1] * (1 - ratio) + rgb_bottom[1] * ratio)
            b = int(rgb_top[2] * (1 - ratio) + rgb_bottom[2] * ratio)
            
            # Write entire row with same color
            pixel = struct.pack('BBB', r, g, b)
            for _ in range(width):
                f.write(pixel)


def create_gradient_with_accent_ppm(width, height, rgb_top, rgb_bottom, 
                                    rgb_accent, accent_width, output_path):
    """Create a gradient PPM with accent stripes."""
    with open(output_path, 'wb') as f:
        # PPM header
        header = f"P6\n{width} {height}\n255\n".encode('ascii')
        f.write(header)
        
        # Write gradient with accent
        for y in range(height):
            ratio = y / height
            r = int(rgb_top[0] * (1 - ratio) + rgb_bottom[0] * ratio)
            g = int(rgb_top[1] * (1 - ratio) + rgb_bottom[1] * ratio)
            b = int(rgb_top[2] * (1 - ratio) + rgb_bottom[2] * ratio)
            
            for x in range(width):
                # Add accent on left edge
                if x < accent_width or y < accent_width:
                    pixel = struct.pack('BBB', rgb_accent[0], rgb_accent[1], rgb_accent[2])
                else:
                    pixel = struct.pack('BBB', r, g, b)
                f.write(pixel)


def convert_ppm_to_png(ppm_path):
    """Try to convert PPM to PNG using external tools."""
    import subprocess
    
    png_path = str(ppm_path).replace('.ppm', '.png')
    
    # Try ImageMagick
    try:
        subprocess.run(['convert', ppm_path, png_path], 
                      check=True, capture_output=True, timeout=5)
        return png_path
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        pass
    
    # Try Pillow if available
    try:
        from PIL import Image
        img = Image.open(ppm_path)
        img.save(png_path, 'PNG')
        return png_path
    except ImportError:
        pass
    
    # Return PPM path if conversion fails (GRUB can use PPM too)
    return ppm_path


def create_grub_background(output_path):
    """Create GRUB-specific background image (800x600 for maximum compatibility)."""
    # GRUB standard resolution for maximum compatibility
    width, height = 800, 600
    
    # Colors: dark green to very dark background
    rgb_top = hex_to_rgb('#236B43')     # Dark green
    rgb_bottom = hex_to_rgb('#0d0d14')  # Very dark background
    rgb_accent = hex_to_rgb('#3CB371')  # Light green
    
    ppm_path = str(output_path).replace('.png', '.ppm')
    create_gradient_with_accent_ppm(width, height, rgb_top, rgb_bottom, 
                                    rgb_accent, 4, ppm_path)
    
    final_path = convert_ppm_to_png(ppm_path)
    print(f"✓ Created GRUB background: {final_path}")
    
    return final_path


def create_installer_splash(output_path):
    """Create installer splash screen (1024x768)."""
    width, height = 1024, 768
    
    # Colors: forest green to very dark background
    rgb_top = hex_to_rgb('#2E8B57')     # Forest green
    rgb_bottom = hex_to_rgb('#0d0d14')  # Very dark background
    rgb_accent = hex_to_rgb('#3CB371')  # Light green
    
    ppm_path = str(output_path).replace('.png', '.ppm')
    create_gradient_with_accent_ppm(width, height, rgb_top, rgb_bottom, 
                                    rgb_accent, 6, ppm_path)
    
    final_path = convert_ppm_to_png(ppm_path)
    print(f"✓ Created installer splash: {final_path}")
    
    return final_path


def main():
    """Generate all installer branding images."""
    script_dir = Path(__file__).parent
    
    # Create directories
    bg_dir = script_dir / "backgrounds"
    logo_dir = script_dir / "logo"
    
    bg_dir.mkdir(parents=True, exist_ok=True)
    logo_dir.mkdir(parents=True, exist_ok=True)
    
    print("Generating installer branding images...")
    
    # Create GRUB background (use PPM and let conversion happen if available)
    grub_bg = bg_dir / "grub-background.png"
    create_grub_background(grub_bg)
    
    # Create installer splash
    splash = bg_dir / "installer-splash.png"
    create_installer_splash(splash)
    
    print("\n✓ All installer branding images generated successfully!")
    print(f"  Backgrounds: {bg_dir}")
    print(f"  Logos: {logo_dir}")
    print("\nNote: PPM format is used for maximum compatibility.")
    print("PNG conversion attempted if ImageMagick or Pillow available.")


if __name__ == "__main__":
    main()
