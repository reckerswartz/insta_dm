from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import numpy as np
import cv2
import base64
import io
from PIL import Image
import json
import logging
from typing import List, Dict, Any, Optional
import os
from pathlib import Path

# Import AI modules
from services.vision_service import VisionService
from services.face_service import FaceService
from services.ocr_service import OCRService
from services.video_service import VideoService
from services.whisper_service import WhisperService

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Local AI Microservice", version="1.0.0")

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Initialize services
vision_service = VisionService()
face_service = FaceService()
ocr_service = OCRService()
video_service = VideoService()
whisper_service = WhisperService()

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "services": {
            "vision": vision_service.is_loaded(),
            "face": face_service.is_loaded(),
            "ocr": ocr_service.is_loaded(),
            "video": video_service.is_loaded(),
            "whisper": whisper_service.is_loaded()
        }
    }

@app.post("/analyze/image")
async def analyze_image(
    file: UploadFile = File(...),
    features: Optional[str] = "labels,text,faces,safe_search"
):
    """
    Analyze image with local AI models
    
    Features: labels, text, faces, safe_search
    """
    try:
        # Read and decode image
        image_bytes = await file.read()
        image = Image.open(io.BytesIO(image_bytes))
        
        # Convert to OpenCV format
        opencv_image = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
        
        results = {}
        feature_list = features.split(",")
        
        # Object/Label Detection
        if "labels" in feature_list:
            results["labels"] = vision_service.detect_objects(opencv_image)
        
        # Text Detection (OCR)
        if "text" in feature_list:
            results["text"] = ocr_service.extract_text(opencv_image)
        
        # Face Detection
        if "faces" in feature_list:
            results["faces"] = face_service.detect_faces(opencv_image)
        
        # Safe Search (basic content detection)
        if "safe_search" in feature_list:
            results["safe_search"] = vision_service.detect_safe_content(opencv_image)
        
        return {
            "success": True,
            "results": results,
            "metadata": {
                "image_size": image.size,
                "features_used": feature_list
            }
        }
        
    except Exception as e:
        logger.error(f"Image analysis error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/analyze/video")
async def analyze_video(
    file: UploadFile = File(...),
    features: Optional[str] = "labels,faces,scenes",
    sample_rate: Optional[int] = 2  # Sample every 2 seconds
):
    """
    Analyze video with local AI models
    
    Features: labels, faces, scenes
    Sample_rate: seconds between frame sampling
    """
    try:
        video_bytes = await file.read()
        
        # Save temporary video file
        temp_path = "/tmp/temp_video.mp4"
        with open(temp_path, "wb") as f:
            f.write(video_bytes)
        
        results = video_service.analyze_video(temp_path, features.split(","), sample_rate)
        
        # Clean up
        os.remove(temp_path)
        
        return {
            "success": True,
            "results": results,
            "metadata": {
                "features_used": features.split(","),
                "sample_rate": sample_rate
            }
        }
        
    except Exception as e:
        logger.error(f"Video analysis error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/transcribe/audio")
async def transcribe_audio(
    file: UploadFile = File(...),
    model: Optional[str] = "base"
):
    """
    Transcribe audio using local Whisper
    """
    try:
        audio_bytes = await file.read()
        
        # Save temporary audio file
        temp_path = "/tmp/temp_audio.wav"
        with open(temp_path, "wb") as f:
            f.write(audio_bytes)
        
        transcription = whisper_service.transcribe(temp_path, model)
        
        # Clean up
        os.remove(temp_path)
        
        return {
            "success": True,
            "transcript": transcription["text"],
            "metadata": {
                "model": model,
                "confidence": transcription.get("confidence", 0.0)
            }
        }
        
    except Exception as e:
        logger.error(f"Audio transcription error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/face/embedding")
async def get_face_embedding(file: UploadFile = File(...)):
    """
    Generate face embedding for recognition
    """
    try:
        image_bytes = await file.read()
        image = Image.open(io.BytesIO(image_bytes))
        opencv_image = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
        
        embedding = face_service.get_face_embedding(opencv_image)
        
        return {
            "success": True,
            "embedding": embedding.tolist() if embedding is not None else None,
            "metadata": {
                "embedding_size": len(embedding) if embedding is not None else 0
            }
        }
        
    except Exception as e:
        logger.error(f"Face embedding error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/face/compare")
async def compare_faces(
    file1: UploadFile = File(...),
    file2: UploadFile = File(...),
    threshold: Optional[float] = 0.6
):
    """
    Compare two faces and return similarity score
    """
    try:
        # Read both images
        img1_bytes = await file1.read()
        img2_bytes = await file2.read()
        
        img1 = Image.open(io.BytesIO(img1_bytes))
        img2 = Image.open(io.BytesIO(img2_bytes))
        
        opencv_img1 = cv2.cvtColor(np.array(img1), cv2.COLOR_RGB2BGR)
        opencv_img2 = cv2.cvtColor(np.array(img2), cv2.COLOR_RGB2BGR)
        
        similarity = face_service.compare_faces(opencv_img1, opencv_img2, threshold)
        
        return {
            "success": True,
            "similarity": similarity,
            "is_match": similarity > threshold,
            "threshold": threshold
        }
        
    except Exception as e:
        logger.error(f"Face comparison error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        log_level="info"
    )
