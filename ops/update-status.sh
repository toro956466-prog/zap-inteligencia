#!/bin/bash
# Zap Inteligência — Full Status Updater
# Polls Ollama + ComfyUI + Phones and updates status.json
# Run via cron every 60s or on-demand

STATUS_FILE="$(dirname "$0")/status.json"
PC_IP="100.79.77.119"
OLLAMA_URL="http://${PC_IP}:11434"
COMFYUI_URL="http://${PC_IP}:8188"
TIMEOUT=5

# Phone ADB addresses
MOTOG_ADB="100.111.83.8:38641"
TCL_ADB="100.73.184.62:44411"

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

# ─── Poll Phones ───

poll_phone() {
  local ADB_ADDR="$1"
  local WA_PACKAGE="$2"  # com.whatsapp or com.whatsapp.w4b
  
  # Test connectivity first
  local TEST=$(adb -s "$ADB_ADDR" shell "echo ok" 2>/dev/null)
  if [ "$TEST" != "ok" ]; then
    echo "offline"
    return
  fi
  
  # Get each value separately to avoid shell escaping issues
  local BATTERY=$(adb -s "$ADB_ADDR" shell "dumpsys battery" 2>/dev/null | grep "level:" | head -1 | tr -dc '0-9')
  local TEMP_RAW=$(adb -s "$ADB_ADDR" shell "dumpsys battery" 2>/dev/null | grep "temperature:" | head -1 | tr -dc '0-9')
  local TEMP=$(echo "scale=1; ${TEMP_RAW:-0} / 10" | bc 2>/dev/null || echo "0")
  
  local RAM_TOTAL=$(adb -s "$ADB_ADDR" shell "cat /proc/meminfo" 2>/dev/null | grep "MemTotal" | awk '{print int($2/1024)}')
  local RAM_AVAIL=$(adb -s "$ADB_ADDR" shell "cat /proc/meminfo" 2>/dev/null | grep "MemAvailable" | awk '{print int($2/1024)}')
  
  local DF_LINE=$(adb -s "$ADB_ADDR" shell "df /data" 2>/dev/null | tail -1)
  local STORAGE_USED_KB=$(echo "$DF_LINE" | awk '{print $3}')
  local STORAGE_TOTAL_KB=$(echo "$DF_LINE" | awk '{print $2}')
  local STORAGE_USED=$(echo "scale=0; ${STORAGE_USED_KB:-0} / 1048576" | bc 2>/dev/null || echo "0")
  local STORAGE_TOTAL=$(echo "scale=0; ${STORAGE_TOTAL_KB:-0} / 1048576" | bc 2>/dev/null || echo "0")
  
  local WA_PID=$(adb -s "$ADB_ADDR" shell "pidof $WA_PACKAGE" 2>/dev/null | tr -dc '0-9')
  local WA_RUNNING="false"
  if [ -n "$WA_PID" ]; then
    WA_RUNNING="true"
  fi
  
  echo "${BATTERY:-0}|${TEMP:-0}|${RAM_TOTAL:-0}|${RAM_AVAIL:-0}|${STORAGE_USED}G/${STORAGE_TOTAL}G|${WA_RUNNING}"
}

# Poll Moto G (WhatsApp Business = com.whatsapp.w4b)
MOTOG_DATA=$(poll_phone "$MOTOG_ADB" "com.whatsapp.w4b")
if [ "$MOTOG_DATA" = "offline" ]; then
  MOTOG_ONLINE=false
  MOTOG_BATTERY=0; MOTOG_TEMP=0; MOTOG_RAM_TOTAL=0; MOTOG_RAM_AVAIL=0
  MOTOG_STORAGE="—"; MOTOG_WA=false
else
  MOTOG_ONLINE=true
  IFS='|' read -r MOTOG_BATTERY MOTOG_TEMP MOTOG_RAM_TOTAL MOTOG_RAM_AVAIL MOTOG_STORAGE MOTOG_WA <<< "$MOTOG_DATA"
fi

# Poll TCL (WhatsApp Business = com.whatsapp.w4b)
TCL_DATA=$(poll_phone "$TCL_ADB" "com.whatsapp.w4b")
if [ "$TCL_DATA" = "offline" ]; then
  TCL_ONLINE=false
  TCL_BATTERY=0; TCL_TEMP=0; TCL_RAM_TOTAL=0; TCL_RAM_AVAIL=0
  TCL_STORAGE="—"; TCL_WA=false
