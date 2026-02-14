#!/bin/bash

# Activate virtual environment
source ai_microservice_env/bin/activate

# Start the microservice
echo "🚀 Starting Local AI Microservice on http://localhost:8000"
python main.py
