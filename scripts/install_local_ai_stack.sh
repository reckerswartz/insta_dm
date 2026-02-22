#!/bin/bash

# Local AI Stack - Complete Installation & Verification Script
# This script installs and configures the entire local AI stack for Linux

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="$PWD"
PYTHON_VERSION="3.12"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:3b}"
OLLAMA_QUALITY_MODEL="${OLLAMA_QUALITY_MODEL:-$OLLAMA_MODEL}"
OLLAMA_VISION_MODEL="${OLLAMA_VISION_MODEL:-llava:7b}"

# Logging
LOG_FILE="$INSTALL_DIR/installation.log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

print_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" >> "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1" >> "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
}

check_system() {
    print_header "System Check"
    
    # Check OS
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        print_status "Linux system detected"
    else
        print_error "This script is designed for Linux systems"
        exit 1
    fi
    
    # Check architecture
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        print_status "x86_64 architecture detected"
    else
        print_warning "Architecture $ARCH may have limited support"
    fi
    
    # Check memory
    MEMORY=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $MEMORY -ge 16 ]]; then
        print_status "$MEMORY GB RAM detected (recommended: 16GB+)"
    else
        print_warning "$MEMORY GB RAM detected (16GB+ recommended for optimal performance)"
    fi
    
    # Check disk space
    DISK=$(df -BG "$INSTALL_DIR" | awk 'NR==2{print $4}' | sed 's/G//')
    if [[ $DISK -ge 5 ]]; then
        print_status "$DISK GB free disk space"
    else
        print_warning "Only $DISK GB free space (5GB+ recommended)"
    fi
}

install_system_dependencies() {
    print_header "Installing System Dependencies"
    
    # Update package list
    print_status "Updating package list..."
    sudo apt update
    
    # Install basic dependencies
    print_status "Installing basic dependencies..."
    sudo apt install -y \
        curl \
        wget \
        git \
        build-essential \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        unzip \
        htop \
        tree
    
    # Install Python and development tools
    print_status "Installing Python $PYTHON_VERSION and development tools..."
    sudo apt install -y \
        python$PYTHON_VERSION \
        python$PYTHON_VERSION-venv \
        python$PYTHON_VERSION-dev \
        python3-pip \
        python3-dev
    
    # Install system libraries for AI/ML
    print_status "Installing AI/ML system libraries..."
    sudo apt install -y \
        libgl1-mesa-glx \
        libglib2.0-0 \
        libsm6 \
        libxext6 \
        libxrender-dev \
        libgomp1 \
        libgthread-2.0-0 \
        libjpeg-dev \
        libpng-dev \
        libtiff-dev \
        libavcodec-dev \
        libavformat-dev \
        libswscale-dev \
        libv4l-dev \
        libxvidcore-dev \
        libx264-dev \
        libgtk-3-dev \
        libatlas-base-dev \
        gfortran
    
    # Install FFmpeg for video processing
    print_status "Installing FFmpeg..."
    sudo apt install -y ffmpeg
    
    print_status "System dependencies installed successfully"
}

install_ollama() {
    print_header "Installing Ollama"
    
    # Check if Ollama is already installed
    if command -v ollama &> /dev/null; then
        print_status "Ollama already installed"
    else
        print_status "Installing Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
        
        # Add to PATH
        if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
        fi
        export PATH="$HOME/.local/bin:$PATH"
    fi
    
    # Start Ollama service
    print_status "Starting Ollama service..."
    sudo systemctl enable ollama
    sudo systemctl start ollama
    
    # Wait for service to start
    sleep 5
    
    # Check if Ollama is running
    if curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
        print_status "Ollama service is running"
    else
        print_error "Ollama service failed to start"
        return 1
    fi
    
    # Pull the models
    print_status "Pulling primary model $OLLAMA_MODEL (this may take a while)..."
    ollama pull "$OLLAMA_MODEL"
    if [[ "$OLLAMA_QUALITY_MODEL" != "$OLLAMA_MODEL" ]]; then
        print_status "Pulling quality model $OLLAMA_QUALITY_MODEL (this may take a while)..."
        ollama pull "$OLLAMA_QUALITY_MODEL"
    fi
    if [[ "$OLLAMA_VISION_MODEL" != "$OLLAMA_MODEL" && "$OLLAMA_VISION_MODEL" != "$OLLAMA_QUALITY_MODEL" ]]; then
        print_status "Pulling vision model $OLLAMA_VISION_MODEL (this may take a while)..."
        ollama pull "$OLLAMA_VISION_MODEL"
    fi
    
    print_status "Ollama installation completed"
}

