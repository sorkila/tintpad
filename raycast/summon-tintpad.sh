#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Summon Tintpad
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🎨
# @raycast.packageName Tintpad

# Documentation:
# @raycast.description Summon the Tintpad palette. One key. The right repo. Your agent in the terminal.
# @raycast.author Erik Nielsen
# @raycast.authorURL https://sorkila.com

# Try the URL scheme first. Fall back to launching the app.
open "tintpad://" 2>/dev/null || open -a Tintpad
