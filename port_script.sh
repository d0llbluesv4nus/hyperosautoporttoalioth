#!/bin/bash
set -e

# --- 1. CONFIG ---
if [ "$EUID" -ne 0 ]; then 
  echo "Run as sudo!"
  exit 1
fi

BASE_DIR=$1
PORT_DIR=$2
REPO_DIR=$(pwd)  # <--- ИСПРАВЛЕНО: определение переменной
WORK_DIR=$REPO_DIR/working
LOG_FILE=$REPO_DIR/port_log.txt

# --- CHECK TOOLS ---
# Проверяем наличие lpmake (нужен для финальной сборки)
if ! command -v mkfs.erofs &> /dev/null; then
    echo "mkfs.erofs not found!"
    exit 1
fi

echo "=== STARTING PORT ===" > $LOG_FILE

# --- FUNCTIONS ---
extract_partition() {
    image_path=$1
    output_path=$2
    partition_name=$3
    
    echo "Extracting $partition_name..."
    # Если это sparse image (.img), конвертируем (если есть sdat2img, но payload dumper дает raw)
    
    extract.erofs -i "$image_path" -x -o "$output_path" 2>/dev/null || 7z x "$image_path" -o"$output_path"
}

# --- 2. PREPARE ---
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# --- 3. EXTRACT ---
# Считаем, что в BASE_DIR и PORT_DIR уже лежат raw .img файлы
# Если там super.img, его надо было распаковать ДО запуска этого скрипта (в workflow) или здесь через lpunpack

extract_partition "$BASE_DIR/vendor.img" "$WORK_DIR/vendor" "vendor"
extract_partition "$PORT_DIR/system.img" "$WORK_DIR/system" "system"
extract_partition "$PORT_DIR/product.img" "$WORK_DIR/product" "product"
extract_partition "$PORT_DIR/system_ext.img" "$WORK_DIR/system_ext" "system_ext"
# Mi_ext часто нужен для HyperOS
if [ -f "$PORT_DIR/mi_ext.img" ]; then
    extract_partition "$PORT_DIR/mi_ext.img" "$WORK_DIR/mi_ext" "mi_ext"
fi

# Пути к корням
SYS_ROOT="$WORK_DIR/system/system" 
[ ! -d "$SYS_ROOT" ] && SYS_ROOT="$WORK_DIR/system"

PRD_ROOT="$WORK_DIR/product/product"
[ ! -d "$PRD_ROOT" ] && PRD_ROOT="$WORK_DIR/product"

# --- 4. MODIFICATIONS (BASE) ---

# Copy Vendor Overlays (Осторожно)
if [ -d "$WORK_DIR/system_ext/overlay" ]; then
    echo "Moving system_ext overlays..."
    # Логика переноса оверлеев
fi

# Fix build.prop (Vendor)
sed -i 's/ro.apex.updatable=.*/ro.apex.updatable=true/' "$WORK_DIR/vendor/build.prop"

# Fix build.prop (System)
echo "ro.vendor.display.default_fps=120" >> "$SYS_ROOT/build.prop"
# ... остальные ваши фиксы ...

# Debloat (ваш код)
rm -rf "$SYS_ROOT/app/MiuiVideo"
# ...

# --- 5. REPACK ---
echo "Repacking images..."

# ВАЖНО: Mount points
# Также нужно сохранить file_contexts, если возможно. 
# В самом простом случае надеемся на удачу или патчим sepolicy в ядре.

mkfs.erofs -zlz4hc --mount-point /vendor --fs-config-file "$REPO_DIR/fs_config_vendor" "$BASE_DIR/vendor.img" "$WORK_DIR/vendor"
mkfs.erofs -zlz4hc --mount-point /system --fs-config-file "$REPO_DIR/fs_config_system" "$BASE_DIR/system.img" "$WORK_DIR/system"
mkfs.erofs -zlz4hc --mount-point /product --fs-config-file "$REPO_DIR/fs_config_product" "$BASE_DIR/product.img" "$WORK_DIR/product"
mkfs.erofs -zlz4hc --mount-point /system_ext "$BASE_DIR/system_ext.img" "$WORK_DIR/system_ext"

