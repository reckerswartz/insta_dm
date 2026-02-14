import cv2
import numpy as np
from typing import List, Dict, Any
import logging
import os
import tempfile

from .vision_service import VisionService
from .face_service import FaceService
from .ocr_service import OCRService

logger = logging.getLogger(__name__)

class VideoService:
    def __init__(self):
        self.vision_service = VisionService()
        self.face_service = FaceService()
        self.ocr_service = OCRService()
    
    def is_loaded(self) -> bool:
        return all([
            self.vision_service.is_loaded(),
            self.face_service.is_loaded(),
            self.ocr_service.is_loaded()
        ])
    
    def analyze_video(self, video_path: str, features: List[str], sample_rate: int = 2) -> Dict[str, Any]:
        """
        Analyze video by sampling frames and applying AI models
        
        Args:
            video_path: Path to video file
            features: List of features to extract ['labels', 'faces', 'scenes', 'text']
            sample_rate: Sample every N seconds
        
        Returns:
            Dictionary with analysis results
        """
        try:
            cap = cv2.VideoCapture(video_path)
            if not cap.isOpened():
                raise ValueError(f"Cannot open video: {video_path}")
            
            fps = cap.get(cv2.CAP_PROP_FPS)
            total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
            duration = total_frames / fps if fps > 0 else 0
            
            # Calculate frame sampling
            frames_to_sample = int(duration / sample_rate)
            frame_interval = int(fps * sample_rate)
            
            results = {
                'metadata': {
                    'duration': duration,
                    'fps': fps,
                    'total_frames': total_frames,
                    'frames_analyzed': 0,
                    'sample_rate': sample_rate
                },
                'labels': [],
                'faces': [],
                'scenes': [],
                'text': [],
                'shot_changes': []
            }
            
            frame_count = 0
            analyzed_frames = 0
            last_frame = None
            
            while True:
                ret, frame = cap.read()
                if not ret:
                    break
                
                # Sample frames at specified interval
                if frame_count % frame_interval == 0:
                    analyzed_frames += 1
                    timestamp = frame_count / fps
                    
                    # Analyze frame based on requested features
                    frame_results = self._analyze_frame(frame, features, timestamp)
                    
                    # Aggregate results
                    if 'labels' in features:
                        results['labels'].extend(frame_results.get('labels', []))
                    
                    if 'faces' in features:
                        results['faces'].extend(frame_results.get('faces', []))
                    
                    if 'text' in features:
                        results['text'].extend(frame_results.get('text', []))
                    
                    if 'scenes' in features and last_frame is not None:
                        # Basic scene change detection
                        scene_change = self._detect_scene_change(last_frame, frame, timestamp)
                        if scene_change:
                            results['scenes'].append(scene_change)
                    
                    last_frame = frame.copy()
                
                frame_count += 1
            
            cap.release()
            
            # Update metadata
            results['metadata']['frames_analyzed'] = analyzed_frames
            
            # Post-process results
            results = self._post_process_results(results)
            
            return results
            
        except Exception as e:
            logger.error(f"Video analysis error: {e}")
            raise
    
    def _analyze_frame(self, frame: np.ndarray, features: List[str], timestamp: float) -> Dict[str, Any]:
        """Analyze a single frame"""
        frame_results = {}
        
        try:
            # Object/Label Detection
            if 'labels' in features:
                labels = self.vision_service.detect_objects(frame)
                for label in labels:
                    label['timestamp'] = timestamp
                frame_results['labels'] = labels
            
            # Face Detection
            if 'faces' in features:
                faces = self.face_service.detect_faces(frame)
                for face in faces:
                    face['timestamp'] = timestamp
                frame_results['faces'] = faces
            
            # Text Detection
            if 'text' in features:
                text = self.ocr_service.extract_text(frame)
                for text_item in text:
                    text_item['timestamp'] = timestamp
                frame_results['text'] = text
        
        except Exception as e:
            logger.error(f"Frame analysis error at {timestamp}: {e}")
        
        return frame_results
    
    def _detect_scene_change(self, prev_frame: np.ndarray, curr_frame: np.ndarray, timestamp: float) -> Dict[str, Any]:
        """
        Basic scene change detection using histogram comparison
        """
        try:
            # Convert to grayscale
            prev_gray = cv2.cvtColor(prev_frame, cv2.COLOR_BGR2GRAY)
            curr_gray = cv2.cvtColor(curr_frame, cv2.COLOR_BGR2GRAY)
            
            # Calculate histograms
            hist_prev = cv2.calcHist([prev_gray], [0], None, [256], [0, 256])
            hist_curr = cv2.calcHist([curr_gray], [0], None, [256], [0, 256])
            
            # Compare histograms
            correlation = cv2.compareHist(hist_prev, hist_curr, cv2.HISTCMP_CORREL)
            
            # Scene change threshold (lower correlation = more different)
            if correlation < 0.7:  # Threshold can be tuned
                return {
                    'timestamp': timestamp,
                    'correlation': correlation,
                    'type': 'scene_change'
                }
            
            return None
            
        except Exception as e:
            logger.error(f"Scene change detection error: {e}")
            return None
    
    def _post_process_results(self, results: Dict[str, Any]) -> Dict[str, Any]:
        """Post-process and aggregate results"""
        
        # Aggregate and rank labels
        if results['labels']:
            label_counts = {}
            for label in results['labels']:
                label_name = label['label']
                if label_name not in label_counts:
                    label_counts[label_name] = {
                        'label': label_name,
                        'count': 0,
                        'max_confidence': 0,
                        'timestamps': []
                    }
                
                label_counts[label_name]['count'] += 1
                label_counts[label_name]['max_confidence'] = max(
                    label_counts[label_name]['max_confidence'], 
                    label['confidence']
                )
                label_counts[label_name]['timestamps'].append(label['timestamp'])
            
            # Sort by frequency and confidence
            aggregated_labels = sorted(
                label_counts.values(),
                key=lambda x: (x['count'], x['max_confidence']),
                reverse=True
            )
            results['labels'] = aggregated_labels[:20]  # Top 20 labels
        
        # Aggregate faces
        if results['faces']:
            # Group faces by approximate position over time
            face_groups = self._group_faces_over_time(results['faces'])
            results['faces'] = face_groups
        
        # Aggregate text
        if results['text']:
            # Remove duplicate text entries
            unique_texts = []
            seen_texts = set()
            
            for text_item in results['text']:
                text_lower = text_item['text'].lower()
                if text_lower not in seen_texts and len(text_item['text']) > 2:
                    seen_texts.add(text_lower)
                    unique_texts.append(text_item)
            
            results['text'] = unique_texts[:50]  # Top 50 unique text entries
        
        return results
    
    def _group_faces_over_time(self, faces: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Group face detections by approximate position to track faces over time
        """
        if not faces:
            return []
        
        # Simple grouping by proximity (more sophisticated tracking could be added)
        face_groups = []
        used_indices = set()
        
        for i, face in enumerate(faces):
            if i in used_indices:
                continue
            
            group = {
                'face_id': len(face_groups),
                'detections': [face],
                'first_seen': face['timestamp'],
                'last_seen': face['timestamp'],
                'detection_count': 1
            }
            used_indices.add(i)
            
            # Find nearby faces in subsequent frames
            for j, other_face in enumerate(faces[i+1:], start=i+1):
                if j in used_indices:
                    continue
                
                # Check if faces are in similar position (simple proximity check)
                if self._faces_are_similar(face, other_face):
                    group['detections'].append(other_face)
                    group['last_seen'] = other_face['timestamp']
                    group['detection_count'] += 1
                    used_indices.add(j)
            
            face_groups.append(group)
        
        return face_groups
    
    def _faces_are_similar(self, face1: Dict[str, Any], face2: Dict[str, Any], threshold: float = 0.3) -> bool:
        """Check if two face detections are likely the same person based on position"""
        try:
            bbox1 = np.array(face1['bbox'])
            bbox2 = np.array(face2['bbox'])
            
            # Calculate center points
            center1 = np.array([(bbox1[0] + bbox1[2]) / 2, (bbox1[1] + bbox1[3]) / 2])
            center2 = np.array([(bbox2[0] + bbox2[2]) / 2, (bbox2[1] + bbox2[3]) / 2])
            
            # Calculate distance
            distance = np.linalg.norm(center1 - center2)
            
            # Normalize by image size (assuming similar frame sizes)
            # This is a simple heuristic - more sophisticated methods exist
            return distance < threshold
            
        except Exception:
            return False
