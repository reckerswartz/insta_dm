# 🚀 Local AI Migration Guide

## Overview
This guide helps you migrate from cloud AI services to local AI processing, reducing costs by **90-100%** while maintaining good accuracy and performance.

## 📋 What's Been Set Up

### ✅ Completed Components

1. **Python AI Microservice** (`ai_microservice/`)
   - **YOLOv8**: Object detection (replaces Google Vision labels)
   - **RetinaFace + InsightFace**: Face detection & recognition (replaces cloud face APIs)
   - **PaddleOCR**: Text extraction (replaces Google Vision text detection)
   - **Whisper**: Speech-to-text (already local, now integrated)
   - **Video Analysis**: Frame sampling + object detection (replaces Video Intelligence)

2. **Local LLM** (Ollama)
   - **Mistral 7B**: Comment generation (replaces Google Gemini)
   - Runs locally on your CPU with 32GB RAM

3. **Vector Storage** (pgvector)
   - Already configured in your database
   - Face embeddings stored locally
   - No more vector DB SaaS costs

4. **Rails Integration**
   - `LocalProvider`: Drop-in replacement for cloud providers
   - `LocalMicroserviceClient`: API client for Python service
   - `OllamaClient`: LLM inference client
   - Updated provider registry with local priority

## 🎯 Cost Savings

| Component | Cloud Cost | Local Cost | Savings |
|-----------|------------|------------|---------|
| Vision API | $$$ | $0 | 100% |
| Speech API | $$$ | $0 | 100% |
| LLM | $$$$$ | $0 | 100% |
| Face Recognition | $$$ | $0 | 100% |
| Vector DB | $$ | $0 | 100% |
| Video AI | $$$ | $0 | 100% |

**Total potential savings: 90-100%**

## 🛠 Quick Start

### 1. Start Everything Together
```bash
# Start Rails + Local AI Services (recommended)
./bin/dev

# Or start AI services separately
./bin/local_ai_services start

# Check status
./bin/local_ai_services status

# Test everything
./bin/validate_local_ai
```

### 2. Configure Rails
```bash
# Run migration to set up provider settings
rails db:migrate:up VERSION=20260215000000

# Set local as default provider
rails runner "
  AiProviderSetting.where(provider: 'local').first_or_create.update(
    config: { ollama_model: 'mistral:7b' },
    enabled: true
  )
  AiProviderSetting.where(provider: 'google_cloud').update_all(enabled: false)
"
```

### 3. Test Integration
```ruby
# In Rails console
provider = Ai::Providers::LocalProvider.new
provider.test_key!
```

### Environment Variables
```bash
# Disable AI auto-start (optional)
START_LOCAL_AI=false ./bin/dev

# Or keep default behavior (AI services start with Rails)
./bin/dev  # AI services start automatically
```

## 📁 File Structure

```
├── ai_microservice/                 # Python AI service
│   ├── main.py                     # FastAPI server
│   ├── services/                   # AI modules
│   │   ├── vision_service.py       # YOLOv8
│   │   ├── face_service.py         # RetinaFace + InsightFace
│   │   ├── ocr_service.py          # PaddleOCR
│   │   ├── video_service.py        # Video analysis
│   │   └── whisper_service.py      # Whisper
│   ├── requirements.txt            # Python dependencies
│   └── setup.sh                   # Setup script
├── app/services/ai/
│   ├── local_microservice_client.rb # API client
│   ├── ollama_client.rb            # LLM client
│   ├── local_engagement_comment_generator.rb
│   └── providers/
│       └── local_provider.rb       # Rails provider
├── bin/
│   ├── local_ai_services           # Service management
│   └── validate_local_ai          # Testing script
└── config/
    └── local_ai.env.example       # Environment variables
```

## ⚙️ Configuration

### Environment Variables
Copy `config/local_ai.env.example` to `.env` and customize:

```bash
# Service URLs
LOCAL_AI_SERVICE_URL=http://localhost:8000
OLLAMA_URL=http://localhost:11434

# Models
OLLAMA_MODEL=mistral:7b
WHISPER_MODEL=base

# Performance
AI_REQUEST_TIMEOUT=120
VIDEO_SAMPLE_RATE=2
```

### Service Management
```bash
# Start with Rails (recommended)
./bin/dev

# Start AI services separately
./bin/local_ai_services start

# Stop services  
./bin/local_ai_services stop

# Restart services
./bin/local_ai_services restart

# View logs
./bin/local_ai_services logs

# Test connectivity
./bin/local_ai_services test

# Disable AI auto-start
START_LOCAL_AI=false ./bin/dev
```

