"""
Legacy compatibility entrypoint.

Historically this file carried a second FastAPI implementation that drifted away
from `main.py`. Keeping one canonical server implementation avoids duplicated
maintenance and inconsistent runtime behavior.
"""

from main import app


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=False)