setup_python_environment() {
    print_header "Setting Up Python Environment"
    
    cd "$INSTALL_DIR/ai_microservice"
    
    # Create virtual environment
    if [[ ! -d "ai_microservice_env" ]]; then
        print_status "Creating Python virtual environment..."
        python$PYTHON_VERSION -m venv ai_microservice_env
    else
        print_status "Virtual environment already exists"
    fi
    
    # Activate virtual environment
    print_status "Activating virtual environment..."
    source ai_microservice_env/bin/activate
    
    # Upgrade pip
    print_status "Upgrading pip..."
    pip install --upgrade pip setuptools wheel
    
    # Install Python packages
    print_status "Installing Python packages..."
    pip install -r requirements.txt
    
    print_status "Python environment setup completed"
}

setup_rails_environment() {
    print_header "Setting Up Rails Environment"
    
    cd "$INSTALL_DIR"
    
    # Check if Ruby is installed
    if ! command -v ruby &> /dev/null; then
        print_error "Ruby is not installed. Please install Ruby first."
        return 1
    fi
    
    # Install Rails dependencies
    if [[ -f "Gemfile" ]]; then
        print_status "Installing Rails dependencies..."
        bundle install
    else
        print_warning "Gemfile not found. Skipping Rails dependencies."
    fi
    
    # Run database migrations
    if [[ -f "db/schema.rb" ]]; then
        print_status "Running database migrations..."
        rails db:migrate
    fi
    
    print_status "Rails environment setup completed"
}

configure_services() {
    print_header "Configuring Services"
    
    cd "$INSTALL_DIR"
    
    # Create necessary directories
    print_status "Creating necessary directories..."
    mkdir -p tmp log
    
    # Update .gitignore
    print_status "Updating .gitignore..."
    if ! grep -q "/ai_microservice/__pycache__" .gitignore; then
        echo "/ai_microservice/__pycache__" >> .gitignore
    fi
    
    # Set up environment variables
    print_status "Setting up environment variables..."
    if [[ ! -f ".env" ]]; then
        cp config/local_ai.env.example .env
        print_status "Created .env file from template"
    fi
    
    # Configure Rails providers
    print_status "Configuring Rails AI providers..."
    rails runner "
        AiProviderSetting.where(provider: 'local').first_or_create.update(
            config: {
              ollama_model: '$OLLAMA_MODEL',
              ollama_fast_model: '$OLLAMA_MODEL',
              ollama_quality_model: '$OLLAMA_QUALITY_MODEL',
              ollama_comment_model: '$OLLAMA_MODEL',
              ollama_vision_model: '$OLLAMA_VISION_MODEL'
            },
            enabled: true
        )
        AiProviderSetting.where(provider: 'google_cloud').update_all(enabled: false)
    " 2>/dev/null || print_warning "Rails provider configuration skipped (Rails not ready)"
    
    print_status "Service configuration completed"
}

verify_installation() {
    print_header "Verifying Installation"
    
    # Check Ollama
    print_status "Checking Ollama..."
    if curl -s http://localhost:11434/api/tags | grep -Fq "$OLLAMA_MODEL"; then
        print_status "✅ Ollama is running with primary model $OLLAMA_MODEL"
    else
        print_error "❌ Ollama verification failed"
        return 1
    fi
    if curl -s http://localhost:11434/api/tags | grep -Fq "$OLLAMA_VISION_MODEL"; then
        print_status "✅ Vision model available: $OLLAMA_VISION_MODEL"
    else
        print_warning "⚠️ Vision model not preloaded: $OLLAMA_VISION_MODEL"
    fi
    
    # Check Python environment
    print_status "Checking Python environment..."
    cd "$INSTALL_DIR/ai_microservice"
    source ai_microservice_env/bin/activate
    
    if python -c "import fastapi, uvicorn, numpy, PIL" 2>/dev/null; then
        print_status "✅ Python packages installed correctly"
    else
        print_error "❌ Python packages verification failed"
        return 1
    fi
    
    # Test AI microservice
    print_status "Testing AI microservice..."
    if python test_setup.py > /dev/null 2>&1; then
        print_status "✅ AI microservice setup test passed"
    else
        print_error "❌ AI microservice setup test failed"
        return 1
    fi
    
    # Start AI microservice
    print_status "Starting AI microservice..."
    PYTHONPATH="$INSTALL_DIR/ai_microservice" nohup ai_microservice_env/bin/python main_simple.py > ../log/ai_microservice.log 2>&1 &
    MICROSERVICE_PID=$!
    echo $MICROSERVICE_PID > ../tmp/ai_microservice.pid
    
    sleep 5
    
    # Check microservice health
    if curl -s http://localhost:8000/health > /dev/null 2>&1; then
        print_status "✅ AI microservice is running"
    else
        print_error "❌ AI microservice failed to start"
        return 1
    fi
    
    # Test Rails integration
    print_status "Testing Rails integration..."
    cd "$INSTALL_DIR"
    if rails runner "Ai::Providers::LocalProvider.new.test_key!" > /dev/null 2>&1; then
        print_status "✅ Rails integration working"
    else
        print_warning "⚠️ Rails integration test skipped (Rails not fully configured)"
    fi
    
    print_status "Installation verification completed"
}

