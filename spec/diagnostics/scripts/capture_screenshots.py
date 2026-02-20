#!/usr/bin/env python3
"""
Unified screenshot capture script for the Instagram DM application.
Consolidates all capture functionality with flexible options for different capture modes.
"""

import os
import time
import requests
import shutil
import argparse
from datetime import datetime
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

class UnifiedScreenshotCapture:
    def __init__(self, base_url="http://localhost:3000", mode="standard", output_dir=None):
        self.base_url = base_url
        self.mode = mode
        self.output_dir = output_dir or self.get_default_output_dir()
        self.driver = None
        self.captured_screenshots = []
        
        # Create output directory
        os.makedirs(self.output_dir, exist_ok=True)
        
        # Define all routes to capture
        self.routes = [
            # Main pages
            {"path": "/", "name": "home", "description": "Home page"},
            {"path": "/up", "name": "health_check", "description": "Health check"},
            
            # Instagram accounts
            {"path": "/instagram_accounts", "name": "accounts_index", "description": "Instagram accounts index"},
            {"path": "/instagram_accounts/new", "name": "accounts_new", "description": "New Instagram account"},
            
            # Instagram profiles  
            {"path": "/instagram_profiles", "name": "profiles_index", "description": "Instagram profiles index"},
            
            # Instagram posts
            {"path": "/instagram_posts", "name": "posts_index", "description": "Instagram posts index"},
            
            # Admin section
            {"path": "/admin/background_jobs", "name": "admin_background_jobs", "description": "Admin background jobs"},
            {"path": "/admin/background_jobs/failures", "name": "admin_job_failures", "description": "Admin job failures"},
            {"path": "/admin/ai_providers", "name": "admin_ai_providers", "description": "Admin AI providers"},
            {"path": "/admin/jobs", "name": "admin_mission_control", "description": "Mission control jobs"},
            
            # Dashboard
            {"path": "/dashboard", "name": "dashboard", "description": "Dashboard"},
            
            # AI Dashboard
            {"path": "/ai_dashboard", "name": "ai_dashboard", "description": "AI Dashboard"},
        ]
        
        # Dynamic routes that might require existing records
        self.dynamic_routes = [
            {"path": "/instagram_accounts/2", "name": "account_show_2", "description": "Account show (ID: 2)"},
            {"path": "/instagram_accounts/2/technical_details", "name": "account_technical_2", "description": "Account technical details (ID: 2)"},
            {"path": "/instagram_accounts/2/story_media_archive", "name": "account_story_archive_2", "description": "Account story archive (ID: 2)"},
            {"path": "/instagram_profiles/1", "name": "profile_show_1", "description": "Profile show (ID: 1)"},
            {"path": "/instagram_profiles/1/events", "name": "profile_events_1", "description": "Profile events (ID: 1)"},
            {"path": "/instagram_posts/1", "name": "post_show_1", "description": "Post show (ID: 1)"},
        ]

    def get_default_output_dir(self):
        """Get default output directory based on mode"""
        if self.mode == "portrait":
            return "screenshots_portrait"
        elif self.mode == "improved":
            return "screenshots_improved"
        else:
            return "screenshots"

    def cleanup_old_screenshots(self):
        """Remove old screenshot directories to ensure fresh data"""
        if self.mode == "portrait":
            directories = ['screenshots', 'screenshots_improved', 'screenshots_portrait']
        elif self.mode == "improved":
            directories = ['screenshots_improved']
        else:
            directories = ['screenshots']
        
        for directory in directories:
            if os.path.exists(directory) and directory != self.output_dir:
                print(f"Cleaning up old directory: {directory}")
                shutil.rmtree(directory)
        
        print("✅ Cleanup completed")

    def setup_driver(self):
        """Setup Chrome WebDriver with mode-specific options"""
        chrome_options = Options()
        chrome_options.add_argument('--headless')
        chrome_options.add_argument('--no-sandbox')
        chrome_options.add_argument('--disable-dev-shm-usage')
        chrome_options.add_argument('--disable-gpu')
        
        # Mode-specific configurations
        if self.mode == "portrait":
            chrome_options.add_argument('--remote-debugging-port=9224')
            chrome_options.add_argument('--window-size=2160,3840')  # Portrait 4K
            chrome_options.add_argument('--force-device-scale-factor=1')
            # Font and emoji support for WSL Linux
            chrome_options.add_argument('--font-render-hinting=none')
            chrome_options.add_argument('--disable-font-subpixel-positioning')
            chrome_options.add_argument('--enable-features=VaapiVideoDecoder')
            chrome_options.add_argument('--disable-features=UseChromeOSDirectVideoDecoder')
        elif self.mode == "improved":
            chrome_options.add_argument('--remote-debugging-port=9223')
            chrome_options.add_argument('--window-size=1920,1080')
        else:
            chrome_options.add_argument('--remote-debugging-port=9222')
            chrome_options.add_argument('--window-size=1920,1080')
        
        try:
            driver = webdriver.Chrome(options=chrome_options)
            self.driver = driver
            print(f"✅ Chrome WebDriver setup complete ({self.mode} mode)")
            return driver
        except Exception as e:
            print(f"❌ Failed to initialize Chrome driver: {e}")
            return None

    def capture_full_page_screenshot(self, url, filename, scroll=True):
        """Capture full page screenshot with proper scrolling"""
        print(f"Capturing: {url}")
        try:
            self.driver.get(url)
            
            # Wait times based on mode
            wait_time = 5 if self.mode == "portrait" else 3
            time.sleep(wait_time)
            
            # Wait for key elements to be present
            try:
                WebDriverWait(self.driver, 10).until(
                    EC.presence_of_element_located((By.TAG_NAME, "body"))
                )
            except:
                pass  # Continue even if wait times out
            
            if scroll:
                if self.mode == "portrait":
                    # Enhanced scrolling for portrait mode
                    total_height = self.driver.execute_script("return document.body.scrollHeight")
                    viewport_height = self.driver.execute_script("return window.innerHeight")
                    
                    print(f"  Page height: {total_height}px, Viewport: {viewport_height}px")
                    
                    # Scroll in chunks to capture everything
                    current_position = 0
                    scroll_chunk = viewport_height - 100  # Leave some overlap
                    
                    while current_position < total_height:
                        self.driver.execute_script(f"window.scrollTo(0, {current_position});")
                        time.sleep(1)
                        current_position += scroll_chunk
                    
                    # Scroll back to top for final screenshot
                    self.driver.execute_script("window.scrollTo(0, 0);")
                    time.sleep(2)
                else:
                    # Standard scrolling for other modes
                    self.driver.execute_script("window.scrollTo(0, document.body.scrollHeight);")
                    time.sleep(2)
                    self.driver.execute_script("window.scrollTo(0, 0);")
                    time.sleep(1)
            
            # Save screenshot
            filepath = os.path.join(self.output_dir, f"{filename}.png")
            self.driver.save_screenshot(filepath)
            
            # Store screenshot info
            screenshot_info = {
                "filename": f"{filename}.png",
                "url": url,
                "timestamp": datetime.now().isoformat(),
                "mode": self.mode
            }
            self.captured_screenshots.append(screenshot_info)
            
            print(f"✅ Saved: {filename}.png")
            return True
            
        except Exception as e:
            print(f"❌ Failed to capture {url}: {e}")
            return False

    def capture_responsive_screenshots(self, url, base_name):
        """Capture screenshots at different viewport sizes"""
        widths = [1920, 1366, 768, 375]  # Desktop, tablet, mobile
        
        for width in widths:
            self.driver.set_window_size(width, 1080)
            filename = f"{base_name}_{width}px"
            self.capture_full_page_screenshot(url, filename, scroll=True)
            time.sleep(1)

    def check_server(self):
        """Check if the server is running"""
        try:
            response = requests.get(f'{self.base_url}/up', timeout=5)
            if response.status_code != 200:
                print("❌ Server is not responding correctly")
                return False
            return True
        except requests.RequestException:
            print(f"❌ Cannot connect to server at {self.base_url}")
            return False

    def capture_all_screenshots(self, include_responsive=False, cleanup=True):
        """Capture screenshots for all defined routes"""
        print(f"🚀 Starting {self.mode} screenshot capture...")
        print("=" * 60)
        
        # Check server
        if not self.check_server():
            return
        
        # Cleanup old screenshots if requested
        if cleanup:
            self.cleanup_old_screenshots()
        
        # Setup driver
        driver = self.setup_driver()
        if not driver:
            print("❌ Failed to setup WebDriver")
            return
        
        # Set initial window size
        if self.mode == "portrait":
            driver.set_window_size(2160, 3840)
        else:
            driver.set_window_size(1920, 1080)
        
        # Capture main URLs
        captured_count = 0
        total_count = len(self.routes) + len(self.dynamic_routes)
        
        print(f"\n📸 Capturing {len(self.routes)} main pages...")
        for route in self.routes:
            name = route["name"]
            url = f"{self.base_url}{route['path']}"
            
            if self.capture_full_page_screenshot(url, name):
                captured_count += 1
            time.sleep(3 if self.mode == "portrait" else 2)
        
        # Try dynamic URLs (might fail if records don't exist)
        print(f"\n🔍 Attempting {len(self.dynamic_routes)} dynamic pages...")
        for route in self.dynamic_routes:
            name = route["name"]
            url = f"{self.base_url}{route['path']}"
            
            if self.capture_full_page_screenshot(url, name):
                captured_count += 1
            time.sleep(2)
        
        # Capture responsive versions if requested
        if include_responsive and self.mode != "portrait":
            key_pages = [
                f"{self.base_url}/",
                f"{self.base_url}/instagram_accounts",
                f"{self.base_url}/instagram_profiles"
            ]
            
            print("\n📱 Capturing responsive versions of key pages...")
            for url in key_pages:
                name = url.replace(f"{self.base_url}/", "").replace("/", "_")
                name = 'home' if name == '' else name
                name = name.replace('__', '_')
                
                self.capture_responsive_screenshots(url, name)
        
        # Close driver
        driver.quit()
        
        # Print summary
        print("=" * 60)
        print(f"✅ {self.mode.capitalize()} screenshot capture complete!")
        print(f"📊 Total pages attempted: {total_count}")
        print(f"✅ Successfully captured: {captured_count}")
        print(f"📁 Screenshots saved in: {self.output_dir}/")
        
        # List captured files
        try:
            screenshots = [f for f in os.listdir(self.output_dir) if f.endswith('.png')]
            screenshots.sort()
            print(f"\n📋 Captured files ({len(screenshots)}):")
            for screenshot in screenshots:
                size = os.path.getsize(os.path.join(self.output_dir, screenshot))
                size_mb = size / (1024 * 1024)
                print(f"  📄 {screenshot} ({size_mb:.1f} MB)")
        except Exception as e:
            print(f"Could not list screenshots: {e}")

def main():
    """Main function with command line arguments"""
    parser = argparse.ArgumentParser(description="Unified screenshot capture for Instagram DM app")
    parser.add_argument("--mode", choices=["standard", "portrait", "improved"], 
                       default="standard", help="Capture mode (default: standard)")
    parser.add_argument("--base-url", default="http://localhost:3000", 
                       help="Base URL of the application (default: http://localhost:3000)")
    parser.add_argument("--output-dir", help="Output directory (auto-generated based on mode)")
    parser.add_argument("--no-cleanup", action="store_true", 
                       help="Don't cleanup old screenshots")
    parser.add_argument("--responsive", action="store_true", 
                       help="Capture responsive versions (not available in portrait mode)")
    
    args = parser.parse_args()
    
    # Create capturer and run
    capturer = UnifiedScreenshotCapture(
        base_url=args.base_url,
        mode=args.mode,
        output_dir=args.output_dir
    )
    
    capturer.capture_all_screenshots(
        include_responsive=args.responsive,
        cleanup=not args.no_cleanup
    )

if __name__ == "__main__":
    main()
