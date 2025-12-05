#!/bin/bash
set -e # Остановить скрипт при любой ошибке

# Проверка на sudo
if [ "$EUID" -ne 0 ]; then 
  echo "Пожалуйста, запустите скрипт от имени root (sudo)"
  exit 1
fi

BASE_DIR=$1
PORT_DIR=$2
WORK_DIR=$(pwd)/working
LOG_FILE=$(pwd)/port_log.txt

# Проверка аргументов
if [ -z "$BASE_DIR" ] || [ -z "$PORT_DIR" ]; then
    echo "Использование: sudo ./port_script.sh <путь_к_базе> <путь_к_порту>"
    exit 1
fi

echo "" > $LOG_FILE
echo "=== STARTING PORT (ALIOTH HYPEROS) ===" | tee -a $LOG_FILE

# Подготовка папок
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/mnt_port" "$WORK_DIR/mnt_base"
mkdir -p "$WORK_DIR/out/system" "$WORK_DIR/out/product" "$WORK_DIR/out/system_ext" "$WORK_DIR/out/vendor"

# Функция безопасного копирования (сохраняет SELinux xattr)
safe_copy() {
    src=$1
    dst=$2
    # cp -a сохраняет права и контексты, если ФС поддерживает xattr
    cp -a "$src/." "$dst/"
}

# Функция обработки образа (Mount -> Copy -> Unmount)
process_image() {
    img_path=$1
    mount_point=$2
    out_dir=$3
    
    echo "Processing $img_path..." | tee -a $LOG_FILE
    
    # Если образ в sparse формате (simg), конвертируем в raw
    if file "$img_path" | grep -q "Android sparse image"; then
        simg2img "$img_path" "${img_path}.raw"
        mv "${img_path}.raw" "$img_path"
    fi

    # Монтируем
    mount -o loop,ro "$img_path" "$mount_point"
    
    # Копируем содержимое (сохраняя метаданные!)
    echo " -> Copying files..."
    cp -a "$mount_point/." "$out_dir/"
    
    # Размонтируем
    umount "$mount_point"
}

# ---------------------------------------------
# 1. РАСПАКОВКА (ЧЕРЕЗ MOUNT)
# ---------------------------------------------
echo "[1/5] Extracting Images via Mount..." | tee -a $LOG_FILE

# Нам нужен Vendor от BASE (Alioth)
process_image "$BASE_DIR/vendor.img" "$WORK_DIR/mnt_base" "$WORK_DIR/out/vendor"

# Нам нужны System, Product, System_ext от PORT (Donor)
process_image "$PORT_DIR/system.img" "$WORK_DIR/mnt_port" "$WORK_DIR/out/system"
process_image "$PORT_DIR/product.img" "$WORK_DIR/mnt_port" "$WORK_DIR/out/product"
process_image "$PORT_DIR/system_ext.img" "$WORK_DIR/mnt_port" "$WORK_DIR/out/system_ext"

# ---------------------------------------------
# 2. ПАТЧИНГ (FIXES)
# ---------------------------------------------
echo "[2/5] Patching..." | tee -a $LOG_FILE

SYS_ROOT="$WORK_DIR/out/system"
VEND_ROOT="$WORK_DIR/out/vendor"
PROD_ROOT="$WORK_DIR/out/product"

# --- Fix 1: Vendor build.prop ---
echo " -> Patching Vendor Props"
sed -i 's/ro.apex.updatable=.*/ro.apex.updatable=true/' "$VEND_ROOT/build.prop" || echo "ro.apex.updatable=true" >> "$VEND_ROOT/build.prop"

# --- Fix 2: System build.prop (120Hz) ---
echo " -> Patching 120Hz"
cat <<EOF >> "$SYS_ROOT/system/build.prop"
ro.surface_flinger.set_idle_timer_ms=0
ro.surface_flinger.set_touch_timer_ms=0
ro.surface_flinger.set_display_power_timer_ms=0
ro.vendor.display.default_fps=120
EOF

# --- Fix 3: SafetyNet / Fingerprint ---
# (Меняем только если fingerprint найден, чтобы не сломать синтаксис)
FINGERPRINT="POCO/alioth_global/alioth:13/RKQ1.211001.001/V14.0.8.0.TKHMIXM:user/release-keys"
find "$WORK_DIR/out" -name "build.prop" -print0 | xargs -0 sed -i "s/^ro.build.fingerprint=.*/ro.build.fingerprint=$FINGERPRINT/"

