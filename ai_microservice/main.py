from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import numpy as np
import cv2
import io
from PIL import Image, UnidentifiedImageError
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

MAX_IMAGE_UPLOAD_BYTES = int(os.getenv("LOCAL_AI_MAX_IMAGE_UPLOAD_BYTES", str(20 * 1024 * 1024)))
MIN_IMAGE_UPLOAD_BYTES = int(os.getenv("LOCAL_AI_MIN_IMAGE_UPLOAD_BYTES", "128"))
MAX_IMAGE_DIMENSION = int(os.getenv("LOCAL_AI_MAX_IMAGE_DIMENSION", "2048"))
MAX_VIDEO_UPLOAD_BYTES = int(os.getenv("LOCAL_AI_MAX_VIDEO_UPLOAD_BYTES", str(80 * 1024 * 1024)))


def normalize_feature_list(raw_features: Optional[str], allowed_features: List[str], default_features: List[str]) -> List[str]:
    if not raw_features:
        return list(default_features)

    requested = [item.strip().lower() for item in str(raw_features).split(",") if item and item.strip()]
    valid = [item for item in requested if item in allowed_features]
    return valid or list(default_features)


def disabled_feature_warning(feature: str, reason: str) -> Dict[str, str]:
    return {
        "feature": feature,
        "error_class": "ServiceUnavailable",
        "error_message": reason
    }


def empty_video_results(sample_rate: int) -> Dict[str, Any]:
    return {
        "metadata": {
            "duration": 0,
            "fps": 0,
            "total_frames": 0,
            "frames_analyzed": 0,
            "sample_rate": sample_rate
        },
        "labels": [],
        "faces": [],
        "scenes": [],
        "text": [],
        "shot_changes": []
    }


def decode_uploaded_image(image_bytes: bytes) -> Image.Image:
    if not image_bytes:
        raise HTTPException(status_code=422, detail="empty_image_payload")
    if len(image_bytes) < MIN_IMAGE_UPLOAD_BYTES:
        raise HTTPException(status_code=422, detail="image_payload_too_small")
    if len(image_bytes) > MAX_IMAGE_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="image_payload_too_large")

    try:
        # Validate bytes first, then reopen for actual decoding.
        probe = Image.open(io.BytesIO(image_bytes))
        probe.verify()
        decoded = Image.open(io.BytesIO(image_bytes))
    except UnidentifiedImageError:
        raise HTTPException(status_code=422, detail="unsupported_or_corrupted_image")
    except OSError:
        raise HTTPException(status_code=422, detail="image_decode_failed")

    if decoded.mode != "RGB":
        decoded = decoded.convert("RGB")

    resized = False
    if max(decoded.size) > MAX_IMAGE_DIMENSION:
        resample_filter = Image.Resampling.LANCZOS if hasattr(Image, "Resampling") else Image.LANCZOS
        decoded.thumbnail((MAX_IMAGE_DIMENSION, MAX_IMAGE_DIMENSION), resample_filter)
        resized = True
    decoded.info["resized"] = resized
    return decoded

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    services = {
        "vision": service_available(vision_service),
        "face": service_available(face_service),
        "ocr": service_available(ocr_service),
        "video": service_available(video_service),
        "whisper": service_available(whisper_service)
    }

    return {
        "status": "healthy" if any(services.values()) else "degraded",
        "services": services,
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
        image = decode_uploaded_image(image_bytes)

        # Convert to OpenCV format
        opencv_image = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)

        results = {}
        warnings = []
        feature_list = normalize_feature_list(
            raw_features=features,
            allowed_features=["labels", "text", "faces"],
            default_features=["labels", "text", "faces"]
        )

        # Object/Label Detection
        if "labels" in feature_list:
            if not service_available(vision_service):
                results["labels"] = []
                warnings.append(disabled_feature_warning("labels", "vision_service_unavailable"))
            else:
                try:
                    results["labels"] = vision_service.detect_objects(opencv_image)
                except Exception as e:
                    results["labels"] = []
                    warnings.append({
                        "feature": "labels",
                        "error_class": e.__class__.__name__,
                        "error_message": str(e)
                    })

        # Text Detection (OCR)
        if "text" in feature_list:
            if not service_available(ocr_service):
                results["text"] = []
                warnings.append(disabled_feature_warning("text", "ocr_service_unavailable"))
            else:
                try:
                    results["text"] = ocr_service.extract_text(opencv_image)
                except Exception as e:
                    results["text"] = []
                    warnings.append({
                        "feature": "text",
                        "error_class": e.__class__.__name__,
                        "error_message": str(e)
                    })

        # Face Detection
        if "faces" in feature_list:
            if not service_available(face_service):
                results["faces"] = []
                warnings.append(disabled_feature_warning("faces", "face_service_unavailable"))
            else:
                try:
                    results["faces"] = face_service.detect_faces(opencv_image)
                except Exception as e:
                    results["faces"] = []
                    warnings.append({
                        "feature": "faces",
                        "error_class": e.__class__.__name__,
                        "error_message": str(e)
                    })

        return {
            "success": True,
            "results": results,
            "metadata": {
                "image_size": image.size,
                "features_used": feature_list,
                "bytes_received": len(image_bytes),
                "resized": bool(image.info.get("resized")),
                "warnings": warnings
            }
        }
    except HTTPException as e:
        logger.warning(f"Image analysis rejected: {e.detail}")
        raise e
    except Exception as e:
        logger.exception("Image analysis error")
        raise HTTPException(status_code=500, detail="image_analysis_failed")

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
        if not video_bytes:
            raise HTTPException(status_code=422, detail="empty_video_payload")
        if len(video_bytes) > MAX_VIDEO_UPLOAD_BYTES:
            raise HTTPException(status_code=413, detail="video_payload_too_large")

        temp_file = tempfile.NamedTemporaryFile(delete=False, suffix=".mp4")
        temp_path = temp_file.name
        try:
            temp_file.write(video_bytes)
            temp_file.flush()
            temp_file.close()

            feature_list = normalize_feature_list(
                raw_features=features,
                allowed_features=["labels", "faces", "scenes", "text"],
                default_features=["labels", "faces", "scenes"]
            )
            normalized_sample_rate = int(sample_rate or 2)
            normalized_sample_rate = max(1, min(normalized_sample_rate, 10))

            if video_service is None:
                results = empty_video_results(normalized_sample_rate)
                results["metadata"]["warnings"] = [
                    disabled_feature_warning("video", "video_service_unavailable")
                ]
            else:
                results = video_service.analyze_video(temp_path, feature_list, normalized_sample_rate)
        finally:
            try:
                os.remove(temp_path)
            except OSError:
                pass

        return {
            "success": True,
            "results": results,
            "metadata": {
                "features_used": feature_list,
                "sample_rate": normalized_sample_rate,
                "bytes_received": len(video_bytes)
            }
        }
    except HTTPException as e:
        logger.warning(f"Video analysis rejected: {e.detail}")
        raise e
    except Exception as e:
        logger.exception("Video analysis error")
        raise HTTPException(status_code=500, detail="video_analysis_failed")

