#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v openssl >/dev/null 2>&1; then
    echo "❌ Error: 'openssl' not found. Please run: pkg install openssl-tool"
    exit 1
fi

if ! command -v argon2 >/dev/null 2>&1; then
    echo "❌ Error: 'argon2' not found. Please run: pkg install argon2"
    exit 1
fi

shopt -s nullglob
CFG_FILES=("$SCRIPT_DIR"/*.qms-cfgenv)
shopt -u nullglob

CFG_COUNT=${#CFG_FILES[@]}

if [ "$CFG_COUNT" -gt 1 ]; then
    echo "❌ Error：Multiple database .qms-cfgenv database file, Please clean it up and try running again!"
    for f in "${CFG_FILES[@]}"; do
        echo "   $f"
    done
    exit 1
fi

if [ "$CFG_COUNT" -eq 1 ]; then
    TMP_CHECK="${CFG_FILES[0]}"
    if head -1 "$TMP_CHECK" 2>/dev/null | grep -q '^QMSENC1$'; then
        DATA_CHK=$(sed -n 's/^DATA=//p' "$TMP_CHECK" | head -1)
        if [ -z "$DATA_CHK" ] || echo "$DATA_CHK" | grep -q 'not found'; then
            echo "⚠️  Legacy or corrupted config detected. Renaming and starting fresh..."
            mv "$TMP_CHECK" "${TMP_CHECK}.old.$(date +%s)" 2>/dev/null
            BAK_CHK="${TMP_CHECK%.qms-cfgenv}.qms-cfgbak"
            [ -f "$BAK_CHK" ] && mv "$BAK_CHK" "${BAK_CHK}.old.$(date +%s)" 2>/dev/null
            rm -rf "$SCRIPT_DIR/...QMS-Library..." 2>/dev/null
            shopt -s nullglob
            CFG_FILES=("$SCRIPT_DIR"/*.qms-cfgenv)
            shopt -u nullglob
            CFG_COUNT=${#CFG_FILES[@]}
        fi
    fi
fi

derive_key() {
    local password="$1"
    local salt="$2"
    local encoded
    encoded=$(printf '%s' "$password" | argon2 "$salt" -id -t 3 -m 16 -p 4 -l 32 2>/dev/null | grep '^Encoded:' | awk '{print $2}')
    if [ -z "$encoded" ]; then
        encoded=$(printf '%s' "$password" | argon2 "$salt" -id -t 3 -m 16 -p 4 -l 32 2>/dev/null | grep -o '\$argon2id\$[^ ]*' | head -1)
    fi
    if [ -z "$encoded" ]; then
        printf '%s' "$password" | openssl dgst -sha256 -hmac "$salt" | awk '{print $NF}'
        return
    fi
    printf '%s' "$encoded" | sha256sum | awk '{print $1}'
}

encrypt_file() {
    local src="$1"
    local dst="$2"
    local password="$3"
    local salt=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16)
    local key=$(derive_key "$password" "$salt")
    local iv=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    local enc=$(openssl enc -aes-256-cbc -K "$key" -iv "$iv" -a -A < "$src" 2>&1)
    {
        printf 'QMSENC1\n'
        printf 'SALT=%s\n' "$salt"
        printf 'IV=%s\n' "$iv"
        printf 'DATA=%s\n' "$enc"
    } > "$dst"
}

decrypt_file() {
    local src="$1"
    local dst="$2"
    local password="$3"
    local salt=$(grep '^SALT=' "$src" | cut -d= -f2)
    local iv=$(grep '^IV=' "$src" | cut -d= -f2)
    local data=$(sed -n 's/^DATA=//p' "$src" | head -1)
    if [ -z "$salt" ] || [ -z "$iv" ] || [ -z "$data" ]; then
        return 1
    fi
    local key=$(derive_key "$password" "$salt")
    printf '%s' "$data" | openssl enc -d -aes-256-cbc -K "$key" -iv "$iv" -a -A 2>/dev/null > "$dst"
    if [ ! -s "$dst" ]; then
        return 1
    fi
    if ! grep -q '^KEYSTORE=' "$dst"; then
        return 1
    fi
    return 0
}

is_encrypted() {
    head -1 "$1" 2>/dev/null | grep -q '^QMSENC1$'
}

if [ "$CFG_COUNT" -eq 0 ]; then
    shopt -s nullglob
    BAK_FILES=("$SCRIPT_DIR"/*.qms-cfgbak)
    shopt -u nullglob
    BAK_COUNT=${#BAK_FILES[@]}

    if [ "$BAK_COUNT" -gt 1 ]; then
        echo "❌ Error：Multiple .qms-cfgbak backup files found. Please clean them up and try again!"
        for f in "${BAK_FILES[@]}"; do
            echo "   $f"
        done
        exit 1
    elif [ "$BAK_COUNT" -eq 1 ]; then
        BAK_FILE="${BAK_FILES[0]}"
        echo "📂 Backup file found: $(basename "$BAK_FILE")"
        read -r -p "🔄 Do you want to restore from this backup? (y/n): " answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            CFG_FILE="${BAK_FILE%.qms-cfgbak}.qms-cfgenv"
            cp "$BAK_FILE" "$CFG_FILE"
            echo "   ✓ Restored from backup: $(basename "$CFG_FILE")"
            CFG_COUNT=1
            CFG_FILES=("$CFG_FILE")
        else
            echo "   ➡️ Skipping restore. Proceeding to first-time configuration."
        fi
    fi
fi

MASTER_PASS=""
TMP_CFG=""

if [ "$CFG_COUNT" -eq 1 ]; then
    CFG_FILE="${CFG_FILES[0]}"
    echo "📂 Configuration file database：$(basename "$CFG_FILE")"
    BAK_FILE="${CFG_FILE%.qms-cfgenv}.qms-cfgbak"
    LIB_DIR="$SCRIPT_DIR/...QMS-Library..."

    if [ ! -s "$CFG_FILE" ]; then
        echo "❌ Error：Core database is damaged!"
        if [ -f "$BAK_FILE" ]; then
            read -r -p "🔄 Backup file found. Restore? (y/n): " answer
            if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
                cp "$BAK_FILE" "$CFG_FILE"
                echo "   ✓ Restored from backup."
            else
                exit 1
            fi
        else
            exit 1
        fi
    fi

    TMP_CFG=$(mktemp 2>/dev/null || echo "/tmp/qms_cfg_$$")

    if is_encrypted "$CFG_FILE"; then
        ATTEMPTS=0
        while [ $ATTEMPTS -lt 3 ]; do
            read -r -s -p "🔐 Master password: " MASTER_PASS
            echo ""
            if decrypt_file "$CFG_FILE" "$TMP_CFG" "$MASTER_PASS"; then
                break
            fi
            ATTEMPTS=$((ATTEMPTS + 1))
            echo "❌ Error: Wrong password or corrupted configuration! ($ATTEMPTS/3)"
        done
        if [ $ATTEMPTS -eq 3 ]; then
            rm -f "$TMP_CFG"
            exit 1
        fi
    else
        cp "$CFG_FILE" "$TMP_CFG"
    fi

    KEYSTORE=""
    ALIAS=""
    STORE_PASS=""
    KEY_PASS=""

    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            KEYSTORE)   KEYSTORE="$value"   ;;
            ALIAS)      ALIAS="$value"      ;;
            STORE_PASS) STORE_PASS="$value" ;;
            KEY_PASS)   KEY_PASS="$value"   ;;
        esac
    done < "$TMP_CFG"

    if [ -z "$KEYSTORE" ] || [ -z "$ALIAS" ] || [ -z "$STORE_PASS" ] || [ -z "$KEY_PASS" ]; then
        rm -f "$TMP_CFG"
        echo "❌ Error：Core database is damaged!"
        if [ -f "$BAK_FILE" ]; then
            read -r -p "🔄 Backup file found. Restore? (y/n): " answer
            if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
                cp "$BAK_FILE" "$CFG_FILE"
                echo "   ✓ Restored from backup. Please run the script again."
            fi
        fi
        exit 1
    fi

    echo "   ✓ Signature database loaded."

    rm -f "$TMP_CFG"

    cp "$CFG_FILE" "$BAK_FILE" 2>/dev/null
    echo "   ✓ Backup updated: $(basename "$BAK_FILE")"

    KS_BASENAME=$(basename "$KEYSTORE")
    FOUND_DIR=""

    if [ ! -f "$KEYSTORE" ]; then
        echo "⚠️  Warning：Not found Keystore file：$KEYSTORE"
        if [ -d "$LIB_DIR" ]; then
            for d in "$LIB_DIR"/*/; do
                if [ -f "${d}${KS_BASENAME}.qms-librarybak" ] || [ -f "${d}${KS_BASENAME}.qms-librarybak.enc" ]; then
                    FOUND_DIR="$d"
                    break
                fi
            done
        fi

        if [ -n "$FOUND_DIR" ]; then
            echo "📂 Library backup found: ${FOUND_DIR}${KS_BASENAME}"
            RECOVERED=0
            if [ -f "${FOUND_DIR}${KS_BASENAME}.qms-librarybak.enc" ]; then
                TMP_KS=$(mktemp 2>/dev/null || echo "/tmp/qms_ks_$$")
                ATTEMPTS=0
                while [ $ATTEMPTS -lt 3 ]; do
                    read -r -s -p "🔐 Library backup password: " LIB_PASS
                    echo ""
                    if decrypt_file "${FOUND_DIR}${KS_BASENAME}.qms-librarybak.enc" "$TMP_KS" "$LIB_PASS"; then
                        RECOVERED=1
                        break
                    fi
                    ATTEMPTS=$((ATTEMPTS + 1))
                    echo "❌ Error: Wrong password! ($ATTEMPTS/3)"
                done
                if [ $RECOVERED -eq 1 ]; then
                    read -r -p "🔄 Restore core library? (y/n): " ans
                    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
                        mkdir -p "$(dirname "$KEYSTORE")" 2>/dev/null
                        cp "$TMP_KS" "$KEYSTORE"
                        echo "   ✓ Core library restored: $KEYSTORE"
                    else
                        rm -f "$TMP_KS"
                        exit 1
                    fi
                fi
                rm -f "$TMP_KS"
            elif [ -f "${FOUND_DIR}${KS_BASENAME}.qms-librarybak" ]; then
                read -r -p "🔄 Library backup found. Restore core library? (y/n): " ans
                if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
                    mkdir -p "$(dirname "$KEYSTORE")" 2>/dev/null
                    cp "${FOUND_DIR}${KS_BASENAME}.qms-librarybak" "$KEYSTORE"
                    echo "   ✓ Core library restored: $KEYSTORE"
                else
                    exit 1
                fi
            fi
        fi
    else
        mkdir -p "$LIB_DIR" 2>/dev/null
        RAND_ID=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 64)
        NEW_LIB="${LIB_DIR}/${RAND_ID}"
        mkdir -p "$NEW_LIB"

        if [ -n "$MASTER_PASS" ]; then
            encrypt_file "$KEYSTORE" "${NEW_LIB}/${KS_BASENAME}.qms-librarybak.enc" "$MASTER_PASS"
            chmod 600 "${NEW_LIB}/${KS_BASENAME}.qms-librarybak.enc" 2>/dev/null
            echo "   ✓ Library backup encrypted (Argon2id + AES-256): $RAND_ID"
        else
            cp "$KEYSTORE" "${NEW_LIB}/${KS_BASENAME}.qms-librarybak"
            chmod 600 "${NEW_LIB}/${KS_BASENAME}.qms-librarybak" 2>/dev/null
            echo "   ✓ Library backup stored: $RAND_ID"
        fi

        for d in "$LIB_DIR"/*/; do
            if [ -d "$d" ] && [ "$d" != "${NEW_LIB}/" ]; then
                rm -rf "$d"
            fi
        done
    fi
else
    echo "🔧 First run：Please fill in the signature configuration information"
    echo ""

    read -r -p "🔑 Keystore full path: " KEYSTORE
    read -r -p "🏷️  Alias       : " ALIAS
    read -r -s -p "🔒 Keystore password     : " STORE_PASS
    echo ""
    read -r -s -p "🔑 Key password          : " KEY_PASS
    echo ""

    KEYSTORE="${KEYSTORE%\"}"; KEYSTORE="${KEYSTORE#\"}"
    ALIAS="${ALIAS%\"}";       ALIAS="${ALIAS#\"}"

    if [ -z "$KEYSTORE" ] || [ -z "$ALIAS" ] || [ -z "$STORE_PASS" ] || [ -z "$KEY_PASS" ]; then
        echo "❌ Error：Configuration information cannot be empty!"
        exit 1
    fi

    if [ ! -f "$KEYSTORE" ]; then
        echo "⚠️  Warning：Not found Keystore file：$KEYSTORE"
    fi

    echo ""
    read -r -s -p "🔐 Set master password (leave empty to skip encryption): " MASTER_PASS
    echo ""

    RAND_STR=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 32)
    TIMESTAMP=$(date +%s)
    CFG_FILE="$SCRIPT_DIR/${RAND_STR}${TIMESTAMP}.qms-cfgenv"

    TMP_CFG=$(mktemp 2>/dev/null || echo "/tmp/qms_cfg_$$")
    cat > "$TMP_CFG" <<EOF
KEYSTORE=$KEYSTORE
ALIAS=$ALIAS
STORE_PASS=$STORE_PASS
KEY_PASS=$KEY_PASS
EOF

    if [ -n "$MASTER_PASS" ]; then
        encrypt_file "$TMP_CFG" "$CFG_FILE" "$MASTER_PASS"
        echo "   ✓ Configuration saved with Argon2id + AES-256 encryption."
    else
        cp "$TMP_CFG" "$CFG_FILE"
        echo "   ✓ Configuration saved (unencrypted)."
    fi
    rm -f "$TMP_CFG"

    chmod 600 "$CFG_FILE" 2>/dev/null

    echo "   ✓ Configuration saved.：$(basename "$CFG_FILE")"
    echo "   （It will be automatically read during the next run, no need to fill it in again.）"
fi

echo ""

echo "=========================================="
echo "  Android - Termux Signature tool"
echo "  开发者｜Developer：量方易动工作室 | QuantumMoveStudio"
echo "  官网｜Official website：https://quantummovestudio.dpdns.org"
echo "  合作方镜像站｜Partner mirror site：https://sunworld-fuchuan-technology-organization.dnsglobalnodes.dpdns.org/Resources"
echo "=========================================="
echo ""

read -r -p "📦 Please enter the full path to the APK file: " APK_PATH

APK_PATH="${APK_PATH%\"}"
APK_PATH="${APK_PATH#\"}"

if [ -z "$APK_PATH" ]; then
    echo "❌ Error：APK path not entered"
    exit 1
fi

APK_DIR=$(dirname "$APK_PATH")
APK_NAME=$(basename "$APK_PATH" .apk)
ORIGINAL_APK_FILENAME=$(basename "$APK_PATH")
UNSIGNED_APK="${APK_DIR}/${APK_NAME}_Unsigned.apk"
SIGNED_APK="${APK_DIR}/${APK_NAME}_Signed.apk"
ZIP_FILE="${APK_DIR}/${ORIGINAL_APK_FILENAME}.zip"

if [ ! -f "$APK_PATH" ]; then
    echo "❌ Error：Can't find the APK file!"
    echo "   $APK_PATH"
    exit 1
fi

echo "📦 Source file: $APK_PATH"
echo ""

echo "🗑️ Remove the original signature..."
cp "$APK_PATH" "$UNSIGNED_APK"
zip -q -d "$UNSIGNED_APK" "META-INF/*"
echo "   ✓ OK"

echo "🔏 Sign with a certificate..."
echo "   Keystore: $KEYSTORE"
echo "   Alias   : $ALIAS"
apksigner sign \
    --ks "$KEYSTORE" \
    --ks-key-alias "$ALIAS" \
    --ks-pass pass:"$STORE_PASS" \
    --key-pass pass:"$KEY_PASS" \
    --out "$SIGNED_APK" \
    "$UNSIGNED_APK"

if [ $? -ne 0 ]; then
    echo "   ❌ Signature failed!"
    rm -f "$UNSIGNED_APK"
    exit 1
fi
echo "   ✓ Signature successful"

echo ""
echo "🔍 Verify signature..."
apksigner verify -v "$SIGNED_APK" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "   ✓ Signature verification passed"
else
    echo "   ⚠️ Signature verification failed"
fi

echo ""
echo "🗜️  Packaging the signed APK..."
if ( cd "$APK_DIR" && rm -f "$ZIP_FILE" && zip -q "$ZIP_FILE" "$(basename "$SIGNED_APK")" ); then
    echo "   ✓ Compression package generated successfully."
    echo "   $ZIP_FILE"
else
    echo "   ❌ Compression failed!"
    rm -f "$UNSIGNED_APK"
    exit 1
fi

APK_SHA256=$(sha256sum "$SIGNED_APK" | awk '{print $1}')

CERT_SHA256=$(keytool -printcert -jarfile "$SIGNED_APK" 2>/dev/null | grep "SHA256" | head -1)

ZIP_SHA256=$(sha256sum "$ZIP_FILE" | awk '{print $1}')

rm -f "$SIGNED_APK"
echo "   ✓ Signed APK deleted: $SIGNED_APK"

rm -f "$UNSIGNED_APK"

echo ""
echo "=========================================="
echo "✅ Sign and pack it up！"
echo ""
echo "📁 output file:"
echo "   $ZIP_FILE"
echo ""
echo "📋 certificate fingerprint (SHA256):"
echo "   ${CERT_SHA256:-未获取到}"
echo ""
echo "🔑 Signed APK SHA256:"
echo "   ${APK_SHA256:-未获取到}"
echo ""
echo "🗂️ SHA256 of the compressed package:"
echo "   ${ZIP_SHA256:-未获取到}"
echo "=========================================="
echo "👨‍💻 Powered by QuantumMoveStudio"