# --- Fix 4: NFC (Если есть патчи) ---
if [ -d "$(pwd)/patches/nfc" ]; then
    echo " -> Applying NFC patches"
    cp -rf "$(pwd)/patches/nfc/"* "$SYS_ROOT/system/etc/"
fi

# ---------------------------------------------
# 3. DEBLOAT (Осторожный)
# ---------------------------------------------
echo "[3/5] Light Debloat..." | tee -a $LOG_FILE
# Удаляем только явный мусор, не трогая Галерею (она нужна камере)
rm -rf "$PROD_ROOT/app/MSA"
rm -rf "$PROD_ROOT/priv-app/MSA"
rm -rf "$PROD_ROOT/app/MiShop"

# ---------------------------------------------
# 4. FIX CONTEXTS (В ручном режиме)
# ---------------------------------------------
echo "[4/5] Fixing Contexts (Basic)..." | tee -a $LOG_FILE
# Поскольку мы использовали cp -a, основные контексты сохранились.
# Но для измененных файлов (build.prop) нужно восстановить контекст.
# Обычно это u:object_r:system_file:s0, но лучше всего не трогать, если cp -a сработал.

# Исправляем права на build.prop, так как sed создает новый файл
chmod 644 "$SYS_ROOT/system/build.prop"
chmod 644 "$VEND_ROOT/build.prop"
# Восстанавливаем SELinux context (требует установленного setfilecon или chcon, но на ПК это сложно).
# Надеемся, что mkfs.erofs с опцией --file-contexts (если есть) или стандартная сборка подхватят.
# ВНИМАНИЕ: Для идеального порта нужно генерировать file_contexts.bin. 
# Для простого порта EROFS использует расширенные атрибуты (xattr), которые мы сохранили через cp -a.

# ---------------------------------------------
# 5. REPACKING (EROFS)
# ---------------------------------------------
echo "[5/5] Repacking images..." | tee -a $LOG_FILE

# Аргументы для сохранения xattr (контекстов)
EROFS_ARGS="-zlz4hc --mount-point"

# Функция упаковки
pack_image() {
    src_dir=$1
    img_name=$2
    mount_pt=$3 # например /system
    
    echo "Repacking $img_name..."
    # Важно: mkfs.erofs должен поддерживать флаги для сохранения xattr
    mkfs.erofs $EROFS_ARGS "$mount_pt" --fs-config-file "$(pwd)/fs_config_dummy" "$BASE_DIR/$img_name" "$src_dir" 
    # Примечание: полноценный fs-config здесь опущен для простоты, но cp -a + mkfs.erofs часто работает на новых версиях tools.
    # Если версия mkfs.erofs старая, используйте просто:
    # mkfs.erofs -zlz4hc "$BASE_DIR/$img_name" "$src_dir"
}

# ВАЖНО: Проверьте версию mkfs.erofs. 
# Если простая:
mkfs.erofs -zlz4hc "$BASE_DIR/vendor.img" "$WORK_DIR/out/vendor"
mkfs.erofs -zlz4hc "$BASE_DIR/system.img" "$WORK_DIR/out/system"
mkfs.erofs -zlz4hc "$BASE_DIR/product.img" "$WORK_DIR/out/product"
mkfs.erofs -zlz4hc "$BASE_DIR/system_ext.img" "$WORK_DIR/out/system_ext"

echo "=== DONE. Flash these images via Fastboot ===" | tee -a $LOG_FILE# ---------------------------------------------
# 2. РАСПАКОВКА ДЛЯ ПАТЧИНГА
# ---------------------------------------------
echo "[2/7] Распаковка образов для патчинга..." | tee -a $LOG_FILE

# Функция распаковки (поддерживает erofs и ext4 через 7z)
extract_img() {
    img_file=$1
    out_dir=$2
    echo "Extracting $img_file to $out_dir..." | tee -a $LOG_FILE
    # Пробуем как EROFS
    extract.erofs -i "$img_file" -x -o "$out_dir" 2>/dev/null
    if [ -z "$(ls -A $out_dir)" ]; then
        # Если пусто, пробуем как EXT4 через 7zip
        7z x "$img_file" -o"$out_dir" > /dev/null
    fi
}

extract_img "$BASE_DIR/vendor.img" "$WORK_DIR/vendor_base"
extract_img "$PORT_DIR/vendor.img" "$WORK_DIR/vendor_port"
# Нам нужно распаковать System и Product порта для деблоата и фиксов
extract_img "$PORT_DIR/system.img" "$WORK_DIR/system_port"
extract_img "$PORT_DIR/product.img" "$WORK_DIR/product_port"

