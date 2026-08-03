#!/bin/bash
# Provision PostgreSQL for agent1 and point systemd at DATABASE_URL.
set -euo pipefail
PASS="${1:?sudo password}"
DB_PASS="${2:?db password}"

echo "$PASS" | sudo -S apt-get update -qq
echo "$PASS" | sudo -S DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql postgresql-contrib

echo "$PASS" | sudo -S systemctl enable --now postgresql

# create role/db if missing
echo "$PASS" | sudo -S -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'agent1') THEN
    CREATE ROLE agent1 LOGIN PASSWORD '${DB_PASS}';
  ELSE
    ALTER ROLE agent1 WITH LOGIN PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;
SELECT 'ok_role';
SQL

echo "$PASS" | sudo -S -u postgres psql -v ON_ERROR_STOP=1 -c "SELECT 1 FROM pg_database WHERE datname='agent1'" | grep -q 1 \
  || echo "$PASS" | sudo -S -u postgres createdb -O agent1 agent1

# allow local md5/scram for agent1
# ensure pg_hba has scram for local connections — default ubuntu usually ok for 127.0.0.1

ENV_FILE=/home/admin-akea/agent1/.env
umask 077
cat > "$ENV_FILE" <<EOF
AGENT1_HOME=/home/admin-akea/agent1
AGENT1_DATABASE_URL=postgresql://agent1:${DB_PASS}@127.0.0.1:5432/agent1
EOF
chmod 600 "$ENV_FILE"

# patch systemd units to load EnvironmentFile
for unit in agent1-api agent1-worker; do
  echo "$PASS" | sudo -S tee /etc/systemd/system/${unit}.service >/dev/null <<EOF
[Unit]
Description=Agent1 ${unit}
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=admin-akea
WorkingDirectory=/home/admin-akea/agent1/app
EnvironmentFile=/home/admin-akea/agent1/.env
Environment=PATH=/home/admin-akea/agent1/venv/bin:/usr/bin
Environment=AGENT1_API=http://127.0.0.1:8101
Environment=AGENT1_WORKER_ID=worker-1
ExecStart=/home/admin-akea/agent1/venv/bin/$([ "$unit" = agent1-api ] && echo 'uvicorn main:app --host 127.0.0.1 --port 8101' || echo 'python worker.py')
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
done

# Fix ExecStart properly (the ternary above in heredoc is messy) — rewrite explicitly
echo "$PASS" | sudo -S tee /etc/systemd/system/agent1-api.service >/dev/null <<'EOF'
[Unit]
Description=Agent1 control plane (postgres)
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=admin-akea
WorkingDirectory=/home/admin-akea/agent1/app
EnvironmentFile=/home/admin-akea/agent1/.env
Environment=PATH=/home/admin-akea/agent1/venv/bin:/usr/bin
ExecStart=/home/admin-akea/agent1/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8101
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "$PASS" | sudo -S tee /etc/systemd/system/agent1-worker.service >/dev/null <<'EOF'
[Unit]
Description=Agent1 shadow worker
After=network.target agent1-api.service postgresql.service
Requires=agent1-api.service

[Service]
Type=simple
User=admin-akea
WorkingDirectory=/home/admin-akea/agent1/app
EnvironmentFile=/home/admin-akea/agent1/.env
Environment=AGENT1_API=http://127.0.0.1:8101
Environment=AGENT1_WORKER_ID=worker-1
Environment=PATH=/home/admin-akea/agent1/venv/bin:/usr/bin
ExecStart=/home/admin-akea/agent1/venv/bin/python worker.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cd /home/admin-akea/agent1
./venv/bin/pip install -q -r app/requirements.txt

echo "$PASS" | sudo -S systemctl daemon-reload
echo "$PASS" | sudo -S systemctl restart postgresql
echo "$PASS" | sudo -S systemctl restart agent1-api agent1-worker
sleep 2
curl -sS http://127.0.0.1:8101/api/health
echo
./venv/bin/python app/seed_run.py
sleep 3
curl -sS http://127.0.0.1:8101/api/status
echo
echo PG_OK
