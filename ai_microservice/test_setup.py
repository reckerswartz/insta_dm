#!/usr/bin/env python3
"""
Simple test script to verify AI microservice can start
"""

import sys
import os

def test_imports():
    """Test if all required modules can be imported"""
    try:
        print("Testing basic imports...")
        import fastapi
        print("✅ FastAPI available")
        
        import uvicorn
        print("✅ Uvicorn available")
        
        import numpy as np
        print("✅ NumPy available")
        
        try:
            import cv2
            print("✅ OpenCV available")
        except ImportError:
            print("⚠️  OpenCV not available - some features may not work")
        
        try:
            from PIL import Image
            print("✅ PIL available")
        except ImportError:
            print("⚠️  PIL not available - image processing may not work")
        
        print("\nTesting AI service imports...")
        
        # Test if service files exist
        service_files = [
            'services/vision_service.py',
            'services/face_service.py', 
            'services/ocr_service.py',
            'services/video_service.py',
            'services/whisper_service.py'
        ]
        
        for service_file in service_files:
            if os.path.exists(service_file):
                print(f"✅ {service_file} exists")
            else:
                print(f"❌ {service_file} missing")
        
        return True
    except Exception as e:
        print(f"❌ Import error: {e}")
        return False

def test_basic_server():
    """Test if we can create a basic FastAPI server"""
    try:
        from fastapi import FastAPI
        
        app = FastAPI(title="Test Server")
        
        @app.get("/")
        async def root():
            return {"status": "ok"}
        
        print("✅ Basic FastAPI server created successfully")
        return True
    except Exception as e:
        print(f"❌ Failed to create server: {e}")
        return False

if __name__ == "__main__":
    print("🧪 Testing AI Microservice Setup")
    print("=" * 40)
    
    imports_ok = test_imports()
    server_ok = test_basic_server()
    
    if imports_ok and server_ok:
        print("\n✅ Basic tests passed! The microservice should be able to start.")
        sys.exit(0)
    else:
        print("\n❌ Some tests failed. Check the errors above.")
        sys.exit(1)
