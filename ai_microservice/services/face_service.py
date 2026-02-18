import cv2
import numpy as np
from typing import List, Dict, Any, Optional
import logging

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
        self.face_analyzer = None
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
            logger.info("OpenCV face detector loaded")
        except Exception as e:
            logger.error(f"Failed to load OpenCV face detector: {e}")
            self.face_detector = None
    
    def is_loaded(self) -> bool:
        return self.face_detector is not None or self.face_analyzer is not None
    
    def detect_faces(self, image: np.ndarray) -> List[Dict[str, Any]]:
        """
        Detect faces in image
        Returns list of face detections with bounding boxes and confidence
        """
        faces = []
        
        try:
            if RETINAFACE_AVAILABLE and self.face_analyzer:
                # Use RetinaFace for better detection
                faces_data = RetinaFace.detect_faces(image)
                
                if isinstance(faces_data, dict):
                    for face_id, face_info in faces_data.items():
                        if 'facial_area' in face_info:
                            bbox = face_info['facial_area']
                            confidence = face_info.get('score', 0.9)
                            
                            faces.append({
                                'bbox': [int(bbox[0]), int(bbox[1]), int(bbox[2]), int(bbox[3])],  # [x1, y1, x2, y2]
                                'confidence': float(confidence),
                                'landmarks': face_info.get('landmarks', []),
                                'age': face_info.get('age'),
                                'gender': face_info.get('gender'),
                                'gender_score': face_info.get('gender_score')
                            })
            else:
                # Fallback to OpenCV
                gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
                detections = self.face_detector.detectMultiScale(
                    gray, 
                    scaleFactor=1.1, 
                    minNeighbors=5,
                    minSize=(30, 30)
                )
                
                for (x, y, w, h) in detections:
                    faces.append({
                        'bbox': [int(x), int(y), int(x + w), int(y + h)],
                        'confidence': 0.8,  # OpenCV doesn't provide confidence
                        'landmarks': [],
                        'age': None,
                        'gender': None,
                        'gender_score': None
                    })
        
        except Exception as e:
            logger.error(f"Face detection error: {e}")
        
        return faces
    
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