## 🧪 Testing & Validation

### Automated Testing
```bash
# Run comprehensive tests
./bin/validate_local_ai
```

### Manual Testing
```ruby
# Test image analysis
provider = Ai::Providers::LocalProvider.new
result = provider.analyze_post!(
  post_payload: { post: { caption: "test" } },
  media: { type: "image", bytes: image_bytes }
)

# Test LLM generation
client = Ai::OllamaClient.new
response = client.generate(
  model: "mistral:7b",
  prompt: "Generate a comment for this photo"
)
```

## 🔄 Migration Strategy

### Phase 1: Parallel Testing (Recommended)
1. Keep cloud providers enabled
2. Add local provider with highest priority
3. Monitor accuracy and performance
4. Compare costs

### Phase 2: Full Migration
1. Disable cloud providers
2. Run on local-only
3. Monitor system performance

### Phase 3: Optimization
1. Fine-tune model parameters
2. Optimize video sampling rates
3. Cache embeddings and results

## 📊 Performance Expectations

### Your Hardware: Intel Ultra 7 + 32GB RAM

| Task | Expected Performance | Notes |
|------|-------------------|-------|
| Image Analysis | 2-5 seconds | YOLOv8 nano model |
| Face Recognition | 1-3 seconds | InsightFace CPU mode |
| OCR | 2-4 seconds | PaddleOCR |
| Speech-to-Text | 5-15 seconds | Whisper base model |
| LLM Generation | 10-30 seconds | Mistral 7B on CPU |
| Video Analysis | 30-120 seconds | Depends on length |

### Optimization Tips
- Use video sampling (every 2 seconds)
- Cache face embeddings
- Process images in batches
- Use quantized models (already configured)

## 🚨 Troubleshooting

### Common Issues

**Service won't start:**
```bash
# Check logs
./bin/local_ai_services logs

# Check dependencies
cd ai_microservice && python -m pip install -r requirements.txt
```

**Out of memory:**
- Reduce concurrent requests: `AI_CONCURRENT_REQUESTS=1`
- Use smaller models: `OLLAMA_MODEL=mistral:7b` → `OLLAMA_MODEL=phi3:mini`

**Slow performance:**
- Increase video sample rate: `VIDEO_SAMPLE_RATE=5`
- Use faster Whisper model: `WHISPER_MODEL=tiny`

**Accuracy issues:**
- Try larger models: `OLLAMA_MODEL=mistral:7b` → `OLLAMA_MODEL=llama3:8b`
- Adjust face recognition threshold: `FACE_RECOGNITION_THRESHOLD=0.7`

## 📈 Monitoring

### Rails Metrics
```ruby
# Check provider usage
AiProviderSetting.where(enabled: true).count

# Monitor API calls
AiApiCall.where(provider: 'local').group(:operation).count

# Track costs (should be $0)
AiApiCall.where(provider: 'local').sum(:request_units)
```

### System Metrics
```bash
# CPU usage
top -p $(pgrep -f "python main.py")
top -p $(pgrep ollama)

# Memory usage
free -h

# Service health
curl http://localhost:8000/health
curl http://localhost:11434/api/tags
```

## 🎉 Success Criteria

✅ **Cost Reduction**: 90-100% savings on AI services  
✅ **Performance**: Acceptable response times (< 30 seconds for most tasks)  
✅ **Accuracy**: Comparable results to cloud services  
✅ **Reliability**: Services run consistently without crashes  
✅ **Maintainability**: Easy to update and scale  

## � **Next Steps**

1. **Start everything together**: `./bin/dev`
2. **Run tests**: `./bin/validate_local_ai`
3. **Test in Rails**: `Ai::Providers::LocalProvider.new.test_key!`
4. **Monitor costs**: Should drop to near-zero

**The `./bin/dev` command now automatically starts:**
- ✅ Rails web server
- ✅ Background jobs (Sidekiq)
- ✅ Ollama (LLM service)
- ✅ AI Microservice (Vision/OCR/Whisper)

**To disable AI auto-start:** `START_LOCAL_AI=false ./bin/dev`

## 🔄 Rollback Plan

To revert to cloud services:

```bash
# Disable local provider
rails runner "AiProviderSetting.where(provider: 'local').update_all(enabled: false)"

# Enable cloud providers
rails runner "AiProviderSetting.where(provider: 'google_cloud').update_all(enabled: true)"

# Stop local services
./bin/local_ai_services stop
```

---

**🎯 You're now ready to run AI processing locally with massive cost savings!**
