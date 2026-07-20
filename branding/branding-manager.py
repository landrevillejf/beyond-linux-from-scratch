#!/usr/bin/env python3
"""
Professional Branding Manager for BLFS
Loads branding configuration from TOML and manages all branding assets
"""

import sys
import json
import logging
from pathlib import Path
from typing import Dict, Any, Optional

try:
    import tomllib
except ImportError:
    import tomli as tomllib


class BrandingManager:
    """Manages BLFS branding configuration and assets"""

    def __init__(self, branding_dir: Path = None):
        self.logger = logging.getLogger(__name__)
        self.branding_dir = branding_dir or Path(__file__).parent
        self.config_file = self.branding_dir / "branding.toml"
        self.config: Dict[str, Any] = {}
        self.load_config()

    def load_config(self) -> None:
        """Load branding configuration from TOML"""
        if not self.config_file.exists():
            self.logger.error(f"Config not found: {self.config_file}")
            sys.exit(1)

        try:
            with open(self.config_file, "rb") as f:
                self.config = tomllib.load(f)
            self.logger.info(f"Loaded branding config: {self.config['brand']['name']}")
        except Exception as e:
            self.logger.error(f"Failed to load config: {e}")
            sys.exit(1)

    def get(self, key: str, default: Any = None) -> Any:
        """Get config value with dot notation"""
        keys = key.split(".")
        value = self.config
        for k in keys:
            if isinstance(value, dict):
                value = value.get(k)
            else:
                return default
        return value if value is not None else default

    def export_for_shell(self, output_file: Path = None) -> bool:
        """Export config as shell variables"""
        if not output_file:
            output_file = self.branding_dir / "branding.env"

        env_vars = {
            "BRANDING_NAME": self.get("brand.name"),
            "BRANDING_SHORT_NAME": self.get("brand.short_name"),
            "BRANDING_VERSION": self.get("brand.version"),
            "BRANDING_WEBSITE": self.get("brand.website"),
            "PRIMARY_COLOR_HEX": self.get("colors.primary.hex"),
            "PRIMARY_COLOR_RGB": ",".join(map(str, self.get("colors.primary.rgb"))),
            "SECONDARY_COLOR_HEX": self.get("colors.secondary.hex"),
            "DEFAULT_THEME": self.get("themes.default_theme"),
            "DEFAULT_WALLPAPER": self.get("wallpapers.default_wallpaper"),
            "GENERATE_WALLPAPERS": "true" if self.get("wallpapers.generate_on_build") else "false",
            "WALLPAPER_VARIANTS": str(self.get("wallpapers.variants")),
            "GTK_THEME_DARK": self.get("themes.dark.gtk_theme"),
            "GTK_THEME_LIGHT": self.get("themes.light.gtk_theme"),
            "ICON_THEME_DARK": self.get("themes.dark.icon_theme"),
            "ICON_THEME_LIGHT": self.get("themes.light.icon_theme"),
        }

        try:
            with open(output_file, "w") as f:
                f.write("#!/bin/bash\n")
                f.write("# Branding environment variables - auto-generated from branding.toml\n\n")
                for key, value in env_vars.items():
                    f.write(f"export {key}='{value}'\n")
            self.logger.info(f"Exported branding env to: {output_file}")
            return True
        except Exception as e:
            self.logger.error(f"Export failed: {e}")
            return False

    def export_for_json(self, output_file: Path = None) -> bool:
        """Export config as JSON"""
        if not output_file:
            output_file = self.branding_dir / "branding-manifest.json"

        manifest = {
            "brand": self.config.get("brand", {}),
            "colors": self.config.get("colors", {}),
            "wallpapers": {
                "default": self.get("wallpapers.default_wallpaper"),
                "dir": self.get("wallpapers.fallback_dir"),
                "generate_on_build": self.get("wallpapers.generate_on_build"),
            },
            "themes": self.config.get("themes", {}),
            "desktop_environments": self.config.get("desktop_environments", {}),
        }

        try:
            with open(output_file, "w") as f:
                json.dump(manifest, f, indent=2)
            self.logger.info(f"Exported branding manifest to: {output_file}")
            return True
        except Exception as e:
            self.logger.error(f"Export failed: {e}")
            return False

    def validate(self) -> bool:
        """Validate branding configuration"""
        self.logger.info("Validating branding configuration...")

        required_keys = [
            "brand.name",
            "brand.short_name",
            "colors.primary.hex",
            "wallpapers.default_wallpaper",
            "themes.default_theme",
        ]

        for key in required_keys:
            if not self.get(key):
                self.logger.error(f"Missing required key: {key}")
                return False

        # Check if color values are valid hex
        try:
            hex_color = self.get("colors.primary.hex")
            if not hex_color.startswith("#") or len(hex_color) != 7:
                raise ValueError(f"Invalid hex color: {hex_color}")
        except Exception as e:
            self.logger.error(f"Color validation failed: {e}")
            return False

        self.logger.info("Branding validation passed")
        return True

    def print_info(self) -> None:
        """Print branding information"""
        brand = self.config.get("brand", {})
        colors = self.config.get("colors", {})

        print("\n" + "=" * 60)
        print("BLFS BRANDING CONFIGURATION")
        print("=" * 60)
        print(f"\nBrand: {brand.get('name')} v{brand.get('version')}")
        print(f"Organization: {brand.get('organization')}")
        print(f"Website: {brand.get('website')}\n")

        print("Colors:")
        for name, color_info in colors.items():
            if isinstance(color_info, dict):
                hex_val = color_info.get("hex", "N/A")
                print(f"  {name:20} {hex_val}")

        print(f"\nDefault Theme: {self.get('themes.default_theme')}")
        print(f"Default Wallpaper: {self.get('wallpapers.default_wallpaper')}")
        print(f"Generate Wallpapers: {'Yes' if self.get('wallpapers.generate_on_build') else 'No'}")
        print("=" * 60 + "\n")


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s: %(message)s"
    )

    manager = BrandingManager()
    manager.print_info()

    if manager.validate():
        print("✓ Configuration is valid\n")
        manager.export_for_shell()
        manager.export_for_json()
    else:
        print("✗ Configuration validation failed")
        sys.exit(1)
