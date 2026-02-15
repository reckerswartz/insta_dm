#!/bin/bash

# AI Microservice Startup Script

echo "🚀 Starting Local AI Microservice..."

# Check if virtual environment exists
if [ ! -d "ai_microservice_env" ]; then
    echo "❌ Virtual environment not found. Please run ./setup.sh first."
    exit 1
fi

# Activate virtual environment
source ai_microservice_env/bin/activate

# Check if service is already running
if curl -s http://localhost:8000/health > /dev/null 2>&1; then
    echo "⚠️  Service is already running on http://localhost:8000"
    echo "📊 Health status:"
    curl -s http://localhost:8000/health | python3 -m json.tool
    exit 0
fi

# Start the service
echo "🔧 Starting service on http://localhost:8000"
echo "📚 API Documentation: http://localhost:8000/docs"
echo "🔍 Health Check: http://localhost:8000/health"
echo ""
echo "Press Ctrl+C to stop the service"
echo ""

python3 main.py
