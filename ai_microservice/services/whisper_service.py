import logging
import os
import tempfile
from typing import Dict, Any

try:
    from faster_whisper import WhisperModel
    FASTER_WHISPER_AVAILABLE = True
except ImportError:
    FASTER_WHISPER_AVAILABLE = False
    logging.warning("faster-whisper not available")

logger = logging.getLogger(__name__)


def env_enabled(name: str, default: bool = True) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


class WhisperService:
    def __init__(self):
        self.models = {}
        self.default_model = os.getenv("LOCAL_WHISPER_MODEL", "tiny").strip() or "tiny"
        self.compute_type = os.getenv("LOCAL_WHISPER_COMPUTE_TYPE", "int8").strip() or "int8"
        self.allow_dynamic_model_loading = env_enabled("LOCAL_WHISPER_ALLOW_DYNAMIC_MODEL_LOADING", False)
        self._load_default_model()
    
    def _load_default_model(self):
        """Load default Whisper model"""
        try:
            if FASTER_WHISPER_AVAILABLE:
                # Load base model on CPU
                self.models[self.default_model] = WhisperModel(
                    self.default_model,
                    device="cpu",
                    compute_type=self.compute_type
                )
                logger.info(f"Whisper model '{self.default_model}' loaded successfully")
            else:
                logger.warning("faster-whisper not available, transcription disabled")
        except Exception as e:
            logger.error(f"Failed to load Whisper model: {e}")
    
    def is_loaded(self) -> bool:
        return self.default_model in self.models
    
    def transcribe(self, audio_path: str, model_size: str = None) -> Dict[str, Any]:
        """
        Transcribe audio file using Whisper
        
        Args:
            audio_path: Path to audio file
            model_size: Whisper model size ('tiny', 'base', 'small', 'medium', 'large')
        
        Returns:
            Dictionary with transcription text and metadata
        """
        try:
            requested_model = model_size or self.default_model
            if requested_model not in self.models:
                if requested_model != self.default_model and not self.allow_dynamic_model_loading:
                    requested_model = self.default_model
                if requested_model not in self.models:
                    self._load_model(requested_model)

            if requested_model not in self.models:
                raise ValueError(f"Could not load Whisper model: {requested_model}")
            
            model = self.models[requested_model]
            
            # Transcribe audio
            segments, info = model.transcribe(
                audio_path,
                language="en",  # Specify English for better accuracy
                beam_size=1,
                best_of=1,
                vad_filter=True,
                condition_on_previous_text=False
            )
            
            # Collect transcription
            transcription_text = []
            segment_data = []
            total_duration = 0
            
            for segment in segments:
                segment_text = segment.text.strip()
                if segment_text:
                    transcription_text.append(segment_text)
                    segment_data.append({
                        'start': segment.start,
                        'end': segment.end,
                        'text': segment_text
                    })
                    total_duration = max(total_duration, segment.end)
            
            full_text = " ".join(transcription_text)
            
            # Calculate average confidence (Whisper doesn't provide per-word confidence)
            # We'll use duration and text length as a proxy
            confidence = min(1.0, len(full_text.split()) / max(1, total_duration * 2))  # Rough estimate
            
            return {
                'text': full_text,
                'segments': segment_data,
                'duration': total_duration,
                'language': info.language,
                'language_probability': info.language_probability,
                'confidence': confidence,
                'model': requested_model
            }
            
        except Exception as e:
            logger.error(f"Whisper transcription error: {e}")
            return {
                'text': '',
                'segments': [],
                'duration': 0,
                'language': 'unknown',
                'language_probability': 0.0,
                'confidence': 0.0,
                'model': model_size or self.default_model,
                'error': str(e)
            }
    
    def _load_model(self, model_size: str):
        """Load specific Whisper model"""
        try:
            if FASTER_WHISPER_AVAILABLE:
                self.models[model_size] = WhisperModel(
                    model_size,
                    device="cpu",
                    compute_type=self.compute_type
                )
                logger.info(f"Whisper model '{model_size}' loaded successfully")
        except Exception as e:
            logger.error(f"Failed to load Whisper model '{model_size}': {e}")
            raise
    
    def get_available_models(self) -> list:
        """Get list of available Whisper models"""
        return ["tiny", "base", "small", "medium", "large"]
    
    def unload_model(self, model_size: str):
        """Unload a model to free memory"""
        if model_size in self.models:
            del self.models[model_size]
            logger.info(f"Whisper model '{model_size}' unloaded")