# Определяем реальный путь к system (иногда system/system)
if [ -d "$WORK_DIR/system_port/system" ]; then
    SYS_ROOT="$WORK_DIR/system_port/system"
else
    SYS_ROOT="$WORK_DIR/system_port"
fi

if [ -d "$WORK_DIR/product_port/product" ]; then
    PRD_ROOT="$WORK_DIR/product_port/product"
else
    PRD_ROOT="$WORK_DIR/product_port"
fi

# ---------------------------------------------
# 3. PATCHING VENDOR
# ---------------------------------------------
echo "[3/7] Патчинг Vendor..." | tee -a $LOG_FILE

# A. Копирование Selinux contexts
if [ -f "$WORK_DIR/vendor_port/etc/selinux/vendor_property_contexts" ]; then
    cp "$WORK_DIR/vendor_port/etc/selinux/vendor_property_contexts" "$WORK_DIR/vendor_base/etc/selinux/"
    echo " -> Copied vendor_property_contexts" | tee -a $LOG_FILE
fi

# B. Копирование Overlays из порта (базовое)
if [ -d "$WORK_DIR/vendor_port/overlay" ]; then
    cp -r "$WORK_DIR/vendor_port/overlay/"* "$WORK_DIR/vendor_base/overlay/"
    echo " -> Copied Port Overlays" | tee -a $LOG_FILE
fi

# C. Правка build.prop в Vendor
VENDOR_PROP="$WORK_DIR/vendor_base/build.prop"
echo " -> Patching Vendor build.prop..." | tee -a $LOG_FILE

if grep -q "ro.apex.updatable" "$VENDOR_PROP"; then
    sed -i 's/ro.apex.updatable=.*/ro.apex.updatable=true/' "$VENDOR_PROP"
else
    echo "ro.apex.updatable=true" >> "$VENDOR_PROP"
fi

if grep -q "persist.sys.binary.xml" "$VENDOR_PROP"; then
    sed -i 's/persist.sys.binary.xml=.*/persist.sys.binary.xml=false/' "$VENDOR_PROP"
else
    echo "persist.sys.binary.xml=false" >> "$VENDOR_PROP"
fi

# ---------------------------------------------
# 4. PATCHING SYSTEM (Main Fixes)
# ---------------------------------------------
echo "[4/7] Патчинг System (Screen, NFC, SafetyNet)..." | tee -a $LOG_FILE

SYSTEM_PROP="$SYS_ROOT/build.prop"

# === 4.1 FIX 120HZ & SCREEN FLICKER ===
echo " -> Applying 120Hz & Screen fixes..." | tee -a $LOG_FILE
cat <<EOF >> "$SYSTEM_PROP"

# Alioth Screen Fixes
ro.surface_flinger.set_idle_timer_ms=0
ro.surface_flinger.set_touch_timer_ms=0
ro.surface_flinger.set_display_power_timer_ms=0
ro.vendor.display.default_fps=120
ro.surface_flinger.has_wide_color_display=true
ro.surface_flinger.has_HDR_display=true
EOF

# === 4.2 FIX SAFETYNET / CERTIFICATION ===
echo " -> Applying SafetyNet Fingerprint..." | tee -a $LOG_FILE
# Используем Fingerprint от POCO F3 Global (V14.0.8.0.TKHMIXM)
ORIGINAL_FINGERPRINT="POCO/alioth_global/alioth:13/RKQ1.211001.001/V14.0.8.0.TKHMIXM:user/release-keys"

# Заменяем отпечаток, если строка есть, или добавляем, если нет (через sed сложнее, просто добавим переопределение в конец, оно часто срабатывает)
# Но лучше заменить существующие:
sed -i "s/^ro.build.fingerprint=.*/ro.build.fingerprint=$ORIGINAL_FINGERPRINT/" "$SYSTEM_PROP"
sed -i "s/^ro.system.build.fingerprint=.*/ro.system.build.fingerprint=$ORIGINAL_FINGERPRINT/" "$SYSTEM_PROP"

# Если sed не нашел строк, добавляем принудительно:
if ! grep -q "ro.build.fingerprint=$ORIGINAL_FINGERPRINT" "$SYSTEM_PROP"; then
    echo "ro.build.fingerprint=$ORIGINAL_FINGERPRINT" >> "$SYSTEM_PROP"
fi

# === 4.3 FIX NFC CONFIG ===
echo " -> Fixing NFC Configuration..." | tee -a $LOG_FILE
# Копируем конфиги из локальной папки patches/nfc в систему
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