else
  TCL_ONLINE=true
  IFS='|' read -r TCL_BATTERY TCL_TEMP TCL_RAM_TOTAL TCL_RAM_AVAIL TCL_STORAGE TCL_WA <<< "$TCL_DATA"
fi

echo "  Moto G: online=$MOTOG_ONLINE battery=$MOTOG_BATTERY% WA=$MOTOG_WA storage=$MOTOG_STORAGE"
echo "  TCL:    online=$TCL_ONLINE battery=$TCL_BATTERY% WA=$TCL_WA storage=$TCL_STORAGE"

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

# ─── Poll Services (Proxy + DroidClaw) ───

PROXY_DATA=$(curl -s --connect-timeout $TIMEOUT http://localhost:8899/health 2>/dev/null)
if [ -n "$PROXY_DATA" ] && echo "$PROXY_DATA" | jq -e '.status' >/dev/null 2>&1; then
  PROXY_RUNNING=true
  PROXY_UPTIME=$(echo "$PROXY_DATA" | jq -r '.uptime // 0')
  PROXY_MESSAGES=$(echo "$PROXY_DATA" | jq -r '.messages // 0')
  PROXY_ERRORS=$(echo "$PROXY_DATA" | jq -r '.errors // 0')
  PROXY_CONTACTS=$(echo "$PROXY_DATA" | jq -r '.uniqueContacts // 0')
else
  PROXY_RUNNING=false
  PROXY_UPTIME=0; PROXY_MESSAGES=0; PROXY_ERRORS=0; PROXY_CONTACTS=0
fi

MOTOG_DC_PID=$(adb -s "$MOTOG_ADB" shell "pidof com.openclaw.droidclaw" 2>/dev/null | tr -dc '0-9')
MOTOG_DROIDCLAW="false"
[ -n "$MOTOG_DC_PID" ] && MOTOG_DROIDCLAW="true"

TCL_DC_PID=$(adb -s "$TCL_ADB" shell "pidof com.openclaw.droidclaw" 2>/dev/null | tr -dc '0-9')
TCL_DROIDCLAW="false"
[ -n "$TCL_DC_PID" ] && TCL_DROIDCLAW="true"

echo "  Proxy: running=$PROXY_RUNNING msgs=$PROXY_MESSAGES contacts=$PROXY_CONTACTS"
echo "  DroidClaw: MotoG=$MOTOG_DROIDCLAW TCL=$TCL_DROIDCLAW"

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
  --argjson motogOnline "$MOTOG_ONLINE" \
  --argjson motogBattery "${MOTOG_BATTERY:-0}" \
  --argjson motogTemp "${MOTOG_TEMP:-0}" \
  --argjson motogRamTotal "${MOTOG_RAM_TOTAL:-0}" \
  --argjson motogRamAvail "${MOTOG_RAM_AVAIL:-0}" \
  --arg motogStorage "$MOTOG_STORAGE" \
  --argjson motogWa "${MOTOG_WA:-false}" \
  --argjson tclOnline "$TCL_ONLINE" \
  --argjson tclBattery "${TCL_BATTERY:-0}" \
  --argjson tclTemp "${TCL_TEMP:-0}" \
  --argjson tclRamTotal "${TCL_RAM_TOTAL:-0}" \
  --argjson tclRamAvail "${TCL_RAM_AVAIL:-0}" \
  --arg tclStorage "$TCL_STORAGE" \
  --argjson tclWa "${TCL_WA:-false}" \
  --argjson motogDc "$MOTOG_DROIDCLAW" \
  --argjson tclDc "$TCL_DROIDCLAW" \
  --argjson proxyRunning "$PROXY_RUNNING" \
  --argjson proxyUptime "$PROXY_UPTIME" \
  --argjson proxyMessages "$PROXY_MESSAGES" \
  --argjson proxyErrors "$PROXY_ERRORS" \
  --argjson proxyContacts "$PROXY_CONTACTS" \
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
  } |
  .phones.motoG.online = $motogOnline |
  .phones.motoG.battery = $motogBattery |
  .phones.motoG.temperature = $motogTemp |
  .phones.motoG.ramTotal = $motogRamTotal |
  .phones.motoG.ramAvailable = $motogRamAvail |
  .phones.motoG.storage = $motogStorage |
  .phones.motoG.whatsappRunning = $motogWa |
  .phones.tcl.online = $tclOnline |
  .phones.tcl.battery = $tclBattery |
  .phones.tcl.temperature = $tclTemp |
  .phones.tcl.ramTotal = $tclRamTotal |
  .phones.tcl.ramAvailable = $tclRamAvail |
  .phones.tcl.storage = $tclStorage |
  .phones.tcl.whatsappRunning = $tclWa |
  .phones.motoG.droidclaw = $motogDc |
  .phones.tcl.droidclaw = $tclDc |
  .proxy = {
    running: $proxyRunning,
    uptime: $proxyUptime,
    messages: $proxyMessages,
    errors: $proxyErrors,
    uniqueContacts: $proxyContacts
  }
  ' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

