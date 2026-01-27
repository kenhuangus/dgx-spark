```bash
#!/bin/bash
# 🚀 PRODUCTION DGX Spark Ollama + WebUI Update Script
# Version: 2.3 - Optimized for ~/.ollama/models/
# Features: Nuclear cleanup, 100% GPU offload, persistent model storage

set -u  # Only fail on undefined variables, NOT on command failures
shopt -s nullglob  # Handle empty globs gracefully

# ========== CRITICAL CONFIGURATION ==========
readonly SCRIPT_PID=$$
readonly OLLAMA_PORT=11434
readonly WEBUI_PORT=8080
readonly MAX_LOADED_MODELS=1
readonly NUM_GPU_LAYERS=999
readonly NUM_THREADS=8
readonly NUM_CTX=4096
readonly LOG_FILE="/var/log/ollama-webui-update.log"
readonly LOCK_FILE="/tmp/ollama-update.lock"
readonly MAX_RETRIES=3
readonly TIMEOUT_SECONDS=30

# Model directory detection (will be set dynamically)
MODELS_DIR=""
OLLAMA_MODELS_ENV=""

# ========== DISABLE ALL TRAPS - PREVENT EARLY EXIT ==========
trap '' INT TERM QUIT HUP PIPE EXIT

# ========== LOGGING FUNCTIONS ==========
log() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" || echo "[$(date)] $1"
}

debug() { 
    echo "[DEBUG $$] $1" | tee -a "$LOG_FILE" 2>/dev/null || echo "[DEBUG] $1"
}

warn() { 
    echo "[WARN] $1" | tee -a "$LOG_FILE" 2>/dev/null || echo "[WARN] $1"
}

error_continue() {
    echo "⚠️  ERROR (continuing): $1" | tee -a "$LOG_FILE" 2>/dev/null || echo "[ERROR] $1"
}

success() {
    echo "✅ $1" | tee -a "$LOG_FILE" 2>/dev/null || echo "[SUCCESS] $1"
}

# ========== MODEL DIRECTORY DETECTION ==========
detect_models_directory() {
    log "=== Detecting Ollama models directory ==="
    
    # Get current user's home directory (handle both sudo and non-sudo)
    local user_home
    if [ -n "${SUDO_USER:-}" ]; then
        user_home=$(eval echo ~"${SUDO_USER}")
    else
        user_home="${HOME}"
    fi
    
    debug "Current user: ${USER:-unknown}, Home: $user_home"
    
    # Check if OLLAMA_MODELS is already set
    local existing_models_path="${OLLAMA_MODELS:-}"
    
    # Priority order for model directory detection:
    # 1. User's home directory (HIGHEST PRIORITY since you confirmed models are here)
    # 2. Environment variable
    # 3. Root home
    # 4. System locations
    local potential_dirs=(
        "$user_home/.ollama/models"        # User home (HIGHEST PRIORITY)
        "$existing_models_path"             # Environment variable
        "/root/.ollama/models"              # Root user
        "/home/${SUDO_USER:-}/.ollama/models"  # Original user if using sudo
        "/mnt/ollama/models"                # Logical volume mount
        "/var/lib/ollama/models"            # System-wide installation
        "/opt/ollama/models"                # Alternative system location
        "/data/ollama/models"               # Data partition
    )
    
    # Check each potential directory
    for dir in "${potential_dirs[@]}"; do
        # Skip empty strings
        if [ -z "$dir" ]; then
            continue
        fi
        
        # Expand tilde if present
        dir=$(eval echo "$dir")
        
        if [ -d "$dir" ]; then
            # Check if it contains actual model data
            if [ -d "$dir/manifests" ] || [ -d "$dir/blobs" ] || [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
                MODELS_DIR="$dir"
                log "✅ Found existing models directory: $MODELS_DIR"
                
                # Count existing models
                local model_count=0
                local manifest_count=0
                local blob_count=0
                
                if [ -d "$MODELS_DIR/manifests" ]; then
                    manifest_count=$(find "$MODELS_DIR/manifests" -type f 2>/dev/null | wc -l)
                    model_count=$manifest_count
                fi
                
                if [ -d "$MODELS_DIR/blobs" ]; then
                    blob_count=$(find "$MODELS_DIR/blobs" -type f 2>/dev/null | wc -l)
                fi
                
                log "📊 Found $manifest_count model manifests and $blob_count blob files"
                
                # Set environment variable for Ollama
                export OLLAMA_MODELS="$MODELS_DIR"
                OLLAMA_MODELS_ENV="$MODELS_DIR"
                
                return 0
            fi
        fi
    done
    
    # If no existing directory found, check for mounted logical volumes
    log "No models found in standard locations, checking logical volumes..."
    local lv_mounts
    lv_mounts=$(df -h 2>/dev/null | grep -E '/dev/(mapper|vg)' | awk '{print $6}' || true)
    
    if [ -n "$lv_mounts" ]; then
        log "Found logical volume mounts:"
        while IFS= read -r mount; do
            [ -z "$mount" ] && continue
            log "  - $mount"
            # Check if any mount point contains ollama data
            if [ -d "$mount/ollama/models" ] && { [ -d "$mount/ollama/models/manifests" ] || [ -d "$mount/ollama/models/blobs" ]; }; then
                MODELS_DIR="$mount/ollama/models"
                log "✅ Found models on logical volume: $MODELS_DIR"
                export OLLAMA_MODELS="$MODELS_DIR"
                OLLAMA_MODELS_ENV="$MODELS_DIR"
                return 0
            fi
        done <<< "$lv_mounts"
    fi
    
    # Fallback: Use user's home directory (since you confirmed models are there)
    local best_dir="$user_home/.ollama/models"
    
    log "⚠️  No existing models found, will use: $best_dir"
    log "📝 Note: You can pull models after script completes"
    
    mkdir -p "$best_dir" 2>/dev/null || {
        best_dir="/root/.ollama/models"
        mkdir -p "$best_dir" || {
            best_dir="/tmp/ollama/models"
            mkdir -p "$best_dir"
        }
    }
    
    MODELS_DIR="$best_dir"
    export OLLAMA_MODELS="$MODELS_DIR"
    OLLAMA_MODELS_ENV="$MODELS_DIR"
    
    log "✅ Models directory set to: $MODELS_DIR"
    return 0
}

# ========== VERIFY AND LIST EXISTING MODELS ==========
list_existing_models() {
    log "=== Checking existing models ==="
    
    if [ ! -d "$MODELS_DIR" ]; then
        warn "Models directory does not exist: $MODELS_DIR"
        log "Creating directory: $MODELS_DIR"
        mkdir -p "$MODELS_DIR" 2>/dev/null || true
        return 1
    fi
    
    log "Models directory: $MODELS_DIR"
    
    # Check directory permissions
    if [ -r "$MODELS_DIR" ]; then
        local dir_size
        dir_size=$(du -sh "$MODELS_DIR" 2>/dev/null | awk '{print $1}' || echo 'unknown')
        log "Directory size: $dir_size"
    else
        warn "Cannot read directory: $MODELS_DIR (permission denied)"
        return 1
    fi
    
    # Check for model files
    if [ -d "$MODELS_DIR/manifests" ]; then
        local manifest_count
        manifest_count=$(find "$MODELS_DIR/manifests" -type f 2>/dev/null | wc -l)
        log "Manifest files: $manifest_count"
        
        if [ "$manifest_count" -gt 0 ]; then
            log "Existing model manifests:"
            find "$MODELS_DIR/manifests" -type f 2>/dev/null | head -20 | while read -r manifest; do
                # Extract model name from path
                local model_path="${manifest#$MODELS_DIR/manifests/}"
                log "  - $model_path"
            done
        else
            log "No model manifests found (empty directory)"
        fi
    else
        log "No manifests directory found"
    fi
    
    if [ -d "$MODELS_DIR/blobs" ]; then
        local blob_count
        local blob_size
        blob_count=$(find "$MODELS_DIR/blobs" -type f 2>/dev/null | wc -l)
        blob_size=$(du -sh "$MODELS_DIR/blobs" 2>/dev/null | awk '{print $1}' || echo 'unknown')
        log "Blob files: $blob_count (total size: $blob_size)"
    else
        log "No blobs directory found"
    fi
    
    return 0
}

# ========== LOCK FILE MANAGEMENT ==========
acquire_lock() {
    local max_wait=60
    local waited=0
    
    while [ -f "$LOCK_FILE" ]; do
        if [ $waited -ge $max_wait ]; then
            warn "Lock file exists after ${max_wait}s, removing forcefully"
            rm -f "$LOCK_FILE" 2>/dev/null || true
            break
        fi
        
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
            warn "Stale lock file (PID $lock_pid dead), removing"
            rm -f "$LOCK_FILE" 2>/dev/null || true
            break
        fi
        
        debug "Waiting for lock... ($waited/$max_wait)"
        sleep 2
        waited=$((waited + 2))
    done
    
    echo $$ > "$LOCK_FILE" 2>/dev/null || {
        warn "Cannot create lock file, continuing anyway"
    }
}

release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

# ========== SAFE COMMAND EXECUTION ==========
safe_exec() {
    local cmd="$1"
    local description="${2:-command}"
    local max_attempts="${3:-$MAX_RETRIES}"
    
    for attempt in $(seq 1 $max_attempts); do
        debug "Executing: $description (attempt $attempt/$max_attempts)"
        if eval "$cmd" 2>&1 | tee -a "$LOG_FILE"; then
            return 0
        fi
        [ $attempt -lt $max_attempts ] && sleep 2
    done
    
    warn "Failed after $max_attempts attempts: $description"
    return 1
}

# ========== PORT MANAGEMENT ==========
kill_port_processes() {
    local port=$1
    local description="${2:-port $port}"
    
    debug "Killing processes on $description"
    
    # Method 1: fuser with sudo
    sudo fuser -k -n tcp "$port" 2>/dev/null || true
    sleep 1
    sudo fuser -k -9 -n tcp "$port" 2>/dev/null || true
    
    # Method 2: lsof
    if command -v lsof >/dev/null 2>&1; then
        local pids
        pids=$(sudo lsof -ti tcp:"$port" 2>/dev/null || true)
        if [ -n "$pids" ]; then
            echo "$pids" | xargs -r sudo kill -9 2>/dev/null || true
        fi
    fi
    
    # Method 3: ss/netstat parsing
    local netstat_pids
    netstat_pids=$(sudo ss -tulnp 2>/dev/null | grep ":$port " | grep -oP 'pid=\K[0-9]+' || true)
    if [ -n "$netstat_pids" ]; then
        echo "$netstat_pids" | xargs -r sudo kill -9 2>/dev/null || true
    fi
    
    sleep 1
}

verify_port_free() {
    local port=$1
    local max_checks=5
    
    for i in $(seq 1 $max_checks); do
        if timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
            [ $i -eq $max_checks ] && return 1
            debug "Port $port still occupied, retry $i/$max_checks"
            kill_port_processes "$port"
            sleep 2
        else
            return 0
        fi
    done
    
    return 1
}

# ========== PROCESS MANAGEMENT ==========
kill_processes_safe() {
    local pattern="$1"
    local exclude_pid="$2"
    local description="${3:-processes}"
    
    debug "Killing $description (excluding PID $exclude_pid)"
    
    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null | grep -v "^${exclude_pid}$" || true)
    
    if [ -z "$pids" ]; then
        debug "No $description found"
        return 0
    fi
    
    echo "$pids" | while read -r pid; do
        if [ -n "$pid" ] && [ "$pid" != "$exclude_pid" ]; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    
    sleep 3
    
    # Force kill remaining
    pids=$(pgrep -f "$pattern" 2>/dev/null | grep -v "^${exclude_pid}$" || true)
    echo "$pids" | while read -r pid; do
        if [ -n "$pid" ] && [ "$pid" != "$exclude_pid" ]; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    
    sleep 1
}

# ========== DOCKER MANAGEMENT ==========
cleanup_docker() {
    debug "Docker cleanup starting"
    
    # Stop specific container
    docker stop open-webui 2>/dev/null || true
    docker rm -f open-webui 2>/dev/null || true
    
    # Stop all running containers (safety limit: 10)
    local containers
    containers=$(docker ps -q 2>/dev/null | head -10 || true)
    if [ -n "$containers" ]; then
        echo "$containers" | xargs -r docker stop 2>/dev/null || true
        echo "$containers" | xargs -r docker rm -f 2>/dev/null || true
    fi
    
    # Prune stopped containers
    docker container prune -f 2>/dev/null || true
    
    success "Docker cleanup complete"
}

# ========== SYSTEM CACHE MANAGEMENT ==========
clear_system_cache() {
    debug "Clearing system caches (preserving model data)"
    
    # Drop caches safely
    sync 2>/dev/null || true
    sudo sh -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null || true
    
    # Clear shared memory if it exists (but not model data)
    if [ -d "/dev/shm" ]; then
        sudo find /dev/shm -type f -name "ollama*" -delete 2>/dev/null || true
    fi
    
    success "System cache cleared"
}

# ========== MAIN EXECUTION ==========
main() {
    log "🚀 === DGX Spark Ollama/WebUI Update Script v2.3 (PID: $$) ==="
    log "Start time: $(date)"
    
    # Acquire lock
    acquire_lock
    
    # ========== PHASE 0: DETECT MODELS DIRECTORY ==========
    detect_models_directory
    list_existing_models
    
    # Verify models directory is accessible
    if [ ! -w "$MODELS_DIR" ]; then
        warn "Models directory not writable: $MODELS_DIR"
        log "Attempting to fix permissions..."
        sudo chown -R "$(whoami):$(whoami)" "$MODELS_DIR" 2>/dev/null || true
    fi
    
    # ========== PHASE 1: VERSION CHECK ==========
    log "=== PHASE 1: Version check ==="
    
    # Check current Ollama version
    local current_ollama_version=""
    local needs_ollama_update=false
    
    if command -v ollama >/dev/null 2>&1; then
        current_ollama_version=$(ollama --version 2>/dev/null | grep -oP 'ollama version is \K[0-9.]+' || echo "unknown")
        log "Current Ollama version: $current_ollama_version"
        
        # Get latest version from GitHub API
        log "Checking for latest Ollama version..."
        local latest_ollama_version
        latest_ollama_version=$(curl -s https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null | grep -oP '"tag_name": "v\K[0-9.]+' || echo "")
        
        if [ -n "$latest_ollama_version" ]; then
            log "Latest Ollama version: $latest_ollama_version"
            
            if [ "$current_ollama_version" != "$latest_ollama_version" ] && [ "$current_ollama_version" != "unknown" ]; then
                log "⚠️  Ollama update available: $current_ollama_version → $latest_ollama_version"
                needs_ollama_update=true
            else
                success "✓ Ollama is already at latest version ($current_ollama_version)"
            fi
        else
            warn "Could not determine latest Ollama version, will attempt update"
            needs_ollama_update=true
        fi
    else
        log "Ollama not found, will install"
        needs_ollama_update=true
    fi
    
    # Check WebUI version
    log "Checking WebUI (Open WebUI) version..."
    local current_webui_version=""
    local needs_webui_update=false
    
    # Check if container exists
    if docker inspect open-webui >/dev/null 2>&1; then
        # Get the full image ID (sha256 hash) of current container
        local current_image_id
        current_image_id=$(docker inspect open-webui --format='{{.Image}}' 2>/dev/null || echo "")
        
        if [ -n "$current_image_id" ]; then
            log "Current WebUI image ID: ${current_image_id:0:12}..."
            
            # Try to pull the latest image silently and check if it actually updates
            log "Checking for WebUI updates (quick pull check)..."
            local pull_output
            pull_output=$(docker pull ghcr.io/open-webui/open-webui:main 2>&1)
            
            # Check if the pull actually downloaded new layers or if it was already up to date
            if echo "$pull_output" | grep -q "Image is up to date"; then
                success "✓ WebUI is up to date"
                needs_webui_update=false
            elif echo "$pull_output" | grep -q "Downloaded newer image\|Digest:"; then
                # Get the new image ID after pull
                local new_image_id
                new_image_id=$(docker images ghcr.io/open-webui/open-webui:main --format '{{.ID}}' 2>/dev/null | head -1 || echo "")
                
                if [ -n "$new_image_id" ] && [ "$current_image_id" != "$new_image_id" ]; then
                    log "⚠️  WebUI update available (image changed)"
                    log "   Current: ${current_image_id:0:12}..."
                    log "   New:     ${new_image_id:0:12}..."
                    needs_webui_update=true
                else
                    # Pull completed but image ID didn't change (shouldn't happen, but handle it)
                    success "✓ WebUI is up to date (same image ID after pull)"
                    needs_webui_update=false
                fi
            else
                # Pull had some other output, be conservative and don't update
                warn "Unable to determine WebUI update status from pull output"
                log "Pull output: $pull_output"
                needs_webui_update=false
            fi
        else
            warn "Cannot determine current WebUI image ID"
            needs_webui_update=true
        fi
    else
        log "WebUI container not found, will create"
        needs_webui_update=true
    fi
    
    # ========== PHASE 2: SELECTIVE CLEANUP ==========
    # Only cleanup services that need updates
    log "=== PHASE 2: Selective cleanup ==="
    
    if [ "$needs_ollama_update" = true ]; then
        log "Preparing to update Ollama - stopping Ollama service..."
        
        # Stop Ollama systemd service
        sudo systemctl stop ollama 2>/dev/null || true
        sleep 1
        
        # Kill Ollama processes (EXCLUDE THIS SCRIPT)
        kill_processes_safe "ollama" "$SCRIPT_PID" "Ollama processes"
        
        # Clean Ollama port
        kill_port_processes "$OLLAMA_PORT" "Ollama port"
        
        success "Ollama stopped for update"
    else
        log "⏭️  Ollama cleanup skipped (no update needed)"
    fi
    
    if [ "$needs_webui_update" = true ]; then
        log "Preparing to update WebUI - stopping WebUI container..."
        
        # Stop and remove WebUI container
        docker stop open-webui 2>/dev/null || true
        docker rm -f open-webui 2>/dev/null || true
        
        # Clean WebUI port
        kill_port_processes "$WEBUI_PORT" "WebUI port"
        
        success "WebUI stopped for update"
    else
        log "⏭️  WebUI cleanup skipped (no update needed)"
    fi
    
    # Only do system cache cleanup if any update is needed
    if [ "$needs_ollama_update" = true ] || [ "$needs_webui_update" = true ]; then
        clear_system_cache
        log "System cache cleared"
    fi
    
    # ========== PHASE 3: PERFORM UPDATES ==========
    log "=== PHASE 3: Update software (if needed) ==="
    
    # Update Ollama if needed
    if [ "$needs_ollama_update" = true ]; then
        log "Updating Ollama..."
        if curl -fsSL https://ollama.com/install.sh 2>/dev/null | sh 2>&1 | tee -a "$LOG_FILE"; then
            local new_version
            new_version=$(ollama --version 2>/dev/null | grep -oP 'ollama version is \K[0-9.]+' || echo "unknown")
            success "Ollama updated: $current_ollama_version → $new_version"
        else
            warn "Ollama update failed - continuing with current version"
        fi
    else
        log "⏭️  Ollama update skipped (already latest)"
    fi
    
    # WebUI update happens in Phase 6 (docker pull + restart)
    if [ "$needs_webui_update" = true ]; then
        log "WebUI will be updated in Phase 6"
    else
        log "⏭️  WebUI update skipped (already latest)"
    fi
    
    # ========== PHASE 4: GPU OPTIMIZATION CONFIGURATION ==========
    log "=== PHASE 4: GPU offload configuration ==="
    
    # Set environment variables (including models directory)
    export OLLAMA_MODELS="$MODELS_DIR"
    export OLLAMA_MAX_LOADED_MODELS=$MAX_LOADED_MODELS
    export OLLAMA_NUM_PARALLEL=1
    export OLLAMA_FLASH_ATTENTION=1
    export OLLAMA_SCHED_SPREAD=0
    export OLLAMA_GPU_LAYERS=$NUM_GPU_LAYERS
    
    log "🗂️  OLLAMA_MODELS set to: $MODELS_DIR"
    
    # Detect GPU memory
    if command -v nvidia-smi >/dev/null 2>&1; then
        local gpu_mem
        gpu_mem=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | awk '{print int($1/1024)}' || echo "32")
        export OLLAMA_GPUMEMORY="${gpu_mem}G"
        log "Detected GPU memory: ${gpu_mem}GB"
    fi
    
    # ========== PHASE 5: MODEL PROCESSING ==========
    log "=== PHASE 5: Processing models for GPU offload ==="
    
    # Skip model processing if Ollama wasn't updated
    if [ "$needs_ollama_update" = false ]; then
        log "⏭️  Skipping model processing (Ollama was not updated)"
        log "   Existing GPU-optimized models will be used"
    else
        log "Processing models due to Ollama update..."
        
        # Start temporary Ollama instance for model processing
        log "Starting temporary Ollama for model processing..."
        kill_port_processes "$OLLAMA_PORT"
        sleep 2
        
        # Start with explicit models directory
        OLLAMA_MODELS="$MODELS_DIR" nohup ollama serve > /tmp/ollama-temp.log 2>&1 &
        local temp_ollama_pid=$!
        sleep 10
        
        # Wait for Ollama to be ready
        local ready=0
        for i in $(seq 1 30); do
            if curl -s "http://localhost:$OLLAMA_PORT/api/tags" >/dev/null 2>&1; then
                ready=1
                break
            fi
            debug "Waiting for Ollama API... ($i/30)"
            sleep 2
        done
        
        if [ $ready -eq 0 ]; then
            warn "Ollama API not responding after 30s"
            log "Check temporary log: tail -f /tmp/ollama-temp.log"
        else
            success "Ollama API is ready"
            
            # List available models
            log "Listing available models from $MODELS_DIR:"
            local model_list_output
            model_list_output=$(OLLAMA_MODELS="$MODELS_DIR" ollama list 2>&1 || echo "")
            
            if [ -n "$model_list_output" ]; then
                echo "$model_list_output" | tee -a "$LOG_FILE"
            else
                log "No output from 'ollama list' command"
            fi
            
            # Process models
            local models
            models=$(OLLAMA_MODELS="$MODELS_DIR" ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -v "maxgpu" || true)
            local model_count=0
            
            if [ -z "$models" ]; then
                log "⚠️  No models found to optimize."
                log ""
                log "📝 To pull models, use:"
                log "   OLLAMA_MODELS=$MODELS_DIR ollama pull llama3.2"
                log "   OLLAMA_MODELS=$MODELS_DIR ollama pull mistral"
            else
                log "Processing models for GPU optimization..."
                echo "$models" | while read -r model; do
                    [ -z "$model" ] && continue
                    
                    local base_model="${model#library/}"
                    local new_name="${base_model}-maxgpu"
                    
                    # Skip if maxgpu version already exists
                    if OLLAMA_MODELS="$MODELS_DIR" ollama list 2>/dev/null | grep -q "$new_name"; then
                        log "⏭️  Skipping $base_model (maxgpu version exists)"
                        continue
                    fi
                    
                    debug "Processing: $base_model → $new_name"
                    
                    cat > /tmp/Modelfile.$$ << EOF
FROM $base_model
PARAMETER num_gpu $NUM_GPU_LAYERS
PARAMETER num_thread $NUM_THREADS
PARAMETER num_ctx $NUM_CTX
PARAMETER temperature 0.7
PARAMETER top_p 0.9
PARAMETER repeat_penalty 1.1
EOF
                    
                    if timeout 120 OLLAMA_MODELS="$MODELS_DIR" ollama create "$new_name" -f /tmp/Modelfile.$$ 2>&1 | tee -a "$LOG_FILE"; then
                        success "$base_model → $new_name (100% GPU)"
                        model_count=$((model_count + 1))
                    else
                        warn "Failed to create $new_name (timeout or error)"
                    fi
                    
                    rm -f /tmp/Modelfile.$$ 2>/dev/null || true
                    sleep 2
                done
                
                if [ "$model_count" -gt 0 ]; then
                    success "Created $model_count GPU-optimized models"
                else
                    log "No new GPU-optimized models created"
                fi
            fi
        fi
        
        # Stop temporary Ollama
        log "Stopping temporary Ollama instance..."
        kill "$temp_ollama_pid" 2>/dev/null || true
        sleep 3
        kill -9 "$temp_ollama_pid" 2>/dev/null || true
        sleep 2
    fi
    
    # ========== PHASE 6: ENSURE SERVICES ARE RUNNING ==========
    log "=== PHASE 6: Ensure services are running ==="
    
    # ========== OLLAMA SERVICE ==========
    # Check if Ollama needs to be started/restarted
    local ollama_needs_start=false
    
    if [ "$needs_ollama_update" = true ]; then
        # Ollama was updated, must restart
        ollama_needs_start=true
        log "Ollama needs restart (was updated)"
    else
        # Check if Ollama is already running and responding
        local ollama_running=false
        if pgrep -f "ollama serve" >/dev/null 2>&1; then
            log "Ollama process found, checking API..."
            if curl -s "http://localhost:$OLLAMA_PORT/api/tags" >/dev/null 2>&1; then
                ollama_running=true
                success "✓ Ollama is already running and responding"
            else
                warn "Ollama process exists but API not responding, will restart"
                ollama_needs_start=true
            fi
        else
            log "Ollama process not found, will start"
            ollama_needs_start=true
        fi
    fi
    
    # Start or restart Ollama if needed
    if [ "$ollama_needs_start" = true ]; then
        log "Starting Ollama service..."
        
        # Final port cleanup for Ollama
        kill_port_processes "$OLLAMA_PORT"
        sleep 2
        
        # Start Ollama daemon with persistent models directory
        log "Starting Ollama daemon with models at: $MODELS_DIR"
        
        # Create systemd drop-in to set OLLAMA_MODELS permanently
        sudo mkdir -p /etc/systemd/system/ollama.service.d 2>/dev/null || true
        sudo tee /etc/systemd/system/ollama.service.d/models.conf > /dev/null << EOF
[Service]
Environment="OLLAMA_MODELS=$MODELS_DIR"
Environment="OLLAMA_MAX_LOADED_MODELS=$MAX_LOADED_MODELS"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
EOF
        
        sudo systemctl daemon-reload 2>/dev/null || true
        
        # Start via nohup for immediate use
        OLLAMA_MODELS="$MODELS_DIR" nohup ollama serve > /var/log/ollama.log 2>&1 &
        local ollama_pid=$!
        
        success "Ollama started (PID: $ollama_pid)"
        
        # Wait for Ollama to be ready
        log "Waiting for Ollama API..."
        local ollama_ready=false
        for i in $(seq 1 30); do
            if curl -s "http://localhost:$OLLAMA_PORT/api/tags" >/dev/null 2>&1; then
                success "Ollama API ready"
                ollama_ready=true
                break
            fi
            if [ $i -eq 30 ]; then
                warn "Ollama API timeout after 30s"
                log "Check logs: tail -f /var/log/ollama.log"
            fi
            sleep 2
        done
        
        # Preload first GPU-optimized model if Ollama just started
        if [ "$ollama_ready" = true ]; then
            local first_model
            first_model=$(curl -s "http://localhost:$OLLAMA_PORT/api/tags" 2>/dev/null | grep -o '"name":"[^"]*maxgpu[^"]*"' | head -1 | cut -d'"' -f4 || true)
            if [ -n "$first_model" ]; then
                log "Preloading GPU-optimized model: $first_model"
                curl -s -X POST "http://localhost:$OLLAMA_PORT/api/generate" \
                    -H "Content-Type: application/json" \
                    -d "{\"model\":\"$first_model\",\"keep_alive\":-1,\"prompt\":\"test\"}" \
                    >/dev/null 2>&1 || warn "Model preload failed (non-critical)"
            fi
        fi
    fi
    
    # List models available via API
    log ""
    log "📋 Models available via Ollama API:"
    local api_response
    api_response=$(curl -s "http://localhost:$OLLAMA_PORT/api/tags" 2>/dev/null || echo '{"models":[]}')
    
    local model_names
    model_names=$(echo "$api_response" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 || true)
    
    if [ -n "$model_names" ]; then
        echo "$model_names" | while read -r model_name; do
            log "  ✓ $model_name"
        done
    else
        log "  (No models loaded yet - pull models to get started)"
    fi
    log ""
    
    # ========== WEBUI SERVICE ==========
    # Check if WebUI needs to be started/restarted
    local webui_needs_start=false
    
    if [ "$needs_webui_update" = true ]; then
        # WebUI was updated, must restart
        webui_needs_start=true
        log "WebUI needs restart (was updated)"
    else
        # Check if WebUI is running
        local webui_running=false
        if docker inspect open-webui >/dev/null 2>&1; then
            local container_status
            container_status=$(docker inspect open-webui --format='{{.State.Status}}' 2>/dev/null || echo "missing")
            
            if [ "$container_status" = "running" ]; then
                log "WebUI container is running, checking HTTP response..."
                if timeout 5 curl -s "http://localhost:$WEBUI_PORT" >/dev/null 2>&1; then
                    webui_running=true
                    success "✓ WebUI is already running and responding"
                else
                    warn "WebUI container running but not responding, will restart"
                    webui_needs_start=true
                fi
            else
                log "WebUI container exists but not running (status: $container_status)"
                webui_needs_start=true
            fi
        else
            log "WebUI container not found, will start"
            webui_needs_start=true
        fi
    fi
    
    # Start or update WebUI if needed
    if [ "$webui_needs_start" = true ]; then
        log "Starting WebUI Docker..."
        
        # Clean up port
        kill_port_processes "$WEBUI_PORT"
        sleep 2
        
        # Remove old container
        docker rm -f open-webui 2>/dev/null || true
        sleep 2
        
        # Note: Image was already pulled during version check in Phase 1 if update was needed
        # No need to pull again here
        
        # Start WebUI container
        if docker run -d \
            --name open-webui \
            --gpus=all \
            -p "$WEBUI_PORT:8080" \
            -v open-webui:/app/backend/data \
            -v "$MODELS_DIR:/root/.ollama/models:ro" \
            -e OLLAMA_BASE_URL="http://host.docker.internal:$OLLAMA_PORT" \
            -e OLLAMA_MODELS="/root/.ollama/models" \
            --add-host=host.docker.internal:host-gateway \
            --memory=32g \
            --shm-size=16g \
            --restart=unless-stopped \
            ghcr.io/open-webui/open-webui:main 2>&1 | tee -a "$LOG_FILE"; then
            success "WebUI Docker started"
            
            # Wait a moment for WebUI to start
            log "Waiting for WebUI to respond..."
            for i in $(seq 1 15); do
                if timeout 5 curl -s "http://localhost:$WEBUI_PORT" >/dev/null 2>&1; then
                    success "WebUI is responding"
                    break
                fi
                [ $i -eq 15 ] && log "⏳ WebUI may take 30-60s to fully start"
                sleep 2
            done
        else
            warn "WebUI Docker failed to start - check 'docker logs open-webui'"
        fi
    fi
    
    # ========== PHASE 7: FINAL STATUS ==========
    log "=== PHASE 7: Final status report ==="
    
    sleep 5
    
    # Check Ollama
    if curl -s "http://localhost:$OLLAMA_PORT/api/tags" >/dev/null 2>&1; then
        success "✓ Ollama API responding on port $OLLAMA_PORT"
    else
        warn "✗ Ollama API not responding (check /var/log/ollama.log)"
    fi
    
    # Check WebUI
    if timeout 5 curl -s "http://localhost:$WEBUI_PORT" >/dev/null 2>&1; then
        success "✓ WebUI responding on port $WEBUI_PORT"
    else
        log "⏳ WebUI starting... (may take 30-60s)"
        log "   Monitor with: docker logs -f open-webui"
    fi
    
    # GPU Status
    if command -v nvidia-smi >/dev/null 2>&1; then
        log ""
        log "🎯 GPU Status:"
        nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu \
            --format=csv,noheader 2>/dev/null | tee -a "$LOG_FILE" || true
        log ""
    fi
    
    # Model count from API
    local api_model_count
    api_model_count=$(echo "$model_names" | grep -c . || echo "0")
    log "📊 Models available: $api_model_count"
    
    # Disk usage
    local disk_usage
    disk_usage=$(du -sh "$MODELS_DIR" 2>/dev/null | awk '{print $1}' || echo 'unknown')
    log "💾 Models directory size: $disk_usage"
    
    # Release lock
    release_lock
    
    # Final summary
    log ""
    log "═══════════════════════════════════════════════════════════════"
    log "🎉 DEPLOYMENT COMPLETE"
    log "═══════════════════════════════════════════════════════════════"
    log ""
    log "🌐 Access Points:"
    log "   Ollama API:  http://localhost:$OLLAMA_PORT"
    log "   WebUI:       http://localhost:$WEBUI_PORT"
    log ""
    log "📁 Configuration:"
    log "   Models Dir:  $MODELS_DIR"
    log "   Log File:    $LOG_FILE"
    log "   Ollama Log:  /var/log/ollama.log"
    log ""
    log "⚡ GPU Optimizations:"
    log "   Use models ending in '-maxgpu' for 100% GPU offload"
    log "   Example: llama3.2-maxgpu, mistral-maxgpu"
    log ""
    log "📝 Quick Commands:"
    log "   Pull model:  OLLAMA_MODELS=$MODELS_DIR ollama pull llama3.2"
    log "   List models: OLLAMA_MODELS=$MODELS_DIR ollama list"
    log "   Test model:  OLLAMA_MODELS=$MODELS_DIR ollama run llama3.2"
    log ""
    log "🔍 Troubleshooting:"
    log "   Ollama logs: tail -f /var/log/ollama.log"
    log "   WebUI logs:  docker logs -f open-webui"
    log "   GPU status:  watch -n 1 nvidia-smi"
    log ""
    log "End time: $(date)"
    log "═══════════════════════════════════════════════════════════════"
    
    return 0
}

# ========== EXECUTE MAIN ==========
main "$@"
exit_code=$?

# Cleanup (will execute even if main fails)
release_lock 2>/dev/null || true
rm -f /tmp/Modelfile.$$ 2>/dev/null || true

exit $exit_code
```
