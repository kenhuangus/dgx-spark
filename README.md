# 🚀 DGX Spark Ollama + WebUI Update Script

**Version 2.4** - Production-ready automated deployment and update script for Ollama and Open WebUI with GPU optimization.

## 📋 Overview

This script provides a robust, production-grade solution for managing Ollama and Open WebUI installations. It intelligently updates both services while preserving your existing models, configurations, and GPU optimizations.

## ✨ Key Features

### 🎯 Smart Update Detection
- **Version checking**: Automatically detects if Ollama or WebUI updates are available
- **Selective updates**: Only updates components that need it, skipping unnecessary restarts
- **Minimal downtime**: Services stay running if already up-to-date

### 🗂️ Model Preservation
- **Automatic model directory detection**: Finds your models in multiple possible locations
- **Zero data loss**: Preserves all existing models during updates
- **Multi-location support**: Checks user home, root, logical volumes, and custom paths
- **Model persistence**: Maintains model files across all updates

### ⚡ GPU Optimization
- **100% GPU offload**: Creates GPU-optimized versions of your models
- **Automatic configuration**: Sets optimal GPU parameters for maximum performance
- **Flash attention**: Enables advanced GPU acceleration features
- **Memory management**: Configures appropriate context windows and thread counts

### 🔄 Intelligent Cleanup
- **Port management**: Automatically cleans up conflicting processes on ports 11434 and 8080
- **Process safety**: Excludes the script itself from cleanup operations
- **Docker management**: Handles container lifecycle properly
- **Lock file protection**: Prevents concurrent executions

### 📊 Comprehensive Monitoring
- **Detailed logging**: All operations logged to `/var/log/ollama-webui-update.log`
- **Status reporting**: Clear feedback on each operation
- **GPU monitoring**: Reports GPU status and utilization
- **Model inventory**: Lists all available models before and after updates

## 🛠️ System Requirements

- **OS**: Ubuntu 24.04 or compatible Linux distribution
- **GPU**: NVIDIA GPU with CUDA support
- **Docker**: Docker Engine with NVIDIA Container Toolkit
- **Privileges**: Root or sudo access
- **Network**: Internet connection for downloading updates

## 📦 Installation

1. **Download the script**:
   ```bash
   curl -O https://github.com/kenhuangus/dgx-spark/ollama-webui-update.sh
   chmod +x ollama-webui-update.sh
   ```

2. **Review the configuration** (optional):
   ```bash
   # Edit these constants if needed:
   # OLLAMA_PORT=11434
   # WEBUI_PORT=8080
   # MAX_LOADED_MODELS=1
   # NUM_GPU_LAYERS=999
   ```

3. **Run the script**:
   ```bash
   sudo ./ollama-webui-update.sh
   ```

## 🚀 Usage

### Basic Usage
```bash
# Run with default settings
sudo ./ollama-webui-update.sh
```

### First-Time Setup
If this is your first time running the script:
1. It will install Ollama and Open WebUI
2. Create a models directory at `~/.ollama/models`
3. Set up GPU optimizations
4. Start both services

### Updating Existing Installation
If you already have Ollama/WebUI installed:
1. Script detects your existing models directory
2. Checks for available updates
3. Updates only what's needed
4. Preserves all your models and data

## 📁 File Locations

| Component | Location | Purpose |
|-----------|----------|---------|
| Models | `~/.ollama/models` | Primary model storage |
| Ollama Log | `/var/log/ollama.log` | Ollama service logs |
| Script Log | `/var/log/ollama-webui-update.log` | Update script logs |
| Lock File | `/tmp/ollama-update.lock` | Prevents concurrent runs |
| Systemd Config | `/etc/systemd/system/ollama.service.d/` | Persistent environment variables |

## 🔧 Configuration

### Environment Variables
The script automatically sets these for optimal performance:

```bash
OLLAMA_MODELS           # Path to models directory
OLLAMA_MAX_LOADED_MODELS=1
OLLAMA_NUM_PARALLEL=1
OLLAMA_FLASH_ATTENTION=1
OLLAMA_SCHED_SPREAD=0
OLLAMA_GPU_LAYERS=999
```

### GPU Optimization
Models are automatically optimized with:
- **num_gpu**: 999 (100% GPU offload)
- **num_thread**: 8
- **num_ctx**: 4096
- **temperature**: 0.7
- **top_p**: 0.9
- **repeat_penalty**: 1.1

## 📊 What the Script Does

### Phase 0: Model Directory Detection
- Searches multiple possible locations for existing models
- Prioritizes user home directory
- Falls back to logical volumes or system locations
- Creates directory if none exists

### Phase 1: Version Checking
- **Ollama**: Checks GitHub API for latest release
- **WebUI**: Compares Docker image digests with remote registry
- Determines which components need updates

