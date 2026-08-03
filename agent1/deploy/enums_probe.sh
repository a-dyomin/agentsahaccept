#!/bin/bash
set +e
ssh -i ~/.ssh/greta_ro -p 34023 -o IdentitiesOnly=yes -o BatchMode=yes gretaadmin@greta.akea-ds.ru \
  'cat > ~/agent1_export/enums_probe.rb <<'"'"'RUBY'"'"'
day = Date.parse("2026-07-12")
puts "site_stypes=" + Site.kept.joins("INNER JOIN orders ON orders.site_id = sites.id").where(orders: { date: day }).distinct.pluck(:stype).inspect
puts "waste=" + WasteType.pluck(:id, :name).inspect
puts "states=" + Order.kept.where(date: day).group(:state).count.inspect
puts "sample_sites=" + Site.kept.where.not(stype: nil).limit(10).pluck(:id, :stype, :address).inspect
RUBY
cd ~/greta-backend/current && export PATH=$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH && eval "$(rbenv init -)" && RAILS_ENV=production bundle exec rails runner ~/agent1_export/enums_probe.rb'
