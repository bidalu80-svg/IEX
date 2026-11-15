#!/usr/bin/env bash
set -euo pipefail
# Exercise the complete app. Component fixtures do not prove header composition.
: "${ZE_SHARE_SEARCH_SIM_APP:?Build the complete simulator application first}"
export ZE_VERIFY_SOUL_HEADER=1
export ZE_SIMULATOR_IOS_MAJOR=26
bash scripts/test-chat-layout-application.sh
