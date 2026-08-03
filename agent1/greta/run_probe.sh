#!/bin/bash
set -euo pipefail
cd "$HOME/greta-backend/current"
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
eval "$(rbenv init -)"
RAILS_ENV=production bundle exec rails runner /tmp/probe_tracks.rb