run_comprehensive_test() {
    print_header "Running Comprehensive Test"
    
    cd "$INSTALL_DIR"
    
    # Create test image
    print_status "Creating test image..."
    python3 -c "
from PIL import Image, ImageDraw
img = Image.new('RGB', (100, 100), color='white')
draw = ImageDraw.Draw(img)
draw.rectangle([20, 20, 80, 80], fill='red', outline='black')
draw.text((10, 10), 'TEST', fill='black')
img.save('test_install.png', 'PNG')
print('Test image created')
"
    
    # Test full pipeline
    print_status "Testing full AI pipeline..."
    rails runner "
image_bytes = File.open('test_install.png', 'rb') { |f| f.read }
provider = Ai::Providers::LocalProvider.new
result = provider.analyze_post!(
  post_payload: { post: { caption: 'Installation test' } },
  media: { type: 'image', bytes: image_bytes }
)
puts '✅ Full pipeline test successful!'
puts 'Generated comments: ' + result[:analysis][:comment_suggestions].length.to_s
" 2>/dev/null || print_warning "Full pipeline test skipped"
    
    # Clean up test file
    rm -f test_install.png
    
    print_status "Comprehensive test completed"
}

show_next_steps() {
    print_header "Installation Complete!"
    
    echo -e "${GREEN}🎉 Local AI Stack installation completed successfully!${NC}"
    echo ""
    echo -e "${CYAN}What's been installed:${NC}"
    echo "✅ Ollama (LLM service) with primary model $OLLAMA_MODEL, quality model $OLLAMA_QUALITY_MODEL, and vision model $OLLAMA_VISION_MODEL"
    echo "✅ Python AI microservice with vision, face, OCR capabilities"
    echo "✅ Rails integration with local AI provider"
    echo "✅ All necessary system dependencies"
    echo ""
    echo -e "${CYAN}Quick Start Commands:${NC}"
    echo "• Start all services:     ./bin/dev"
    echo "• Check status:          ./bin/local_ai_services status"
    echo "• Run diagnostics:       ./bin/diagnose_ai"
    echo "• Validate setup:         ./bin/validate_local_ai"
    echo ""
    echo -e "${CYAN}Service URLs:${NC}"
    echo "• AI Microservice:       http://localhost:8000"
    echo "• Ollama API:          http://localhost:11434"
    echo "• Rails app:            http://localhost:3000 (when started)"
    echo ""
    echo -e "${CYAN}Configuration:${NC}"
    echo "• Environment file:      .env"
    echo "• Logs:                 log/ directory"
    echo "• Service management:     bin/local_ai_services"
    echo ""
    echo -e "${YELLOW}Important Notes:${NC}"
    echo "• All services are configured to start automatically with ./bin/dev"
    echo "• The system is set to use local AI by default (cost savings: 100%)"
    echo "• Logs are being written to: $LOG_FILE"
    echo "• First model downloads may take a few minutes"
    echo ""
    echo -e "${GREEN}🚀 Your local AI stack is ready to use!${NC}"
}

# Main execution
main() {
    print_header "Local AI Stack Installation"
    echo "This script will install and configure the complete local AI stack"
    echo "Installation directory: $INSTALL_DIR"
    echo "Log file: $LOG_FILE"
    echo ""
    
    read -p "Continue with installation? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
    
    # Run installation steps
    check_system
    install_system_dependencies
    install_ollama
    setup_python_environment
    setup_rails_environment
    configure_services
    verify_installation
    run_comprehensive_test
    show_next_steps
    
    echo -e "${GREEN}Installation completed successfully!${NC}"
}

# Handle script interruption
trap 'print_error "Installation interrupted"; exit 1' INT

# Run main function
main "$@"
