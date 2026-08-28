#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS Post-Install 02d — Russian Locale (optional, personal preference)
# ============================================================================
# Run this ON THE PI. Nothing else in MolniyaOS depends on it, and nothing breaks
# if you never run it — it is the author's preference, not an SDR feature.
#
# WHAT THIS DOES:
#   Sets the system language to Russian for all non-input-dependent output.
#   Menu text, status messages, date/time formatting → Russian.
#   Commands, file paths, config syntax → always English (they're binary names).
#
#   Setting LANG=ru_RU.UTF-8 tells programs: "if you have a Russian translation
#   for this output string, use it." Programs without translations (most SDR
#   tools) silently fall back to English. No commands change.
#
# TO UNDO:
#   sudo localectl set-locale LANG=en_US.UTF-8
# ============================================================================

set -euo pipefail

echo ""
echo "[1/1] Configuring Russian locale..."

# Install locale packages and Russian fonts
sudo apt-get install -y \
    locales \
    fonts-dejavu-core \
    fonts-liberation2 \
    console-cyrillic

# Install Russian man pages (translations of standard Linux man pages)
sudo apt-get install -y manpages-ru 2>/dev/null || \
    echo "       (manpages-ru not available in repo — skipping)"

# Generate the ru_RU.UTF-8 locale
# This is like adding a language pack — it creates the translation database
# the system references when LANG is set to Russian.
sudo sed -i 's/# ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
echo "ru_RU.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen > /dev/null 2>/dev/null
sudo locale-gen

# Set Russian as the system default
# localectl writes to /etc/default/locale which is read at login time.
# This persists across reboots.
sudo localectl set-locale LANG=ru_RU.UTF-8

# Also set it for the current session so verification works immediately
export LANG=ru_RU.UTF-8

echo "       Russian locale configured."
echo "       Date test: $(date '+%A, %d %B %Y г.')"
echo ""
echo "       NOTE on HDMI console Cyrillic:"
echo "         If Cyrillic shows as squares on the HDMI console, run:"
echo "         sudo dpkg-reconfigure console-setup"
echo "         Select: UTF-8 → Guess optimal → Terminus → 8x16"
echo "         SSH terminals handle Cyrillic natively — no config needed."
echo ""
echo "       NOTE: If you need English error messages for Googling errors:"
echo "         export LC_MESSAGES=en_US.UTF-8"
echo "       This overrides just messages while keeping everything else Russian."
