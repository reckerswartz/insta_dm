import cv2
import numpy as np
from typing import List, Dict, Any, Tuple
import logging
import os

try:
    from paddleocr import PaddleOCR
    PADDLEOCR_AVAILABLE = True
except ImportError:
    PADDLEOCR_AVAILABLE = False
    logging.warning("PaddleOCR not available")

# EasyOCR versions before Pillow 10 expect PIL.Image.ANTIALIAS.
try:
    from PIL import Image
    if not hasattr(Image, "ANTIALIAS") and hasattr(Image, "Resampling"):
        Image.ANTIALIAS = Image.Resampling.LANCZOS
except Exception:
    Image = None

try:
    import easyocr
    EASYOCR_AVAILABLE = True
except ImportError:
    EASYOCR_AVAILABLE = False
    logging.warning("EasyOCR not available")

logger = logging.getLogger(__name__)


class OCRService:
    MIN_CONFIDENCE = float(os.getenv("LOCAL_OCR_MIN_CONFIDENCE", "0.35"))

    def __init__(self):
        self.paddle_ocr = None
        self.easy_reader = None
        self._paddle_runtime_available = True
        self._load_models()

    def _load_models(self):
        """Load OCR models"""
        try:
            if PADDLEOCR_AVAILABLE:
                # Keep angle classifier for rotated text; runtime fallback handles API differences.
                self.paddle_ocr = PaddleOCR(use_angle_cls=True, lang="en")
                logger.info("PaddleOCR loaded successfully")
        except Exception as e:
            logger.error(f"Failed to load PaddleOCR: {e}")
            self.paddle_ocr = None

        try:
            if EASYOCR_AVAILABLE:
                self.easy_reader = easyocr.Reader(["en"])
                logger.info("EasyOCR loaded successfully")
        except Exception as e:
            logger.error(f"Failed to load EasyOCR: {e}")
            self.easy_reader = None

    def is_loaded(self) -> bool:
        return self.paddle_ocr is not None or self.easy_reader is not None

    def extract_text(self, image: np.ndarray) -> List[Dict[str, Any]]:
        """
        Extract text from image using robust multi-pass preprocessing.
        Returns list of detected text with bounding boxes.
        """
        if image is None:
            return []

        variants = self._build_variants(image)
        collected: List[Dict[str, Any]] = []

        # Primary path: PaddleOCR across a small set of preprocessed variants.
        for variant_name, variant_image in variants:
            if self.paddle_ocr is None:
                break
            paddle_rows = self._extract_with_paddle(variant_image, variant_name=variant_name)
            if paddle_rows:
                collected.extend(paddle_rows)

        # Fallback path: EasyOCR on strongest variants when Paddle returns nothing.
        if not collected and self.easy_reader is not None:
            for variant_name, variant_image in variants[:6]:
                easy_rows = self._extract_with_easyocr(variant_image, variant_name=variant_name)
                if easy_rows:
                    collected.extend(easy_rows)
                if len(collected) >= 6:
                    break

        return self._dedupe_results(collected)

    def _extract_with_paddle(self, image: np.ndarray, variant_name: str) -> List[Dict[str, Any]]:
        """Extract text using PaddleOCR and handle API shape differences."""
        results: List[Dict[str, Any]] = []
        if self.paddle_ocr is None or not self._paddle_runtime_available:
            return results

        try:
            image_rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB) if len(image.shape) == 3 else image
            raw = self._run_paddle_ocr(image_rgb)
            parsed = self._parse_paddle_output(raw)

            for row in parsed:
                text = row["text"].strip()
                confidence = float(row.get("confidence", 0.0))
                if not text or confidence < self.MIN_CONFIDENCE:
                    continue

                results.append(
                    {
                        "text": text,
                        "confidence": confidence,
                        "bbox": self._normalize_bbox(row.get("bbox")),
                        "source": "paddleocr",
                        "variant": variant_name,
                    }
                )
        except Exception as e:
            logger.error(f"PaddleOCR extraction error: {e}")
            if self._paddle_error_is_fatal(e):
                self._paddle_runtime_available = False

        return results

    def _paddle_error_is_fatal(self, error: Exception) -> bool:
        message = str(error).lower()
        return (
            "convertpirattribute2runtimeattribute" in message
            or "tuple index out of range" in message
            or "unsupported paddleocr api signature" in message
        )

    def _extract_with_easyocr(self, image: np.ndarray, variant_name: str) -> List[Dict[str, Any]]:
        """Extract text using EasyOCR."""
        results: List[Dict[str, Any]] = []
        if self.easy_reader is None:
            return results

        try:
            ocr_results = self.easy_reader.readtext(image)
            for bbox, text, confidence in ocr_results:
                confidence = float(confidence)
                text = str(text).strip()
                if not text or confidence < self.MIN_CONFIDENCE:
                    continue

                results.append(
                    {
                        "text": text,
                        "confidence": confidence,
                        "bbox": self._normalize_bbox(bbox),
                        "source": "easyocr",
                        "variant": variant_name,
                    }
                )
        except Exception as e:
            logger.error(f"EasyOCR extraction error: {e}")

        return results

    def _run_paddle_ocr(self, image_rgb: np.ndarray):
        # PaddleOCR signatures differ across versions. Try common call patterns.
        try:
            return self.paddle_ocr.ocr(image_rgb, cls=True)
        except TypeError:
            pass

        try:
            return self.paddle_ocr.ocr(image_rgb)
        except TypeError:
            pass

        if hasattr(self.paddle_ocr, "predict"):
            return self.paddle_ocr.predict(image_rgb)

        raise RuntimeError("Unsupported PaddleOCR API signature")

    def _parse_paddle_output(self, raw: Any) -> List[Dict[str, Any]]:
        rows: List[Dict[str, Any]] = []

        if isinstance(raw, dict):
            rows.extend(self._parse_paddle_mapping(raw))
            return rows

        if isinstance(raw, list):
            # Legacy shape: [[ [bbox, [text, conf]], ... ]]
            if raw and isinstance(raw[0], list) and raw[0] and isinstance(raw[0][0], list):
                candidate_lines = raw[0]
                for line in candidate_lines:
                    entry = self._parse_legacy_paddle_line(line)
                    if entry:
                        rows.append(entry)

            # Newer wrappers may return list of dict payloads.
            for item in raw:
                if isinstance(item, dict):
                    rows.extend(self._parse_paddle_mapping(item))
                elif isinstance(item, list):
                    entry = self._parse_legacy_paddle_line(item)
                    if entry:
                        rows.append(entry)

        return rows

    def _parse_legacy_paddle_line(self, line: Any) -> Dict[str, Any]:
        if not isinstance(line, list) or len(line) < 2:
            return {}
        bbox = line[0]
        text_info = line[1]
        if not isinstance(text_info, (list, tuple)) or len(text_info) < 2:
            return {}

        return {
            "text": str(text_info[0]),
            "confidence": float(text_info[1]),
            "bbox": bbox,
        }

    def _parse_paddle_mapping(self, payload: Dict[str, Any]) -> List[Dict[str, Any]]:
        texts = payload.get("rec_texts") or payload.get("texts") or []
        scores = payload.get("rec_scores") or payload.get("scores") or []
        boxes = payload.get("dt_polys") or payload.get("polys") or payload.get("boxes") or []

        rows: List[Dict[str, Any]] = []
        for idx, text in enumerate(texts):
            score = scores[idx] if idx < len(scores) else 0.0
            bbox = boxes[idx] if idx < len(boxes) else []
            rows.append(
                {
                    "text": str(text),
                    "confidence": float(score),
                    "bbox": bbox,
                }
            )

        return rows

    def _build_variants(self, image: np.ndarray) -> List[Tuple[str, np.ndarray]]:
        base = image
        if len(base.shape) == 2:
            base = cv2.cvtColor(base, cv2.COLOR_GRAY2BGR)

        h, w = base.shape[:2]
        variants: List[Tuple[str, np.ndarray]] = [("original", base)]

        upscale = 2.0 if max(h, w) < 1400 else 1.4
        upscaled = cv2.resize(base, None, fx=upscale, fy=upscale, interpolation=cv2.INTER_CUBIC)
        variants.append(("upscaled", upscaled))

        gray = cv2.cvtColor(base, cv2.COLOR_BGR2GRAY)
        clahe = cv2.createCLAHE(clipLimit=2.5, tileGridSize=(8, 8)).apply(gray)
        otsu = cv2.threshold(cv2.GaussianBlur(gray, (3, 3), 0), 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)[1]
        adaptive = cv2.adaptiveThreshold(gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 31, 5)

        variants.extend(
            [
                ("gray_up", cv2.resize(gray, None, fx=upscale, fy=upscale, interpolation=cv2.INTER_CUBIC)),
                ("clahe_up", cv2.resize(clahe, None, fx=upscale, fy=upscale, interpolation=cv2.INTER_CUBIC)),
                ("otsu_up", cv2.resize(otsu, None, fx=upscale, fy=upscale, interpolation=cv2.INTER_CUBIC)),
                ("adaptive_up", cv2.resize(adaptive, None, fx=upscale, fy=upscale, interpolation=cv2.INTER_CUBIC)),
                ("rot90", cv2.rotate(upscaled, cv2.ROTATE_90_CLOCKWISE)),
                ("rot270", cv2.rotate(upscaled, cv2.ROTATE_90_COUNTERCLOCKWISE)),
            ]
        )

        # Meme/share posts often contain top and bottom overlays.
        top_crop = base[0 : int(h * 0.35), :]
        bottom_crop = base[int(h * 0.60) : h, :]
        if top_crop.size > 0:
            variants.append(("top_overlay", cv2.resize(top_crop, None, fx=2.8, fy=2.8, interpolation=cv2.INTER_CUBIC)))
        if bottom_crop.size > 0:
            variants.append(("bottom_overlay", cv2.resize(bottom_crop, None, fx=2.8, fy=2.8, interpolation=cv2.INTER_CUBIC)))

        for idx, region in enumerate(self._extract_text_regions(gray)):
            variants.append((f"region_{idx}", cv2.resize(region, None, fx=2.5, fy=2.5, interpolation=cv2.INTER_CUBIC)))

        return variants[:14]

    def _extract_text_regions(self, gray: np.ndarray) -> List[np.ndarray]:
        regions: List[np.ndarray] = []
        try:
            grad_x = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
            grad_x = cv2.convertScaleAbs(grad_x)
            thresh = cv2.threshold(grad_x, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)[1]
            kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (17, 3))
            closed = cv2.morphologyEx(thresh, cv2.MORPH_CLOSE, kernel, iterations=1)

            contours, _ = cv2.findContours(closed, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            h, w = gray.shape[:2]

            candidates = []
            for contour in contours:
                x, y, cw, ch = cv2.boundingRect(contour)
                if cw < max(60, int(w * 0.16)):
                    continue
                if ch < 14:
                    continue
                if cw / float(max(ch, 1)) < 1.5:
                    continue
                area = cw * ch
                if area < 1200:
                    continue
                candidates.append((area, x, y, cw, ch))

            for _area, x, y, cw, ch in sorted(candidates, reverse=True)[:4]:
                pad_x = int(cw * 0.05)
                pad_y = int(ch * 0.4)
                x1 = max(0, x - pad_x)
                y1 = max(0, y - pad_y)
                x2 = min(w, x + cw + pad_x)
                y2 = min(h, y + ch + pad_y)
                region = gray[y1:y2, x1:x2]
                if region.size > 0:
                    regions.append(region)
        except Exception as e:
            logger.debug(f"Text region detection skipped: {e}")

        return regions

    def _normalize_bbox(self, bbox: Any):
        if bbox is None:
            return []
        if isinstance(bbox, np.ndarray):
            bbox = bbox.tolist()

        if isinstance(bbox, list) and bbox and isinstance(bbox[0], (list, tuple, np.ndarray)):
            return [[float(pt[0]), float(pt[1])] for pt in bbox if len(pt) >= 2]
        if isinstance(bbox, list) and len(bbox) == 4 and all(isinstance(v, (int, float)) for v in bbox):
            x1, y1, x2, y2 = [float(v) for v in bbox]
            return [[x1, y1], [x2, y1], [x2, y2], [x1, y2]]

        return []

    def _dedupe_results(self, rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        deduped: Dict[str, Dict[str, Any]] = {}

        for row in rows:
            text = str(row.get("text", "")).strip()
            if not text:
                continue

            key = " ".join(text.lower().split())
            existing = deduped.get(key)
            if existing is None or float(row.get("confidence", 0.0)) > float(existing.get("confidence", 0.0)):
                deduped[key] = {
                    "text": text,
                    "confidence": float(row.get("confidence", 0.0)),
                    "bbox": row.get("bbox", []),
                    "source": row.get("source", "ocr"),
                    "variant": row.get("variant", "original"),
                }

        return sorted(deduped.values(), key=lambda item: item["confidence"], reverse=True)[:120]

    def get_simple_text(self, image: np.ndarray) -> List[str]:
        """
        Simple text extraction - returns just the text strings.
        """
        ocr_results = self.extract_text(image)
        return [result["text"] for result in ocr_results]
