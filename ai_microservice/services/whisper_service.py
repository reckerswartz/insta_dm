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

class WhisperService:
    def __init__(self):
        self.models = {}
        self.default_model = "base"
        self._load_default_model()
    
    def _load_default_model(self):
        """Load default Whisper model"""
        try:
            if FASTER_WHISPER_AVAILABLE:
                # Load base model on CPU
                self.models[self.default_model] = WhisperModel(
                    self.default_model,
                    device="cpu",
                    compute_type="int8"  # Use int8 for lower memory usage
                )
                logger.info(f"Whisper model '{self.default_model}' loaded successfully")
            else:
                logger.warning("faster-whisper not available, transcription disabled")
        except Exception as e:
            logger.error(f"Failed to load Whisper model: {e}")
    
    def is_loaded(self) -> bool:
        return self.default_model in self.models
    
    def transcribe(self, audio_path: str, model_size: str = "base") -> Dict[str, Any]:
        """
        Transcribe audio file using Whisper
        
        Args:
            audio_path: Path to audio file
            model_size: Whisper model size ('tiny', 'base', 'small', 'medium', 'large')
        
        Returns:
            Dictionary with transcription text and metadata
        """
        try:
            # Load model if not already loaded
            if model_size not in self.models:
                self._load_model(model_size)
            
            if model_size not in self.models:
                raise ValueError(f"Could not load Whisper model: {model_size}")
            
            model = self.models[model_size]
            
            # Transcribe audio
            segments, info = model.transcribe(
                audio_path,
                language="en",  # Specify English for better accuracy
                beam_size=2,    # Smaller beam size for faster processing
                vad_filter=True # Voice activity detection
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
                'model': model_size
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
                'model': model_size,
                'error': str(e)
            }
    
    def _load_model(self, model_size: str):
        """Load specific Whisper model"""
        try:
            if FASTER_WHISPER_AVAILABLE:
                self.models[model_size] = WhisperModel(
                    model_size,
                    device="cpu",
                    compute_type="int8"
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
