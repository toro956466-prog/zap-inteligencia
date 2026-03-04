#!/bin/bash
# Zap Inteligência — VRAM Status Updater
# Polls Ollama + ComfyUI and updates status.json with live VRAM breakdown
# Run via cron every 60s or on-demand

STATUS_FILE="$(dirname "$0")/status.json"
PC_IP="100.79.77.119"
OLLAMA_URL="http://${PC_IP}:11434"
COMFYUI_URL="http://${PC_IP}:8188"
TIMEOUT=5

# Check if jq is available
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq required"
  exit 1
fi

# Get current status.json
if [ ! -f "$STATUS_FILE" ]; then
  echo "ERROR: $STATUS_FILE not found"
  exit 1
fi

# ─── Poll Ollama ───
OLLAMA_PS=$(curl -s --connect-timeout $TIMEOUT "${OLLAMA_URL}/api/ps" 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$OLLAMA_PS" ]; then
  OLLAMA_RUNNING=true
  
  # Extract loaded models and their VRAM usage
  LOADED_MODELS=$(echo "$OLLAMA_PS" | jq -r '[.models[]?.name // empty]')
  OLLAMA_VRAM=$(echo "$OLLAMA_PS" | jq '[.models[]?.size_vram // 0] | add // 0')
  OLLAMA_VRAM_GB=$(echo "scale=1; ${OLLAMA_VRAM:-0} / 1000000000" | bc 2>/dev/null || echo "0.0")
else
  OLLAMA_RUNNING=false
  LOADED_MODELS="[]"
  OLLAMA_VRAM_GB="0.0"
fi

# ─── Poll ComfyUI ───
COMFYUI_STATS=$(curl -s --connect-timeout $TIMEOUT "${COMFYUI_URL}/system_stats" 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$COMFYUI_STATS" ]; then
  COMFYUI_RUNNING=true
  
  VRAM_TOTAL=$(echo "$COMFYUI_STATS" | jq '.devices[0].vram_total // 0')
  VRAM_FREE=$(echo "$COMFYUI_STATS" | jq '.devices[0].vram_free // 0')
  TORCH_VRAM=$(echo "$COMFYUI_STATS" | jq '.devices[0].torch_vram_total // 0')
  
  VRAM_TOTAL_GB=$(echo "scale=1; ${VRAM_TOTAL} / 1000000000" | bc)
  VRAM_FREE_GB=$(echo "scale=1; ${VRAM_FREE} / 1000000000" | bc)
  TORCH_VRAM_GB=$(echo "scale=1; ${TORCH_VRAM} / 1000000000" | bc)
  
  # CUDA overhead = total used - torch - ollama
  VRAM_USED=$(echo "${VRAM_TOTAL} - ${VRAM_FREE}" | bc)
  CUDA_OVERHEAD=$(echo "scale=1; (${VRAM_USED} / 1000000000) - ${TORCH_VRAM_GB} - ${OLLAMA_VRAM_GB}" | bc)
  # Clamp to 0 if negative
  CUDA_OVERHEAD=$(echo "$CUDA_OVERHEAD" | awk '{if ($1 < 0) print "0.0"; else printf "%.1f", $1}')
  
  FREE_GB=$(echo "scale=1; ${VRAM_TOTAL_GB} - ${OLLAMA_VRAM_GB} - ${TORCH_VRAM_GB} - ${CUDA_OVERHEAD}" | bc)
  FREE_GB=$(echo "$FREE_GB" | awk '{if ($1 < 0) print "0.0"; else printf "%.1f", $1}')
  
  # GPU utilization estimate (torch allocated vs total)
  GPU_USAGE=$(echo "scale=0; (${VRAM_TOTAL} - ${VRAM_FREE}) * 100 / ${VRAM_TOTAL}" | bc)
  
  PC_ONLINE=true
else
  COMFYUI_RUNNING=false
  TORCH_VRAM_GB="0.0"
  VRAM_TOTAL_GB="24.0"
  CUDA_OVERHEAD="0.0"
  FREE_GB="24.0"
  GPU_USAGE=0
  
  # PC might still be online (Ollama could be up without ComfyUI)
  if [ "$OLLAMA_RUNNING" = "true" ]; then
    PC_ONLINE=true
  else
    PC_ONLINE=false
  fi
fi

# ─── Check ComfyUI queue ───
COMFYUI_QUEUE=$(curl -s --connect-timeout $TIMEOUT "${COMFYUI_URL}/queue" 2>/dev/null)
QUEUE_RUNNING=0
QUEUE_PENDING=0
if [ -n "$COMFYUI_QUEUE" ]; then
  QUEUE_RUNNING=$(echo "$COMFYUI_QUEUE" | jq '.queue_running | length')
  QUEUE_PENDING=$(echo "$COMFYUI_QUEUE" | jq '.queue_pending | length')
fi

# ─── Update status.json ───
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\(..\)$/:\1/')

jq \
  --arg ts "$TIMESTAMP" \
  --argjson pcOnline "$PC_ONLINE" \
  --argjson ollamaRunning "$OLLAMA_RUNNING" \
  --argjson loadedModels "$LOADED_MODELS" \
  --arg ollamaVram "${OLLAMA_VRAM_GB}GB" \
  --arg vramTotal "${VRAM_TOTAL_GB}GB" \
  --argjson gpuUsage "$GPU_USAGE" \
  --argjson comfyRunning "$COMFYUI_RUNNING" \
  --arg torchVram "${TORCH_VRAM_GB}GB" \
  --arg cudaOverhead "${CUDA_OVERHEAD}GB" \
  --arg freeVram "${FREE_GB}GB" \
  --argjson queueRunning "$QUEUE_RUNNING" \
  --argjson queuePending "$QUEUE_PENDING" \
  '
  .lastUpdated = $ts |
  .pc.online = $pcOnline |
  .pc.ollama.running = $ollamaRunning |
  .pc.ollama.loadedModels = $loadedModels |
  .pc.ollama.vramUsed = $ollamaVram |
  .pc.ollama.vramTotal = $vramTotal |
  .pc.ollama.gpuUsage = $gpuUsage |
  .pc.comfyui = {
    running: $comfyRunning,
    torchVram: $torchVram,
    checkpoint: (.pc.comfyui.checkpoint // "juggernautXL_v9"),
    queueRunning: $queueRunning,
    queuePending: $queuePending
  } |
  .pc.vramBreakdown = {
    total: $vramTotal,
    ollamaModels: $ollamaVram,
    comfyui: $torchVram,
    cudaOverhead: $cudaOverhead,
    free: $freeVram
  }
  ' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

echo "✅ Status updated at $TIMESTAMP"
echo "   Ollama: $OLLAMA_RUNNING (models: $LOADED_MODELS, VRAM: ${OLLAMA_VRAM_GB}GB)"
echo "   ComfyUI: $COMFYUI_RUNNING (Torch: ${TORCH_VRAM_GB}GB)"
echo "   VRAM: Ollama ${OLLAMA_VRAM_GB}GB + ComfyUI ${TORCH_VRAM_GB}GB + System ${CUDA_OVERHEAD}GB + Free ${FREE_GB}GB = ${VRAM_TOTAL_GB}GB"
