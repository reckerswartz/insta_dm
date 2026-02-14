from ultralytics import YOLO
import cv2
import numpy as np
from typing import List, Dict, Any
import logging

logger = logging.getLogger(__name__)

class VisionService:
    def __init__(self):
        self.model = None
        self.safe_classes = {
            'adult': ['person', 'people', 'human', 'man', 'woman'],
            'violence': ['weapon', 'gun', 'knife', 'sword', 'blood', 'explosion'],
            'racy': ['underwear', 'lingerie', 'bikini', 'swimsuit']
        }
        self._load_model()
    
    def _load_model(self):
        """Load YOLOv8 model"""
        try:
            # Use YOLOv8n (nano) for faster inference on CPU
            self.model = YOLO('yolov8n.pt')
            logger.info("YOLOv8 model loaded successfully")
        except Exception as e:
            logger.error(f"Failed to load YOLOv8: {e}")
            self.model = None
    
    def is_loaded(self) -> bool:
        return self.model is not None
    
    def detect_objects(self, image: np.ndarray, confidence: float = 0.25) -> List[Dict[str, Any]]:
        """
        Detect objects using YOLOv8
        Returns list of detected objects with labels and confidence scores
        """
        if self.model is None:
            return []
        
        try:
            results = self.model(image, conf=confidence)
            detections = []
            
            for result in results:
                boxes = result.boxes
                if boxes is not None:
                    for box in boxes:
                        # Get class name and confidence
                        cls = int(box.cls[0])
                        conf = float(box.conf[0])
                        class_name = self.model.names[cls]
                        
                        detections.append({
                            'label': class_name,
                            'confidence': conf,
                            'bbox': box.xyxy[0].tolist()  # [x1, y1, x2, y2]
                        })
            
            # Sort by confidence and return top 20
            detections.sort(key=lambda x: x['confidence'], reverse=True)
            return detections[:20]
            
        except Exception as e:
            logger.error(f"Object detection error: {e}")
            return []
    
    def detect_safe_content(self, image: np.ndarray) -> Dict[str, str]:
        """
        Basic safe search detection using object classes
        Returns: {'adult': 'likely'|'unlikely'|'unknown', ...}
        """
        detections = self.detect_objects(image, confidence=0.3)
        labels = [d['label'] for d in detections]
        
        results = {}
        for category, sensitive_classes in self.safe_classes.items():
            found_sensitive = any(label in sensitive_classes for label in labels)
            
            if found_sensitive:
                # Check confidence levels
                max_conf = max([d['confidence'] for d in detections if d['label'] in sensitive_classes], default=0)
                if max_conf > 0.7:
                    results[category] = 'likely'
                elif max_conf > 0.4:
                    results[category] = 'possible'
                else:
                    results[category] = 'unlikely'
            else:
                results[category] = 'unlikely'
        
        return results
