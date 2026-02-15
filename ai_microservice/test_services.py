#!/usr/bin/env python3
"""
Test script to verify AI microservice functionality
"""

import requests
import json
import io
import base64
from PIL import Image, ImageDraw
import numpy as np

def create_test_image():
    """Create a simple test image with some text"""
    # Create a simple image with text
    img = Image.new('RGB', (400, 200), color='white')
    draw = ImageDraw.Draw(img)
    draw.text((20, 20), "Hello World", fill='black')
    draw.text((20, 50), "Test Image", fill='blue')
    
    # Convert to bytes
    img_bytes = io.BytesIO()
    img.save(img_bytes, format='JPEG')
    img_bytes.seek(0)
    
    return img_bytes

def test_health():
    """Test health endpoint"""
    print("🔍 Testing health endpoint...")
    try:
        response = requests.get("http://localhost:8000/health")
        if response.status_code == 200:
            data = response.json()
            print("✅ Health check passed")
            print(f"   Services: {data['services']}")
            return True
        else:
            print(f"❌ Health check failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Health check error: {e}")
        return False

def test_ocr():
    """Test OCR service"""
    print("\n🔍 Testing OCR service...")
    try:
        img_bytes = create_test_image()
        files = {'file': ('test.jpg', img_bytes, 'image/jpeg')}
        data = {'features': 'text'}
        
        response = requests.post("http://localhost:8000/analyze/image", files=files, data=data)
        if response.status_code == 200:
            result = response.json()
            print("✅ OCR test passed")
            if result.get('results', {}).get('text'):
                for text_item in result['results']['text']:
                    print(f"   Detected: '{text_item['text']}' (confidence: {text_item['confidence']:.2f})")
            return True
        else:
            print(f"❌ OCR test failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ OCR test error: {e}")
        return False

def test_vision():
    """Test vision service"""
    print("\n🔍 Testing vision service...")
    try:
        img_bytes = create_test_image()
        files = {'file': ('test.jpg', img_bytes, 'image/jpeg')}
        data = {'features': 'labels'}
        
        response = requests.post("http://localhost:8000/analyze/image", files=files, data=data)
        if response.status_code == 200:
            result = response.json()
            print("✅ Vision test passed")
            labels = result.get('results', {}).get('labels', [])
            if labels:
                for label in labels[:3]:  # Show top 3
                    print(f"   Detected: {label['label']} (confidence: {label['confidence']:.2f})")
            else:
                print("   No objects detected (expected for simple test image)")
            return True
        else:
            print(f"❌ Vision test failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Vision test error: {e}")
        return False

def test_face():
    """Test face detection service"""
    print("\n🔍 Testing face detection service...")
    try:
        img_bytes = create_test_image()
        files = {'file': ('test.jpg', img_bytes, 'image/jpeg')}
        data = {'features': 'faces'}
        
        response = requests.post("http://localhost:8000/analyze/image", files=files, data=data)
        if response.status_code == 200:
            result = response.json()
            print("✅ Face detection test passed")
            faces = result.get('results', {}).get('faces', [])
            print(f"   Faces detected: {len(faces)}")
            return True
        else:
            print(f"❌ Face detection test failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Face detection test error: {e}")
        return False

def main():
    """Run all tests"""
    print("🚀 Testing AI Microservice Services")
    print("=" * 50)
    
    tests = [
        ("Health Check", test_health),
        ("OCR Service", test_ocr),
        ("Vision Service", test_vision),
        ("Face Detection", test_face)
    ]
    
    results = []
    for test_name, test_func in tests:
        try:
            success = test_func()
            results.append((test_name, success))
        except Exception as e:
            print(f"❌ {test_name} failed with exception: {e}")
            results.append((test_name, False))
    
    print("\n" + "=" * 50)
    print("📊 Test Results Summary:")
    print("=" * 50)
    
    passed = 0
    for test_name, success in results:
        status = "✅ PASS" if success else "❌ FAIL"
        print(f"{status} {test_name}")
        if success:
            passed += 1
    
    print(f"\n🎯 Overall: {passed}/{len(results)} tests passed")
    
    if passed == len(results):
        print("🎉 All services are working correctly!")
    else:
        print("⚠️  Some services may need attention")

if __name__ == "__main__":
    main()
