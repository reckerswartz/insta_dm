# Screenshot Capture Script

This unified script consolidates all screenshot capture functionality for the Instagram DM application.

## Usage

```bash
# Standard capture (default)
python3 capture_screenshots.py

# Portrait mode capture
python3 capture_screenshots.py --mode portrait

# Improved UI capture  
python3 capture_screenshots.py --mode improved

# With responsive screenshots
python3 capture_screenshots.py --responsive

# Custom output directory
python3 capture_screenshots.py --output-dir my_screenshots

# Don't cleanup old screenshots
python3 capture_screenshots.py --no-cleanup

# Different base URL
python3 capture_screenshots.py --base-url http://localhost:4000
```

## Modes

- **standard**: Regular screenshots in `screenshots/` directory
- **portrait**: Portrait orientation screenshots in `screenshots_portrait/` directory  
- **improved**: Enhanced UI screenshots in `screenshots_improved/` directory

## Features

- Captures all main application routes
- Attempts dynamic routes (account/profile pages)
- Optional responsive capture at multiple viewport sizes
- Automatic cleanup of old screenshots
- Server health check before capture
- Detailed progress reporting and file summaries
