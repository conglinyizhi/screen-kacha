#!/usr/bin/env bash
# Shared install/uninstall names. Format is source:installed-name where applicable.
SCREEN_KACHA_BINARIES=(
  "main:screen-kacha"
  "tray:screen-kacha-tray"
  "portal:screen-kacha-portal"
  "cursor:screen-kacha-cursor"
)
SCREEN_KACHA_PROCESSES=(
  "screen-kacha-portal-loop"
  "screen-kacha-portal --out"
  "screen-kacha-cursor"
)
SCREEN_KACHA_UNIT_TEMPLATES=(
  "screen-kacha.service.in:screen-kacha.service"
  "screen-kacha-tray.service.in:screen-kacha-tray.service"
)
SCREEN_KACHA_PORTAL_LOOP="screen-kacha-portal-loop"
SCREEN_KACHA_PORTAL_DESKTOP="screen-kacha-portal.desktop"