# ─── Auto-unload idle Ollama models to free VRAM ───
# If no ComfyUI jobs are pending/running AND Ollama has models loaded,
# unload them after capturing stats (they'll reload on next request)
if [ "$COMFYUI_RUNNING" = "true" ] && [ "$QUEUE_RUNNING" -eq 0 ] && [ "$QUEUE_PENDING" -eq 0 ]; then
  if [ "$(echo "$LOADED_MODELS" | jq 'length')" -gt 0 ]; then
    for MODEL in $(echo "$LOADED_MODELS" | jq -r '.[]'); do
      curl -s "${OLLAMA_URL}/api/generate" -d "{\"model\":\"${MODEL}\",\"keep_alive\":0}" > /dev/null 2>&1
      echo "  ♻️  Auto-unloaded: $MODEL"
    done
  fi
fi

# ─── Health State Tracking + Alerts ───
HEALTH_STATE="/Users/toro/clawd/clients/health-state.json"
if [ ! -f "$HEALTH_STATE" ]; then
  echo '{}' > "$HEALTH_STATE"
fi

# Build current health status
HEALTH_JSON=$(jq -n \
  --argjson ollama "$OLLAMA_RUNNING" \
  --argjson comfyui "$COMFYUI_RUNNING" \
  --argjson motog "$MOTOG_ONLINE" \
  --argjson tcl "$TCL_ONLINE" \
  --argjson motogWa "${MOTOG_WA:-false}" \
  '{ollama: $ollama, comfyui: $comfyui, motog: $motog, tcl: $tcl, motogWa: $motogWa}')

# Compare with previous state and log changes
PREV_STATE=$(cat "$HEALTH_STATE")
echo "$HEALTH_JSON" > "$HEALTH_STATE"

# Log any service that went down (for dashboard errors section)
for SVC in ollama comfyui motog tcl motogWa; do
  CURRENT=$(echo "$HEALTH_JSON" | jq -r ".$SVC")
  PREVIOUS=$(echo "$PREV_STATE" | jq -r ".$SVC // true")
  if [ "$CURRENT" = "false" ] && [ "$PREVIOUS" = "true" ]; then
    echo "  ⚠️  $SVC went DOWN"
  elif [ "$CURRENT" = "true" ] && [ "$PREVIOUS" = "false" ]; then
    echo "  ✅ $SVC recovered"
  fi
done

echo "✅ Status updated at $TIMESTAMP"
echo "   Ollama: $OLLAMA_RUNNING (models: $LOADED_MODELS, VRAM: ${OLLAMA_VRAM_GB}GB)"
echo "   ComfyUI: $COMFYUI_RUNNING (Torch: ${TORCH_VRAM_GB}GB)"
echo "   VRAM: Ollama ${OLLAMA_VRAM_GB}GB + ComfyUI ${TORCH_VRAM_GB}GB + System ${CUDA_OVERHEAD}GB + Free ${FREE_GB}GB = ${VRAM_TOTAL_GB}GB"

# ─── Auto-deploy to GitHub ───
cd "$(dirname "$0")/.." 2>/dev/null
if git diff --quiet ops/status.json 2>/dev/null; then
  echo "   No changes to deploy"
else
  git add ops/status.json && \
  git commit -q -m "ops: auto-update $(date +%H:%M)" && \
  git push -q origin main 2>/dev/null && \
  echo "   📤 Deployed to GitHub" || \
  echo "   ⚠️  Deploy failed"
fi