# ПРИМЕЧАНИЕ: fs_config_... файлы нужно создать или генерировать. 
# Если их нет, уберите флаг --fs-config-file, но права доступа будут root:root 777 или 755.

echo "Done. Use lpmake to build super.img if needed."кальной папки patches/nfc в систему
if [ -d "$REPO_DIR/patches/nfc" ]; then
    cp -rf "$REPO_DIR/patches/nfc/"* "$SYS_ROOT/etc/"
    echo " -> NFC configs copied." | tee -a $LOG_FILE
else
    echo " !! WARNING: NFC patches not found in $REPO_DIR/patches/nfc" | tee -a $LOG_FILE
fi

# === 4.4 SPECIFIC OVERLAYS ===
echo " -> Injecting Alioth Overlays..." | tee -a $LOG_FILE
if [ -d "$REPO_DIR/patches/overlays" ]; then
    mkdir -p "$PRD_ROOT/overlay"
    cp -rf "$REPO_DIR/patches/overlays/"* "$PRD_ROOT/overlay/"
    echo " -> Overlays injected into Product." | tee -a $LOG_FILE
fi

# ---------------------------------------------
# 5. DEBLOAT (Расширенный список)
# ---------------------------------------------
echo "[5/7] Extended Debloating..." | tee -a $LOG_FILE

APPS_TO_REMOVE=(
    "app/MiuiVideo" "app/MiuiVideoPlayer" "MiuiVideo"
    "app/MiuiGallery" "priv-app/MiuiGallery"
    "app/MSA" "priv-app/MSA"
    "app/MiuiDaemon" "priv-app/MiuiDaemon"
    "app/HybridAccessory"
    "app/MiMusic" "MiMusic"
    "app/MiWallet" "Mipay" "MiPay"
    "app/UPTsmService"
    "app/MiShop"
    "app/GameCenter"
    "app/VoiceAssist" "MiAI"
    "app/SogouInput" "SogouInput"
    "data-app/*"
)

for app in "${APPS_TO_REMOVE[@]}"; do
    # Пытаемся удалить везде, так как пути могут меняться
    rm -rf "$SYS_ROOT/$app"
    rm -rf "$PRD_ROOT/$app"
    # Поиск по имени папки (на случай нестандартных путей)
    find "$SYS_ROOT" -type d -name "$(basename $app)" -exec rm -rf {} + 2>/dev/null
    find "$PRD_ROOT" -type d -name "$(basename $app)" -exec rm -rf {} + 2>/dev/null
done
echo " -> Debloat complete." | tee -a $LOG_FILE

# ---------------------------------------------
# 6. PERMISSIONS FIX (Важно для Bootloop fix)
# ---------------------------------------------
echo "[6/7] Fixing Permissions & Contexts..." | tee -a $LOG_FILE

# Базовые права
chmod -R 755 "$SYS_ROOT/bin" 2>/dev/null
chmod -R 755 "$SYS_ROOT/xbin" 2>/dev/null
chmod 0644 "$SYSTEM_PROP"

# Важные init скрипты
if [ -d "$SYS_ROOT/etc/init.d" ]; then
    chmod 750 "$SYS_ROOT/etc/init.d/"* 2>/dev/null
fi

# ---------------------------------------------
# 7. REPACKING
# ---------------------------------------------
echo "[7/7] Сборка образов (Repack)..." | tee -a $LOG_FILE

# Repack Vendor
mkfs.erofs -zlz4hc "$BASE_DIR/vendor.img" "$WORK_DIR/vendor_base"
echo " -> Vendor repacked." | tee -a $LOG_FILE

# Repack System
mkfs.erofs -zlz4hc "$BASE_DIR/system.img" "$SYS_ROOT"
echo " -> System repacked." | tee -a $LOG_FILE

# Repack Product
mkfs.erofs -zlz4hc "$BASE_DIR/product.img" "$PRD_ROOT"
echo " -> Product repacked." | tee -a $LOG_FILE

# Очистка рабочей папки
# rm -rf "$WORK_DIR" # Можно закомментировать для отладки

echo "=== ПОРТИРОВАНИЕ ЗАВЕРШЕНО УСПЕШНО ===" | tee -a $LOG_FILE
