# Local AI Stack - Quick Installation Guide

## 🚀 One-Command Installation

Run this single command to install and configure the entire local AI stack:

```bash
./install_local_ai_stack.sh
```

## 📋 What This Script Does

### **System Setup**
- ✅ Checks Linux system compatibility
- ✅ Installs system dependencies (Python 3.12, build tools, libraries)
- ✅ Installs AI/ML libraries (OpenCV, FFmpeg, etc.)
- ✅ Verifies hardware requirements (RAM, disk space)

### **AI Services Installation**
- ✅ Installs Ollama (LLM service)
- ✅ Pulls Mistral 7B model
- ✅ Sets up Python virtual environment
- ✅ Installs all Python packages (FastAPI, YOLOv8, etc.)

### **Rails Integration**
- ✅ Installs Rails dependencies
- ✅ Runs database migrations
- ✅ Configures local AI provider as default
- ✅ Disables cloud providers

### **Configuration & Verification**
- ✅ Creates necessary directories
- ✅ Sets up environment variables
- ✅ Starts all services
- ✅ Runs comprehensive tests
- ✅ Verifies full pipeline

## 🎯 After Installation

### **Services Running**
- **AI Microservice**: http://localhost:8000
- **Ollama LLM**: http://localhost:11434
- **Rails App**: http://localhost:3000 (when started)

### **Quick Commands**
```bash
# Start everything
./bin/dev

# Check service status
./bin/local_ai_services status

# Run diagnostics
./bin/diagnose_ai

# Validate setup
./bin/validate_local_ai
```

## 📊 System Requirements

### **Minimum Requirements**
- **OS**: Linux (Ubuntu 20.04+)
- **RAM**: 16GB (8GB minimum)
- **Storage**: 5GB free
- **Architecture**: x86_64

### **Recommended Requirements**
- **RAM**: 32GB+ (for optimal performance)
- **CPU**: Multi-core processor
- **Storage**: 10GB+ free

## 🔧 Customization

### **Environment Variables**
Edit `.env` file after installation:

```bash
# Change LLM model
OLLAMA_MODEL=llama3:8b

# Adjust performance
AI_REQUEST_TIMEOUT=120
VIDEO_SAMPLE_RATE=2

# Service URLs
LOCAL_AI_SERVICE_URL=http://localhost:8000
OLLAMA_URL=http://localhost:11434
```

### **Model Options**
```bash
# Available models (run after installation)
ollama list

# Pull additional models
ollama pull llama3:8b
ollama pull phi3:mini
```

## 🚨 Troubleshooting

### **Common Issues**

**Installation fails:**
```bash
# Check logs
cat installation.log

# Re-run with verbose output
bash -x ./install_local_ai_stack.sh
```

**Services won't start:**
```bash
# Check status
./bin/local_ai_services status

# View logs
./bin/local_ai_services logs

# Restart services
./bin/local_ai_services restart
```

**Performance issues:**
```bash
# Check system resources
htop
free -h
df -h

# Reduce concurrent requests
export AI_CONCURRENT_REQUESTS=1
```

**Model issues:**
```bash
# Re-download model
ollama pull mistral:7b

# Check available models
ollama list
```

## 📈 Performance Expectations

### **Processing Times**
- **Image Analysis**: 2-5 seconds
- **Face Recognition**: 1-3 seconds
- **OCR**: 2-4 seconds
- **Comment Generation**: 10-30 seconds
- **Video Analysis**: 30-120 seconds

### **Cost Impact**
- **Cloud AI Costs**: $0.00 (100% savings)
- **Local Processing**: Free (after initial setup)
- **Hardware Usage**: CPU/RAM intensive during processing

## 🔄 Updates & Maintenance

### **Update Models**
```bash
# Update Ollama
ollama pull mistral:7b

# Update Python packages
cd ai_microservice
source ai_microservice_env/bin/activate
pip install --upgrade -r requirements.txt
```

### **Backup Configuration**
```bash
# Backup environment
cp .env .env.backup

# Backup logs
tar -czf logs_backup.tar.gz log/
```

## 🎉 Success Criteria

After running the script, you should have:

✅ **All services running** without errors  
✅ **Full AI pipeline** working (image → analysis → comments)  
✅ **100% cost reduction** compared to cloud services  
✅ **Rails integration** seamless and functional  
✅ **Performance** acceptable for your hardware  

## 🆘 Support

If you encounter issues:

1. **Check the installation log**: `cat installation.log`
2. **Run diagnostics**: `./bin/diagnose_ai`
3. **Check service logs**: `./bin/local_ai_services logs`
4. **Verify setup**: `./bin/validate_local_ai`

---

**🚀 Ready to automate your entire local AI stack setup! Run `./install_local_ai_stack.sh` to get started.**
