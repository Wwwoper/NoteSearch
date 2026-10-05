#!/bin/bash
# NoteSearch — Release pipeline для распространения вне App Store.
#
# Использование:
#   bash scripts/release.sh
#   bash scripts/release.sh --skip-tests
#   VERSION=1.0.1 bash scripts/release.sh
#
# Результат:
#   dist/NoteSearch-<version>-arm64.zip
#   dist/NoteSearch-<version>-arm64.dmg
#   dist/SHA256SUMS.txt

set -euo pipefail

PROJECT="NoteSearch.xcodeproj"
SCHEME="NoteSearch"
APP_NAME="NoteSearch"
ARCH="arm64"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f "$PROJECT/project.pbxproj" ]; then
  echo "Ошибка: не найден $PROJECT. Запусти скрипт из репозитория NoteSearch." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Ошибка: xcodebuild не найден. Установи полный Xcode." >&2
  exit 1
fi

SKIP_TESTS=false

for arg in "$@"; do
  case "$arg" in
    --skip-tests)
      SKIP_TESTS=true
      ;;
    *)
      echo "Неизвестный аргумент: $arg" >&2
      exit 1
      ;;
  esac
done

BUILD_SETTINGS="$(
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -showBuildSettings 2>/dev/null
)"

MARKETING_VERSION="$(
  printf '%s\n' "$BUILD_SETTINGS" |
    awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / { print $2; exit }'
)"

BUILD_NUMBER="$(
  printf '%s\n' "$BUILD_SETTINGS" |
    awk -F ' = ' '/^[[:space:]]*CURRENT_PROJECT_VERSION = / { print $2; exit }'
)"

BUNDLE_ID="$(
  printf '%s\n' "$BUILD_SETTINGS" |
    awk -F ' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = / { print $2; exit }'
)"

VERSION="${VERSION:-$MARKETING_VERSION}"

if [ -z "$VERSION" ] || [ -z "$BUNDLE_ID" ]; then
  echo "Ошибка: не удалось получить версию или Bundle ID из Xcode." >&2
  exit 1
fi

if [ "$SKIP_TESTS" = false ]; then
  echo "==> Запуск автотестов"

  swift test
fi

echo "==> Очистка старых артефактов"

rm -rf build/release
rm -rf dist
mkdir -p build/release dist

echo "==> Release-сборка"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath build/release \
  ARCHS="$ARCH" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="build/release/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "$APP" ]; then
  echo "Ошибка: приложение не найдено после сборки: $APP" >&2
  exit 1
fi

EXECUTABLE="$APP/Contents/MacOS/$APP_NAME"

if [ ! -f "$EXECUTABLE" ]; then
  echo "Ошибка: executable не найден: $EXECUTABLE" >&2
  exit 1
fi

ACTUAL_ARCHS="$(lipo -archs "$EXECUTABLE")"

if [ "$ACTUAL_ARCHS" != "$ARCH" ]; then
  echo "Ошибка: ожидалась архитектура $ARCH, получено: $ACTUAL_ARCHS" >&2
  exit 1
fi

echo "==> Ad-hoc подпись"

codesign \
  --force \
  --deep \
  --sign - \
  "$APP"

echo "==> Проверка подписи"

codesign \
  --verify \
  --deep \
  --strict \
  --verbose=2 \
  "$APP"

SIGNATURE_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"

if ! printf '%s\n' "$SIGNATURE_INFO" | grep -q "Signature=adhoc"; then
  echo "Ошибка: приложение не имеет ожидаемой ad-hoc подписи." >&2
  printf '%s\n' "$SIGNATURE_INFO" >&2
  exit 1
fi

PLIST="$APP/Contents/Info.plist"

ACTUAL_BUNDLE_ID="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST"
)"

ACTUAL_VERSION="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST"
)"

if [ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]; then
  echo "Ошибка: Bundle ID в собранном приложении не совпадает." >&2
  echo "Ожидалось: $BUNDLE_ID" >&2
  echo "Получено: $ACTUAL_BUNDLE_ID" >&2
  exit 1
fi

if [ "$ACTUAL_VERSION" != "$VERSION" ]; then
  echo "Ошибка: версия в собранном приложении не совпадает." >&2
  echo "Ожидалось: $VERSION" >&2
  echo "Получено: $ACTUAL_VERSION" >&2
  exit 1
fi

APP_SIZE_BYTES="$(du -sk "$APP" | awk '{print $1 * 1024}')"

echo "==> Упаковка ZIP"

ZIP="dist/${APP_NAME}-${VERSION}-${ARCH}.zip"

ditto \
  -c \
  -k \
  --keepParent \
  "$APP" \
  "$ZIP"

ZIP_SIZE_BYTES="$(du -sk "$ZIP" | awk '{print $1 * 1024}')"

echo "==> Создание DMG"

DMG_STAGE="build/dmg-stage"
DMG="dist/${APP_NAME}-${VERSION}-${ARCH}.dmg"

rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"

ditto "$APP" "$DMG_STAGE/${APP_NAME}.app"

ln -s /Applications "$DMG_STAGE/Applications"

cat > "$DMG_STAGE/Прочитайте.txt" <<EOF
NoteSearch ${VERSION}
====================

1. Перетащите NoteSearch.app в папку Applications.
2. При первом запуске macOS может сообщить, что приложение не подписано
   сертификатом Apple Developer.
3. Откройте System Settings → Privacy & Security и нажмите Open Anyway
   в сообщении о NoteSearch.
4. При первом выборе папки разрешите приложению доступ к ней.

Требования:
- macOS 14 или новее
- Apple Silicon (M1/M2/M3/M4)
EOF

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

DMG_SIZE_BYTES="$(du -sk "$DMG" | awk '{print $1 * 1024}')"

rm -rf "$DMG_STAGE"

echo "==> Контрольные суммы"

(
  cd dist
  shasum -a 256 \
    "${APP_NAME}-${VERSION}-${ARCH}.zip" \
    "${APP_NAME}-${VERSION}-${ARCH}.dmg" \
    > SHA256SUMS.txt
)

echo
echo "=========================================="
echo "Release готов"
echo "=========================================="
echo "Версия:             $VERSION ($BUILD_NUMBER)"
echo "Bundle ID:          $BUNDLE_ID"
echo "Архитектура:        $ACTUAL_ARCHS"
echo "Размер .app:        $APP_SIZE_BYTES байт"
echo "ZIP:                $ZIP ($ZIP_SIZE_BYTES байт)"
echo "DMG:                $DMG ($DMG_SIZE_BYTES байт)"
echo "Контрольные суммы:  dist/SHA256SUMS.txt"
echo
echo "Проверить локально:"
echo "  open \"$APP\""
echo
echo "Проверить ZIP:"
echo "  cd dist && shasum -a 256 -c SHA256SUMS.txt"
echo
echo "Важно: это ad-hoc сборка без Developer ID и нотаризации."
echo "После скачивания macOS может потребовать Open Anyway"
echo "в System Settings → Privacy & Security."
