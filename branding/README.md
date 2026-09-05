# Branding — Remote Pi

Official visual identity assets. Source of truth: SVG vector files.

## Palette

| Color | Hex | Usage |
|---|---|---|
| Pure black | `#000000` | Background (full + adaptive icon bg) |
| Pure white | `#FFFFFF` | Pi symbol π (primary foreground) |
| Pi blue | `#4FC3F7` | Accent dot |

## Files

| File | Content | Recommended Usage |
|---|---|---|
| `logo-full.svg` | Black background + white π + blue dot | Single-piece logo (favicon, README header, site, screenshots) |
| `logo-foreground.svg` | π + dot on transparent background | iOS app icon (with separate bg), Android adaptive icon foreground |
| `logo-background.svg` | Solid black 1024×1024 | Android adaptive icon background layer |
| `logo-monochrome.svg` | Solid white silhouette | Android 13+ themed icon |
| `banner.svg` / `banner.png` | 1280×640 horizontal banner | Package cards, README hero, social preview |

All files: **1024×1024** viewBox, Android safe-zone compliant (~66% center).

## PNG Conversion

```bash
# Via rsvg-convert
rsvg-convert -w 1024 -h 1024 logo-foreground.svg -o logo-foreground.png
rsvg-convert -w 1024 -h 1024 logo-background.svg -o logo-background.png
rsvg-convert -w 1024 -h 1024 logo-monochrome.svg -o logo-monochrome.png
rsvg-convert -w 1024 -h 1024 logo-full.svg -o logo-full.png
```

## Standard Export Sizes

| Platform | Size | Source File |
|---|---|---|
| iOS App Icon | 1024×1024 PNG (no alpha) | `logo-full.svg` |
| Android Adaptive (foreground) | 432×432 PNG transparent | `logo-foreground.svg` |
| Android Adaptive (background) | 432×432 PNG solid | `logo-background.svg` |
| Android Themed (monochrome) | 432×432 PNG transparent | `logo-monochrome.svg` |
| Favicon | 32×32, 16×16 PNG | `logo-full.svg` |
| npm registry README | 512×512 PNG | `logo-full.svg` |
