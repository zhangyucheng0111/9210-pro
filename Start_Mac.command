#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$PROJECT_DIR/Mac/9210 Pro Control.app"
if [[ ! -x "$APP/Contents/MacOS/9210ProControl" ]]; then
  bash "$PROJECT_DIR/9210-pro-control/native/build.sh"
fi
open "$APP"
