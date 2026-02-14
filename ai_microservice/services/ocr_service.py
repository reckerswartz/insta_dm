import cv2
import numpy as np
from typing import List, Dict, Any
import logging

try:
    from paddleocr import PaddleOCR
    PADDLEOCR_AVAILABLE = True
except ImportError:
    PADDLEOCR_AVAILABLE = False
    logging.warning("PaddleOCR not available")

try:
    import easyocr
    EASYOCR_AVAILABLE = True
except ImportError:
    EASYOCR_AVAILABLE = False
    logging.warning("EasyOCR not available")

logger = logging.getLogger(__name__)

class OCRService:
    def __init__(self):
        self.paddle_ocr = None
        self.easy_reader = None
        self._load_models()
    
    def _load_models(self):
        """Load OCR models"""
        try:
            if PADDLEOCR_AVAILABLE:
                # Initialize PaddleOCR (use angle classifier for rotated text)
                self.paddle_ocr = PaddleOCR(use_angle_cls=True, lang='en', show_log=False)
                logger.info("PaddleOCR loaded successfully")
        except Exception as e:
            logger.error(f"Failed to load PaddleOCR: {e}")
            self.paddle_ocr = None
        
        try:
            if EASYOCR_AVAILABLE:
                # Initialize EasyOCR as backup
                self.easy_reader = easyocr.Reader(['en'])
                logger.info("EasyOCR loaded successfully")
        except Exception as e:
            logger.error(f"Failed to load EasyOCR: {e}")
            self.easy_reader = None
    
    def is_loaded(self) -> bool:
        return self.paddle_ocr is not None or self.easy_reader is not None
    
    def extract_text(self, image: np.ndarray) -> List[Dict[str, Any]]:
        """
        Extract text from image using available OCR engine
        Returns list of detected text with bounding boxes
        """
        results = []
        
        # Try PaddleOCR first (generally more accurate)
        if self.paddle_ocr is not None:
            try:
                paddle_results = self._extract_with_paddle(image)
                if paddle_results:
                    results.extend(paddle_results)
                    return results
            except Exception as e:
                logger.error(f"PaddleOCR error: {e}")
        
        # Fallback to EasyOCR
        if self.easy_reader is not None:
            try:
                easy_results = self._extract_with_easyocr(image)
                if easy_results:
                    results.extend(easy_results)
            except Exception as e:
                logger.error(f"EasyOCR error: {e}")
        
        return results
    
    def _extract_with_paddle(self, image: np.ndarray) -> List[Dict[str, Any]]:
        """Extract text using PaddleOCR"""
        results = []
        
        try:
            # PaddleOCR expects RGB format
            if len(image.shape) == 3 and image.shape[2] == 3:
                # Convert BGR to RGB
                image_rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
            else:
                image_rgb = image
            
            ocr_results = self.paddle_ocr.ocr(image_rgb, cls=True)
            
            if ocr_results and ocr_results[0]:
                for line in ocr_results[0]:
                    if line and len(line) >= 2:
                        bbox = line[0]  # Bounding box
                        text_info = line[1]  # (text, confidence)
                        
                        if text_info and len(text_info) >= 2:
                            text = text_info[0].strip()
                            confidence = text_info[1]
                            
                            if text and confidence > 0.5:  # Filter low confidence
                                results.append({
                                    'text': text,
                                    'confidence': confidence,
                                    'bbox': bbox,  # [[x1,y1], [x2,y2], [x3,y3], [x4,y4]]
                                    'source': 'paddleocr'
                                })
        
        except Exception as e:
            logger.error(f"PaddleOCR extraction error: {e}")
        
        return results
    
    def _extract_with_easyocr(self, image: np.ndarray) -> List[Dict[str, Any]]:
        """Extract text using EasyOCR"""
        results = []
        
        try:
            # EasyOCR handles BGR/RGB automatically
            ocr_results = self.easy_reader.readtext(image)
            
            for (bbox, text, confidence) in ocr_results:
                if text and confidence > 0.5:  # Filter low confidence
                    results.append({
                        'text': text.strip(),
                        'confidence': confidence,
                        'bbox': bbox,  # [[x1,y1], [x2,y2], [x3,y3], [x4,y4]]
                        'source': 'easyocr'
                    })
        
        except Exception as e:
            logger.error(f"EasyOCR extraction error: {e}")
        
        return results
    
    def get_simple_text(self, image: np.ndarray) -> List[str]:
        """
        Simple text extraction - returns just the text strings
        Useful for basic text analysis
        """
        ocr_results = self.extract_text(image)
        return [result['text'] for result in ocr_results]
