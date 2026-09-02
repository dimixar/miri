#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# These APIs synchronously message a target process (or, for private window-ID
# mapping, have undocumented blocking behavior). Their implementations are
# restricted to the per-PID executor and the cleanup watcher's worker transport.
pattern='AXUIElement(CopyAttributeValue|CopyParameterizedAttributeValue|SetAttributeValue|PerformAction|IsAttributeSettable)|AXObserver(Create|AddNotification)|SkyLight\.shared\.windowID|\b(setAXFrame|setAXPosition|setAXSize|withDisabledEnhancedUserInterface)\('
allowed='Sources/Miri/System/(AXOperationController|Accessibility)\.swift:'

violations="$(rg -n "$pattern" Sources/Miri --glob '*.swift' | grep -Ev "$allowed" || true)"
if [[ -n "$violations" ]]; then
    echo 'Synchronous target-app AX IPC found outside approved worker transports:' >&2
    echo "$violations" >&2
    exit 1
fi

echo 'AX boundary audit passed.'
