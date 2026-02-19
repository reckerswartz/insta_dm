import cv2
import numpy as np
from typing import List, Dict, Any, Optional
import logging
import os

try:
    from retinaface_pytorch import RetinaFace
    RETINAFACE_AVAILABLE = True
except ImportError:
    try:
        # Try alternative import
        from retinaface import RetinaFace
        RETINAFACE_AVAILABLE = True
    except ImportError:
        RETINAFACE_AVAILABLE = False
        logging.warning("RetinaFace not available, using OpenCV face detection")

try:
    import insightface
    from insightface.app import FaceAnalysis
    INSIGHTFACE_AVAILABLE = True
except ImportError:
    INSIGHTFACE_AVAILABLE = False
    logging.warning("InsightFace not available, face embeddings disabled")

logger = logging.getLogger(__name__)

class FaceService:
    def __init__(self):
        self.face_detector = None
        self.profile_face_detector = None
        self.face_analyzer = None
        self.min_size = max(16, int(os.getenv("LOCAL_FACE_MIN_SIZE", "24")))
        self.scale_factor = max(1.01, float(os.getenv("LOCAL_FACE_SCALE_FACTOR", "1.05")))
        self.min_neighbors = max(1, int(os.getenv("LOCAL_FACE_MIN_NEIGHBORS", "3")))
        self.min_confidence = max(0.0, float(os.getenv("LOCAL_FACE_MIN_CONFIDENCE", "0.25")))
        self._load_models()
    
    def _load_models(self):
        """Load face detection and recognition models"""
        try:
            if INSIGHTFACE_AVAILABLE:
                # Initialize InsightFace for embeddings
                self.face_analyzer = FaceAnalysis(name='buffalo_l')  # Lightweight model
                self.face_analyzer.prepare(ctx_id=-1)  # CPU mode
                logger.info("InsightFace loaded successfully")
        except Exception as e:
            logger.warning(
                "Failed to load InsightFace (%s): %r. Falling back to OpenCV detector only.",
                e.__class__.__name__,
                e
            )
            self.face_analyzer = None
        
        # Always load OpenCV as fallback
        try:
            self.face_detector = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_frontalface_default.xml')
            profile_path = cv2.data.haarcascades + "haarcascade_profileface.xml"
            self.profile_face_detector = cv2.CascadeClassifier(profile_path)
            logger.info("OpenCV face detector loaded")
        except Exception as e:
            logger.error(f"Failed to load OpenCV face detector: {e}")
            self.face_detector = None
            self.profile_face_detector = None
    
    def is_loaded(self) -> bool:
        return self.face_detector is not None or self.face_analyzer is not None
    
    def detect_faces(self, image: np.ndarray) -> List[Dict[str, Any]]:
        """
        Detect faces in image
        Returns list of face detections with bounding boxes and confidence
        """
        faces = []
        
        try:
            if RETINAFACE_AVAILABLE:
                faces.extend(self._detect_with_retinaface(image))

            if not faces and (self.face_detector is not None or self.profile_face_detector is not None):
                faces.extend(self._detect_with_opencv(image))
        
        except Exception as e:
            logger.error(f"Face detection error: {e}")
        
        return self._dedupe_faces(faces)
    
    def get_face_embedding(self, image: np.ndarray) -> Optional[np.ndarray]:
        """
        Generate face embedding for recognition
        Returns embedding vector or None if no face detected
        """
        if self.face_analyzer is None:
            logger.warning("Face embedding not available (InsightFace not loaded)")
            return None
        
        try:
            # Detect and analyze faces
            faces = self.face_analyzer.get(image)
            
            if len(faces) > 0:
                # Return embedding for the first detected face
                embedding = faces[0].embedding
                return embedding
            else:
                return None
                
        except Exception as e:
            logger.error(f"Face embedding error: {e}")
            return None
    
    def compare_faces(self, image1: np.ndarray, image2: np.ndarray, threshold: float = 0.6) -> float:
        """
        Compare two face images and return similarity score
        Returns cosine similarity between 0 and 1
        """
        if self.face_analyzer is None:
            logger.warning("Face comparison not available")
            return 0.0
        
        try:
            # Get embeddings for both images
            emb1 = self.get_face_embedding(image1)
            emb2 = self.get_face_embedding(image2)
            
            if emb1 is None or emb2 is None:
                return 0.0
            
            # Calculate cosine similarity
            similarity = np.dot(emb1, emb2) / (np.linalg.norm(emb1) * np.linalg.norm(emb2))
            
            return float(similarity)
            
        except Exception as e:
            logger.error(f"Face comparison error: {e}")
            return 0.0

    def _detect_with_retinaface(self, image: np.ndarray) -> List[Dict[str, Any]]:
        out: List[Dict[str, Any]] = []
        try:
            faces_data = RetinaFace.detect_faces(image)
            if not isinstance(faces_data, dict):
                return out

            for _face_id, face_info in faces_data.items():
                if not isinstance(face_info, dict):
                    continue

                bbox = face_info.get("facial_area")
                if not isinstance(bbox, (list, tuple)) or len(bbox) != 4:
                    continue

                confidence = float(face_info.get("score", 0.9))
                if confidence < self.min_confidence:
                    continue

                out.append({
                    "bbox": [int(bbox[0]), int(bbox[1]), int(bbox[2]), int(bbox[3])],
                    "confidence": confidence,
                    "landmarks": face_info.get("landmarks", []),
                    "age": face_info.get("age"),
                    "gender": face_info.get("gender"),
                    "gender_score": face_info.get("gender_score"),
                })
        except Exception as e:
            logger.warning("RetinaFace detection failed (%s): %s", e.__class__.__name__, e)

        return out

    def _detect_with_opencv(self, image: np.ndarray) -> List[Dict[str, Any]]:
        out: List[Dict[str, Any]] = []
        if image is None:
            return out

        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        equalized = cv2.equalizeHist(gray)
        detector_rows = [
            (self.face_detector, 0.80),
            (self.profile_face_detector, 0.68),
        ]
        variants = [gray, equalized]

        for variant in variants:
            variant_rows = [(variant, 1.0)]
            min_dim = min(variant.shape[:2])
            if min_dim < 640:
                scale = 640.0 / float(max(1, min_dim))
                upscaled = cv2.resize(variant, None, fx=scale, fy=scale, interpolation=cv2.INTER_LINEAR)
                variant_rows.append((upscaled, scale))

            for frame, scale in variant_rows:
                for detector, confidence in detector_rows:
                    if detector is None:
                        continue

                    detections = detector.detectMultiScale(
                        frame,
                        scaleFactor=self.scale_factor,
                        minNeighbors=self.min_neighbors,
                        minSize=(self.min_size, self.min_size),
                    )
                    for (x, y, w, h) in detections:
                        x1 = int(x / scale)
                        y1 = int(y / scale)
                        x2 = int((x + w) / scale)
                        y2 = int((y + h) / scale)
                        if (x2 - x1) < self.min_size or (y2 - y1) < self.min_size:
                            continue

                        out.append({
                            "bbox": [x1, y1, x2, y2],
                            "confidence": confidence,
                            "landmarks": [],
                            "age": None,
                            "gender": None,
                            "gender_score": None,
                        })

        return out

    def _dedupe_faces(self, faces: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        if not faces:
            return []

        sorted_faces = sorted(
            [row for row in faces if isinstance(row, dict) and isinstance(row.get("bbox"), (list, tuple)) and len(row.get("bbox")) == 4],
            key=lambda row: float(row.get("confidence", 0.0)),
            reverse=True,
        )
        kept: List[Dict[str, Any]] = []

        for candidate in sorted_faces:
            bbox = [float(v) for v in candidate.get("bbox", [0, 0, 0, 0])]
            if any(self._iou(bbox, [float(v) for v in current.get("bbox", [0, 0, 0, 0])]) > 0.35 for current in kept):
                continue
            kept.append(candidate)

        return kept

    def _iou(self, box_a: List[float], box_b: List[float]) -> float:
        ax1, ay1, ax2, ay2 = box_a
        bx1, by1, bx2, by2 = box_b
        inter_x1 = max(ax1, bx1)
        inter_y1 = max(ay1, by1)
        inter_x2 = min(ax2, bx2)
        inter_y2 = min(ay2, by2)
        inter_w = max(0.0, inter_x2 - inter_x1)
        inter_h = max(0.0, inter_y2 - inter_y1)
        inter_area = inter_w * inter_h
        if inter_area <= 0:
            return 0.0

        area_a = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)
        area_b = max(0.0, bx2 - bx1) * max(0.0, by2 - by1)
        denom = area_a + area_b - inter_area
        if denom <= 0:
            return 0.0

        return inter_area / denom
