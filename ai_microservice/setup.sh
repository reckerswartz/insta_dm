#!/bin/bash

# Local AI Microservice Setup Script

echo "🚀 Setting up Local AI Microservice..."

# Check if Python 3.8+ is available
if ! command -v python3 &> /dev/null; then
    echo "❌ Python 3 is required but not installed."
    exit 1
fi

# Create virtual environment
echo "📦 Creating Python virtual environment..."
if [ ! -d "ai_microservice_env" ]; then
    python3 -m venv ai_microservice_env
    if [ $? -ne 0 ]; then
        echo "❌ Failed to create virtual environment"
        exit 1
    fi
fi

# Activate virtual environment
echo "🔄 Activating virtual environment..."
if [ -f "ai_microservice_env/bin/activate" ]; then
    source ai_microservice_env/bin/activate
else
    echo "❌ Virtual environment activation script not found"
    exit 1
fi

# Upgrade pip
echo "⬆️ Upgrading pip..."
pip install --upgrade pip

# Install requirements
echo "📚 Installing Python packages..."
pip install -r requirements.txt

# Download YOLOv8 model (will be downloaded automatically on first run)
echo "🤖 YOLOv8 model will be downloaded automatically on first run"

# Create startup script
echo "📝 Creating startup script..."
cat > start_microservice.sh << 'EOF'
#!/bin/bash

# Activate virtual environment
source ai_microservice_env/bin/activate

# Start the microservice
echo "🚀 Starting Local AI Microservice on http://localhost:8000"
python main.py
EOF

chmod +x start_microservice.sh

# Create systemd service file (optional)
echo "🔧 Creating systemd service file..."
cat > ai-microservice.service << 'EOF'
[Unit]
Description=Local AI Microservice
After=network.target

[Service]
Type=simple
User=YOUR_USERNAME
WorkingDirectory=PATH_TO_AI_MICROSERVICE
Environment=PATH=PATH_TO_AI_MICROSERVICE/ai_microservice_env/bin
ExecStart=PATH_TO_AI_MICROSERVICE/ai_microservice_env/bin/python main.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo "✅ Setup complete!"
echo ""
echo "🎯 Next steps:"
echo "1. Start the service: ./start_microservice.sh"
echo "2. Test health endpoint: curl http://localhost:8000/health"
echo "3. View API docs: http://localhost:8000/docs"
echo ""
echo "💡 Note: Models will be downloaded on first use (YOLOv8 ~6MB, Whisper ~150MB)"
echo "💡 Total expected disk usage: ~500MB-1GB depending on models used"
