from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import numpy as np
import io
import logging
from typing import List, Dict, Any, Optional, Callable
import os
from pathlib import Path
import tempfile

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

def env_enabled(name: str, default: bool = True) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


SERVICE_FLAGS = {
    "vision": env_enabled("LOCAL_AI_ENABLE_VISION", True),
    "face": env_enabled("LOCAL_AI_ENABLE_FACE", True),
    "ocr": env_enabled("LOCAL_AI_ENABLE_OCR", True),
    "video": env_enabled("LOCAL_AI_ENABLE_VIDEO", True),
    "whisper": env_enabled("LOCAL_AI_ENABLE_WHISPER", True),
}


def service_available(service: Any) -> bool:
    if service is None:
        return False

    checker = getattr(service, "is_loaded", None)
    if not callable(checker):
        return True

    try:
        return bool(checker())
    except Exception as exc:
        logger.warning("Service availability check failed: %s", exc)
        return False


def load_service(name: str, enabled: bool, factory: Callable[[], Any]):
    if not enabled:
        logger.info("%s service disabled by configuration", name)
        return None

    try:
        service = factory()
    except Exception as exc:
        logger.warning("%s service failed to initialize: %s", name, exc)
        return None

    if service_available(service):
        logger.info("%s service loaded", name)
    else:
        logger.warning("%s service initialized but unavailable", name)

    return service


def build_vision_service():
    from services.vision_service import VisionService
    return VisionService()


def build_face_service():
    from services.face_service import FaceService
    return FaceService()


def build_ocr_service():
    from services.ocr_service import OCRService
    return OCRService()


def build_video_service():
    from services.video_service import VideoService
    return VideoService(
        vision_service=vision_service,
        face_service=face_service,
        ocr_service=ocr_service
    )


def build_whisper_service():
    from services.whisper_service import WhisperService
    return WhisperService()


vision_service = load_service("vision", SERVICE_FLAGS["vision"], build_vision_service)
face_service = load_service("face", SERVICE_FLAGS["face"], build_face_service)
ocr_service = load_service("ocr", SERVICE_FLAGS["ocr"], build_ocr_service)
video_service = load_service("video", SERVICE_FLAGS["video"], build_video_service)
whisper_service = load_service("whisper", SERVICE_FLAGS["whisper"], build_whisper_service)


def disabled_feature_warning(feature: str, reason: str) -> Dict[str, str]:
    return {
        "feature": feature,
        "error_class": "ServiceUnavailable",
        "error_message": reason
    }

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    services_status = {
        "vision": service_available(vision_service),
        "face": service_available(face_service),
        "ocr": service_available(ocr_service),
        "video": service_available(video_service),
        "whisper": service_available(whisper_service),
    }
    healthy = any(bool(value) for value in services_status.values())
    return {
        "status": "healthy" if healthy else "degraded",
        "services": services_status,
        "enabled": SERVICE_FLAGS
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
        warnings = []
        feature_list = features.split(",")
        
        # Object/Label Detection
        if "labels" in feature_list:
            if not service_available(vision_service):
                results["labels"] = []
                warnings.append(disabled_feature_warning("labels", "vision_service_unavailable"))
            else:
                try:
                    if opencv_image is not None:
                        results["labels"] = vision_service.detect_objects(opencv_image)
                except Exception as e:
                    logger.error(f"Label detection error: {e}")
                    results["labels"] = []

        # Text Detection (OCR)
        if "text" in feature_list:
            if not service_available(ocr_service):
                results["text"] = []
                warnings.append(disabled_feature_warning("text", "ocr_service_unavailable"))
            else:
                try:
                    if opencv_image is not None:
                        results["text"] = ocr_service.extract_text(opencv_image)
                except Exception as e:
                    logger.error(f"OCR error: {e}")
                    results["text"] = []

        # Face Detection
        if "faces" in feature_list:
            if not service_available(face_service):
                results["faces"] = []
                warnings.append(disabled_feature_warning("faces", "face_service_unavailable"))
            else:
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
                "features_used": feature_list,
                "warnings": warnings
            }
        }
        
    except Exception as e:
        logger.error(f"Image analysis error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/transcribe/audio")
async def transcribe_audio(
    file: UploadFile = File(...),
    model: Optional[str] = os.getenv("LOCAL_WHISPER_MODEL", "tiny")
):
    """
    Transcribe audio using local Whisper
    """
    if not service_available(whisper_service):
        raise HTTPException(status_code=503, detail="Whisper service not available")
    
    try:
        audio_bytes = await file.read()
        temp_file = tempfile.NamedTemporaryFile(delete=False, suffix=".wav")
        temp_path = temp_file.name
        try:
            temp_file.write(audio_bytes)
            temp_file.flush()
            temp_file.close()
            transcription = whisper_service.transcribe(temp_path, model)
        finally:
            try:
                os.remove(temp_path)
            except OSError:
                pass
        
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
    if not service_available(face_service):
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
    reload_enabled = os.getenv("LOCAL_AI_RELOAD", "false").strip().lower() in {"1", "true", "yes", "on"}
    log_level = os.getenv("LOCAL_AI_LOG_LEVEL", "info").strip().lower() or "info"
    watch_dir = str(Path(__file__).resolve().parent)

    uvicorn.run(
        "main_simple:app",
        host="0.0.0.0",
        port=8000,
        reload=reload_enabled,
        reload_dirs=[watch_dir] if reload_enabled else None,
        log_level=log_level
    )