@app.post("/transcribe/audio")
async def transcribe_audio(
    file: UploadFile = File(...),
    model: Optional[str] = "base"
):
    """
    Transcribe audio using local Whisper
    """
    if not service_available(whisper_service):
        raise HTTPException(status_code=503, detail="whisper_service_unavailable")

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
        raise HTTPException(status_code=503, detail="face_service_unavailable")

    try:
        image_bytes = await file.read()
        if not image_bytes:
            raise HTTPException(status_code=422, detail="empty_image_payload")
        
        try:
            image = Image.open(io.BytesIO(image_bytes))
            image.verify()  # Verify image integrity
            # Reopen after verify (verify() closes the file)
            image = Image.open(io.BytesIO(image_bytes))
        except (UnidentifiedImageError, OSError) as e:
            raise HTTPException(status_code=422, detail=f"invalid_or_corrupted_image: {str(e)}")
        
        opencv_image = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
        
        embedding = face_service.get_face_embedding(opencv_image)
        
        return {
            "success": True,
            "embedding": embedding.tolist() if embedding is not None else None,
            "metadata": {
                "embedding_size": len(embedding) if embedding is not None else 0
            }
        }
        
    except HTTPException:
        raise
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
    if not service_available(face_service):
        raise HTTPException(status_code=503, detail="face_service_unavailable")

    try:
        # Read both images
        img1_bytes = await file1.read()
        img2_bytes = await file2.read()
        
        if not img1_bytes or not img2_bytes:
            raise HTTPException(status_code=422, detail="empty_image_payload")
        
        try:
            img1 = Image.open(io.BytesIO(img1_bytes))
            img1.verify()
            img1 = Image.open(io.BytesIO(img1_bytes))
        except (UnidentifiedImageError, OSError) as e:
            raise HTTPException(status_code=422, detail=f"invalid_or_corrupted_image_1: {str(e)}")
            
        try:
            img2 = Image.open(io.BytesIO(img2_bytes))
            img2.verify()
            img2 = Image.open(io.BytesIO(img2_bytes))
        except (UnidentifiedImageError, OSError) as e:
            raise HTTPException(status_code=422, detail=f"invalid_or_corrupted_image_2: {str(e)}")
        
        opencv_img1 = cv2.cvtColor(np.array(img1), cv2.COLOR_RGB2BGR)
        opencv_img2 = cv2.cvtColor(np.array(img2), cv2.COLOR_RGB2BGR)
        
        similarity = face_service.compare_faces(opencv_img1, opencv_img2, threshold)
        
        return {
            "success": True,
            "similarity": similarity,
            "is_match": similarity > threshold,
            "threshold": threshold
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Face comparison error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    reload_enabled = os.getenv("LOCAL_AI_RELOAD", "false").strip().lower() in {"1", "true", "yes", "on"}
    log_level = os.getenv("LOCAL_AI_LOG_LEVEL", "info").strip().lower() or "info"
    watch_dir = str(Path(__file__).resolve().parent)

    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=reload_enabled,
        reload_dirs=[watch_dir] if reload_enabled else None,
        log_level=log_level
    )