### Phase 2: Selective Cleanup
- Stops only services that need updating
- Preserves running services that are up-to-date
- Cleans up ports and processes safely

### Phase 3: Software Updates
- Updates Ollama via official install script
- Pulls latest WebUI Docker image if needed
- Skips updates for components already at latest version

### Phase 4: GPU Configuration
- Detects GPU memory automatically
- Sets environment variables for optimal performance
- Configures Flash Attention and parallel processing

### Phase 5: Model Processing
- Creates GPU-optimized versions of models (suffix: `-maxgpu`)
- Skips if Ollama wasn't updated (existing optimizations preserved)
- Processes all models with maximum GPU offload

### Phase 6: Service Deployment
- Starts or restarts services as needed
- Verifies API endpoints are responding
- Preloads first GPU-optimized model
- Monitors startup progress

### Phase 7: Status Report
- Confirms all services are running
- Reports GPU utilization
- Lists available models
- Provides troubleshooting commands

## 🎯 Access Points

After successful deployment:

- **Ollama API**: `http://localhost:11434`
- **Open WebUI**: `http://localhost:8080`

## 📝 Quick Commands

### Working with Models
```bash
# Pull a new model
OLLAMA_MODELS=~/.ollama/models ollama pull llama3.2

# List all models
OLLAMA_MODELS=~/.ollama/models ollama list

# Run a model (use -maxgpu version for GPU optimization)
OLLAMA_MODELS=~/.ollama/models ollama run llama3.2-maxgpu

# Test a model
curl http://localhost:11434/api/generate -d '{
  "model": "llama3.2-maxgpu",
  "prompt": "Why is the sky blue?"
}'
```

### Monitoring
```bash
# Watch Ollama logs
tail -f /var/log/ollama.log

# Watch WebUI logs
docker logs -f open-webui

# Monitor GPU usage
watch -n 1 nvidia-smi

# Check script log
tail -f /var/log/ollama-webui-update.log
```

### Troubleshooting
```bash
# Restart Ollama
sudo systemctl restart ollama

# Restart WebUI
docker restart open-webui

# Check service status
curl http://localhost:11434/api/tags
curl http://localhost:8080

# Verify models directory
ls -lah ~/.ollama/models/manifests
```

## 🔍 Troubleshooting

### Models Not Showing Up
```bash
# Verify models directory
echo $OLLAMA_MODELS
ls -lah ~/.ollama/models/

# Check Ollama is using correct directory
ps aux | grep ollama
```

### WebUI Can't Connect to Ollama
```bash
# Verify Ollama is running
curl http://localhost:11434/api/tags

# Check Docker network
docker exec open-webui curl http://host.docker.internal:11434/api/tags
```

### GPU Not Being Used
```bash
# Check GPU is available
nvidia-smi

# Verify model has -maxgpu suffix
ollama list | grep maxgpu

# Monitor GPU during inference
watch -n 0.5 nvidia-smi
```

### Port Already in Use
The script automatically handles this, but if you encounter issues:
```bash
# Check what's using the port
sudo lsof -i :11434
sudo lsof -i :8080

# Kill processes manually if needed
sudo fuser -k 11434/tcp
sudo fuser -k 8080/tcp
```

## 🔒 Safety Features

- **Lock file**: Prevents multiple script instances
- **Process exclusion**: Never kills its own process
- **Atomic updates**: Each component updates independently
- **Rollback safe**: Services continue on current version if update fails
- **Data preservation**: Models never deleted during updates

## 🎨 GPU-Optimized Models

Models with `-maxgpu` suffix are optimized for:
- Maximum GPU memory utilization
- Fastest inference times
- Lowest latency responses
- Full GPU offload (999 layers)

Example:
- Original: `llama3.2`
- Optimized: `llama3.2-maxgpu` ✨

## 📈 Performance Tips

1. **Use GPU-optimized models**: Always use the `-maxgpu` versions
2. **Monitor GPU memory**: Adjust `NUM_CTX` if running out of memory
3. **Single model loading**: Default `MAX_LOADED_MODELS=1` prevents memory fragmentation
4. **Flash Attention**: Enabled by default for faster inference

## 🤝 Contributing

Issues and pull requests welcome! Please ensure:
- Changes preserve model data
- Script remains idempotent
- Logging is comprehensive
- Error handling is robust

## 📄 License

MIT License - Feel free to modify and distribute

## 🙏 Acknowledgments

- Ollama team for the excellent LLM runtime
- Open WebUI team for the beautiful interface
- NVIDIA for GPU acceleration support

## 📞 Support

For issues or questions:
1. Check the troubleshooting section above
2. Review logs in `/var/log/`
3. Open an issue with log excerpts

---

**Made with ❤️ for the AI community**
