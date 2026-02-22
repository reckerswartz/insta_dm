import cv2
import numpy as np
from typing import List, Dict, Any
import logging
import os
import hashlib
from collections import OrderedDict

from .vision_service import VisionService
from .face_service import FaceService
from .ocr_service import OCRService

logger = logging.getLogger(__name__)


def env_enabled(name: str, default: bool = True) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


class VideoService:
    def __init__(self, vision_service=None, face_service=None, ocr_service=None):
        # Reuse already-loaded service instances when available to avoid
        # duplicate model initialization and reduce memory pressure.
        self.vision_service = vision_service if vision_service is not None else VisionService()
        self.face_service = face_service if face_service is not None else FaceService()
        self.ocr_service = ocr_service if ocr_service is not None else OCRService()
        self.max_frames = int(os.getenv("LOCAL_AI_VIDEO_MAX_FRAMES", "12"))
        self.max_frames = max(1, min(self.max_frames, 60))
        self.max_frame_width = int(os.getenv("LOCAL_AI_VIDEO_RESIZE_MAX_WIDTH", "960"))
        self.max_frame_width = max(160, min(self.max_frame_width, 1920))
        self.static_prefilter_enabled = env_enabled("LOCAL_AI_VIDEO_STATIC_PREFILTER", True)
        self.static_prefilter_sample_frames = int(os.getenv("LOCAL_AI_VIDEO_STATIC_PREFILTER_SAMPLES", "4"))
        self.static_prefilter_sample_frames = max(2, min(self.static_prefilter_sample_frames, 8))
        self.static_diff_threshold = float(os.getenv("LOCAL_AI_VIDEO_STATIC_DIFF_THRESHOLD", "8.5"))
        self.static_diff_threshold = max(1.0, min(self.static_diff_threshold, 35.0))
        self.frame_cache_max_entries = int(os.getenv("LOCAL_AI_VIDEO_FRAME_CACHE_SIZE", "64"))
        self.frame_cache_max_entries = max(0, min(self.frame_cache_max_entries, 512))
        self._frame_cache: "OrderedDict[str, List[Dict[str, Any]]]" = OrderedDict()
    
    def is_loaded(self) -> bool:
        statuses = []
        if self.vision_service is not None:
            statuses.append(bool(self.vision_service.is_loaded()))
        if self.face_service is not None:
            statuses.append(bool(self.face_service.is_loaded()))
        if self.ocr_service is not None:
            statuses.append(bool(self.ocr_service.is_loaded()))
        return any(statuses)
    
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
        cap = None
        try:
            cap = cv2.VideoCapture(video_path)
            if not cap.isOpened():
                raise ValueError(f"Cannot open video: {video_path}")
            
            fps = cap.get(cv2.CAP_PROP_FPS)
            fps = float(fps) if fps and fps > 0 else 1.0
            total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
            duration = total_frames / fps if fps > 0 else 0

            normalized_sample_rate = max(1, int(sample_rate or 1))
            frame_indices = self._sampling_frame_indices(
                total_frames=total_frames,
                fps=fps,
                sample_rate=normalized_sample_rate
            )
            static_prefilter = {
                "enabled": self.static_prefilter_enabled,
                "applied": False,
                "detected_static": False,
                "mean_abs_diff": None,
                "max_abs_diff": None
            }

            if self.static_prefilter_enabled and len(frame_indices) > 1:
                static_detected, static_metrics = self._is_static_video(
                    cap=cap,
                    frame_indices=frame_indices
                )
                static_prefilter.update(static_metrics)
                if static_detected:
                    frame_indices = frame_indices[:1]
                    static_prefilter["detected_static"] = True

            results = {
                'metadata': {
                    'duration': duration,
                    'fps': fps,
                    'total_frames': total_frames,
                    'frames_analyzed': 0,
                    'sample_rate': normalized_sample_rate,
                    'max_frames': self.max_frames,
                    'sampled_frame_indices': frame_indices,
                    'static_prefilter': static_prefilter
                },
                'labels': [],
                'faces': [],
                'scenes': [],
                'text': [],
                'shot_changes': []
            }

            analyzed_frames = 0
            last_frame = None

            for frame_index in frame_indices:
                frame = self._read_frame_at(cap=cap, frame_index=frame_index)
                if frame is None:
                    continue

                prepared = self._prepare_frame(frame)
                analyzed_frames += 1
                timestamp = frame_index / fps if fps > 0 else 0.0

                frame_results = self._analyze_frame(prepared, features, timestamp)

                if 'labels' in features:
                    results['labels'].extend(frame_results.get('labels', []))

                if 'faces' in features:
                    results['faces'].extend(frame_results.get('faces', []))

                if 'text' in features:
                    results['text'].extend(frame_results.get('text', []))

                if 'scenes' in features and last_frame is not None:
                    scene_change = self._detect_scene_change(last_frame, prepared, timestamp)
                    if scene_change:
                        results['scenes'].append(scene_change)

                last_frame = prepared
            
            # Update metadata
            results['metadata']['frames_analyzed'] = analyzed_frames
            
            # Post-process results
            results = self._post_process_results(results)
            
            return results
            
        except Exception as e:
            logger.error(f"Video analysis error: {e}")
            raise
        finally:
            if cap is not None:
                cap.release()
    
    def _analyze_frame(self, frame: np.ndarray, features: List[str], timestamp: float) -> Dict[str, Any]:
        """Analyze a single frame"""
        frame_results = {}
        frame_signature = self._frame_signature(frame)
        
        try:
            # Object/Label Detection
            if 'labels' in features and self.vision_service is not None and self.vision_service.is_loaded():
                labels = self._cached_inference(
                    feature_name="labels",
                    frame_signature=frame_signature,
                    infer_fn=lambda: self.vision_service.detect_objects(frame)
                )
                annotated_labels = []
                for label in labels:
                    row = dict(label) if isinstance(label, dict) else {"label": str(label)}
                    row['timestamp'] = timestamp
                    annotated_labels.append(row)
                frame_results['labels'] = annotated_labels
            
            # Face Detection
            if 'faces' in features and self.face_service is not None and self.face_service.is_loaded():
                faces = self._cached_inference(
                    feature_name="faces",
                    frame_signature=frame_signature,
                    infer_fn=lambda: self.face_service.detect_faces(frame)
                )
                annotated_faces = []
                for face in faces:
                    row = dict(face) if isinstance(face, dict) else {"bbox": [], "confidence": 0.0}
                    row['timestamp'] = timestamp
                    annotated_faces.append(row)
                frame_results['faces'] = annotated_faces
            
            # Text Detection
            if 'text' in features and self.ocr_service is not None and self.ocr_service.is_loaded():
                text = self._cached_inference(
                    feature_name="text",
                    frame_signature=frame_signature,
                    infer_fn=lambda: self.ocr_service.extract_text(frame)
                )
                annotated_text = []
                for text_item in text:
                    row = dict(text_item) if isinstance(text_item, dict) else {"text": str(text_item)}
                    row['timestamp'] = timestamp
                    annotated_text.append(row)
                frame_results['text'] = annotated_text
        
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

    def _sampling_frame_indices(self, total_frames: int, fps: float, sample_rate: int) -> List[int]:
        if total_frames <= 0:
            return [0]

        frame_interval = max(int(round(float(fps) * float(sample_rate))), 1)
        indices = list(range(0, total_frames, frame_interval))
        if not indices:
            indices = [0]
        if len(indices) == 1 and total_frames > 1:
            indices.append(total_frames - 1)
        return self._limit_frame_indices(indices, self.max_frames)

    def _limit_frame_indices(self, indices: List[int], max_frames: int) -> List[int]:
        clean = sorted({max(0, int(idx)) for idx in indices})
        if len(clean) <= max_frames:
            return clean

        if max_frames <= 1:
            return [clean[0]]

        sample_positions = np.linspace(0, len(clean) - 1, num=max_frames)
        reduced = [clean[int(round(pos))] for pos in sample_positions]
        return sorted({int(idx) for idx in reduced})

    def _read_frame_at(self, cap: cv2.VideoCapture, frame_index: int):
        cap.set(cv2.CAP_PROP_POS_FRAMES, max(0, int(frame_index)))
        ret, frame = cap.read()
        if not ret:
            return None
        return frame

    def _prepare_frame(self, frame: np.ndarray) -> np.ndarray:
        if frame is None or frame.size == 0:
            return frame

        height, width = frame.shape[:2]
        if width <= self.max_frame_width:
            return frame

        ratio = self.max_frame_width / float(width)
        resized_height = max(1, int(round(height * ratio)))
        return cv2.resize(frame, (self.max_frame_width, resized_height), interpolation=cv2.INTER_AREA)

    def _is_static_video(self, cap: cv2.VideoCapture, frame_indices: List[int]):
        diagnostic = {
            "applied": True,
            "mean_abs_diff": None,
            "max_abs_diff": None
        }
        probe_indices = self._limit_frame_indices(
            frame_indices,
            self.static_prefilter_sample_frames
        )
        if len(probe_indices) < 2:
            return False, diagnostic

        gray_frames = []
        for idx in probe_indices:
            frame = self._read_frame_at(cap=cap, frame_index=idx)
            if frame is None:
                continue
            frame = self._prepare_frame(frame)
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            gray = cv2.resize(gray, (64, 64), interpolation=cv2.INTER_AREA)
            gray_frames.append(gray)

        if len(gray_frames) < 2:
            return False, diagnostic

        diffs = []
        for prev, curr in zip(gray_frames, gray_frames[1:]):
            diffs.append(float(np.mean(cv2.absdiff(prev, curr))))

        if not diffs:
            return False, diagnostic

        mean_diff = float(np.mean(diffs))
        max_diff = float(np.max(diffs))
        diagnostic["mean_abs_diff"] = round(mean_diff, 3)
        diagnostic["max_abs_diff"] = round(max_diff, 3)

        static_detected = (
            mean_diff <= self.static_diff_threshold and
            max_diff <= (self.static_diff_threshold * 1.35)
        )
        return static_detected, diagnostic

    def _frame_signature(self, frame: np.ndarray) -> str:
        if frame is None or frame.size == 0:
            return "empty"
        return hashlib.sha1(frame.tobytes()).hexdigest()

    def _cache_get(self, key: str):
        if self.frame_cache_max_entries <= 0:
            return None
        value = self._frame_cache.get(key)
        if value is None:
            return None
        self._frame_cache.move_to_end(key)
        return [dict(item) if isinstance(item, dict) else item for item in value]

    def _cache_set(self, key: str, value: List[Dict[str, Any]]):
        if self.frame_cache_max_entries <= 0:
            return
        self._frame_cache[key] = [dict(item) if isinstance(item, dict) else item for item in value]
        self._frame_cache.move_to_end(key)
        while len(self._frame_cache) > self.frame_cache_max_entries:
            self._frame_cache.popitem(last=False)

    def _cached_inference(self, feature_name: str, frame_signature: str, infer_fn):
        cache_key = f"{feature_name}:{frame_signature}"
        cached = self._cache_get(cache_key)
        if cached is not None:
            return cached

        value = infer_fn()
        normalized = [dict(item) if isinstance(item, dict) else item for item in (value or [])]
        self._cache_set(cache_key, normalized)
        return [dict(item) if isinstance(item, dict) else item for item in normalized]
