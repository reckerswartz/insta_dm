from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import numpy as np
import base64
import io
import json
import logging
from typing import List, Dict, Any, Optional
import os
from pathlib import Path

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

# Service availability tracking
services_status = {
    "vision": False,
    "face": False,
    "ocr": False,
    "video": False,
    "whisper": False
}

# Try to import and initialize services
try:
    from services.vision_service import VisionService
    vision_service = VisionService()
    services_status["vision"] = vision_service.is_loaded()
    logger.info("Vision service loaded")
except Exception as e:
    logger.warning(f"Vision service failed to load: {e}")
    vision_service = None

try:
    from services.face_service import FaceService
    face_service = FaceService()
    services_status["face"] = face_service.is_loaded()
    logger.info("Face service loaded")
except Exception as e:
    logger.warning(f"Face service failed to load: {e}")
    face_service = None

try:
    from services.ocr_service import OCRService
    ocr_service = OCRService()
    services_status["ocr"] = ocr_service.is_loaded()
    logger.info("OCR service loaded")
except Exception as e:
    logger.warning(f"OCR service failed to load: {e}")
    ocr_service = None

try:
    from services.video_service import VideoService
    video_service = VideoService()
    services_status["video"] = video_service.is_loaded()
    logger.info("Video service loaded")
except Exception as e:
    logger.warning(f"Video service failed to load: {e}")
    video_service = None

try:
    from services.whisper_service import WhisperService
    whisper_service = WhisperService()
    services_status["whisper"] = whisper_service.is_loaded()
    logger.info("Whisper service loaded")
except Exception as e:
    logger.warning(f"Whisper service failed to load: {e}")
    whisper_service = None

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "services": services_status
    }

@app.post("/analyze/image")
async def analyze_image(
    file: UploadFile = File(...),
    features: Optional[str] = "labels,text,faces"
):
    """
    Analyze image with local AI models
    
    Features: labels, text, faces
    """
    try:
        # Read and decode image
        image_bytes = await file.read()
        
        # Try to open with PIL, fallback if not available
        try:
            from PIL import Image
            image = Image.open(io.BytesIO(image_bytes))
            
            # Convert to OpenCV format if available
            try:
                import cv2
                opencv_image = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
            except ImportError:
                opencv_image = None
        except ImportError:
            return {
                "success": False,
                "error": "PIL not available for image processing"
            }
        
        results = {}
        feature_list = features.split(",")
        
        # Object/Label Detection
        if "labels" in feature_list and vision_service:
            try:
                if opencv_image is not None:
                    results["labels"] = vision_service.detect_objects(opencv_image)
            except Exception as e:
                logger.error(f"Label detection error: {e}")
                results["labels"] = []
        
        # Text Detection (OCR)
        if "text" in feature_list and ocr_service:
            try:
                if opencv_image is not None:
                    results["text"] = ocr_service.extract_text(opencv_image)
            except Exception as e:
                logger.error(f"OCR error: {e}")
                results["text"] = []
        
        # Face Detection
        if "faces" in feature_list and face_service:
            try:
                if opencv_image is not None:
                    results["faces"] = face_service.detect_faces(opencv_image)
            except Exception as e:
                logger.error(f"Face detection error: {e}")
                results["faces"] = []
        
        return {
            "success": True,
            "results": results,
            "metadata": {
                "image_size": image.size if 'image' in locals() else "unknown",
                "features_used": feature_list
            }
        }
        
    except Exception as e:
        logger.error(f"Image analysis error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/transcribe/audio")
async def transcribe_audio(
    file: UploadFile = File(...),
    model: Optional[str] = "base"
):
    """
    Transcribe audio using local Whisper
    """
    if not whisper_service:
        raise HTTPException(status_code=503, detail="Whisper service not available")
    
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
    if not face_service:
        raise HTTPException(status_code=503, detail="Face service not available")
    
    try:
        image_bytes = await file.read()
        
        # Try to open with PIL
        try:
            from PIL import Image
            image = Image.open(io.BytesIO(image_bytes))
            
            # Convert to OpenCV format if available
            try:
                import cv2
                opencv_image = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
            except ImportError:
                raise HTTPException(status_code=503, detail="OpenCV not available")
        except ImportError:
            raise HTTPException(status_code=503, detail="PIL not available")
        
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

if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        log_level="info"
    )
