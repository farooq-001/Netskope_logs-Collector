#!/bin/bash

echo "🔐 Fill the Netskope-API Keys:"

# Prompt for required values
read -p "Enter API_TOKEN: " API_TOKEN
read -p "Enter TENANT_HOSTNAME: " TENANT_HOSTNAME

echo "🧭 Fill the Filebeat Configuration:"
read -p "Enter SENSOR_ID: " SENSOR_ID
read -p "Enter CLIENT_ID: " CLIENT_ID
read -p "Enter REMOTE_HOST: " REMOTE_HOST
read -p "Enter PORT: " PORT

# Display inputs
echo ""
echo "🔐 Netskope-API Keys"
echo "API_TOKEN        : $API_TOKEN"
echo "TENANT_HOSTNAME  : $TENANT_HOSTNAME"
echo ""
echo "🧭 Filebeat Configuration"
echo "SENSOR_ID        : $SENSOR_ID"
echo "CLIENT_ID        : $CLIENT_ID"
echo "REMOTE_HOST      : $REMOTE_HOST"
echo "PORT             : $PORT"
echo ""

# Confirm installation
read -p "Proceed with installation? (y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "❌ Installation cancelled."
    exit 1
fi

# Create user if not exists
if ! id "blusapphire" &>/dev/null; then
    useradd -r -s /bin/false blusapphire
fi

# Create Directory
mkdir -p /opt/blusapphire/Netskope
chown -R blusapphire:blusapphire /opt/blusapphire

# Create Python script
cat <<EOF > /opt/blusapphire/Netskope/script.py
import requests
import time
import json
import logging
import os
from logging.handlers import RotatingFileHandler
import argparse
 
# === COMMAND-LINE ARGUMENT PARSING ===
parser = argparse.ArgumentParser(description="Netskope Audit Log Collector")
 
parser.add_argument("--limit", type=int, default=500, help="Number of records to fetch per API call")
parser.add_argument("--poll-interval", type=int, default=300, help="Polling interval in seconds")
parser.add_argument("--file-count", type=int, default=5, help="Number of rotated log files to keep")
parser.add_argument("--max-file-size", type=int, default=10 * 1024 * 1024, help="Max log file size in bytes")
 
args = parser.parse_args()
 
 
# === CONFIGURATION (From arguments or default) ===
LIMIT = args.limit
POLL_INTERVAL = args.poll_interval
FILE_COUNT = args.file_count
MAX_FILE_SIZE = args.max_file_size
 
 
# === CONFIGURATION ===
API_TOKEN = "${API_TOKEN}"
TENANT_HOSTNAME = "${TENANT_HOSTNAME}"
CHECKPOINT_FILE = "netskope_checkpoint.json"
# LIMIT = 500
# POLL_INTERVAL = 300  # 5 minutes
# FILE_COUNT = 5
# MAX_FILE_SIZE = 10 * 1024 * 1024 #10MB
 
 
# Optional proxy if needed
PROXIES = {}
 
# === LOGGING SETUP WITH ROTATION ===
# === LOGGING SETUP ===
log_formatter = logging.Formatter("%(message)s")
 
# File handler ONLY for process_data logger
file_handler = RotatingFileHandler(
    "netskope_auditlogs.log", maxBytes=MAX_FILE_SIZE, backupCount=FILE_COUNT
)
file_handler.setFormatter(log_formatter)
file_handler.setLevel(logging.INFO)
 
# Console handler (for general info messages)
console_handler = logging.StreamHandler()
console_handler.setFormatter(log_formatter)
console_handler.setLevel(logging.INFO)
 
# Main logger (console only)
main_logger = logging.getLogger("main_logger")
main_logger.setLevel(logging.INFO)
main_logger.addHandler(console_handler)
main_logger.propagate = False
 
# Dedicated logger for process_data (file only)
data_logger = logging.getLogger("data_logger")
data_logger.setLevel(logging.INFO)
data_logger.addHandler(file_handler)
data_logger.propagate = False
 
 
def load_checkpoint():
    if os.path.exists(CHECKPOINT_FILE):
        with open(CHECKPOINT_FILE, "r") as f:
            return json.load(f)
    else:
        # Default start: now - 5 minutes
        current_time = int(time.time())
        #current_time = 1743465600 #for testing 
        return {"starttime": current_time - POLL_INTERVAL, "offset": 0}
 
def save_checkpoint(starttime, offset):
    with open(CHECKPOINT_FILE, "w") as f:
        json.dump({"starttime": starttime, "offset": offset}, f)
 
        
def fetch_audit_logs(starttime, offset):
    endtime = int(time.time())
    url = f"https://{TENANT_HOSTNAME}/api/v2/events/data/audit"
    headers = {
        "Authorization": f"Bearer {API_TOKEN}"
    }
    params = {
        "limit": LIMIT,
        "offset": offset,
        "starttime": starttime,
        "endtime": endtime
    }
 
    main_logger.info(f"Fetching audit logs | starttime: {starttime}, endtime: {endtime}, offset: {offset}")
 
    try:
        response = requests.get(url, headers=headers, params=params, proxies=PROXIES)
        response.raise_for_status()
        return response.json(), endtime
    except requests.RequestException as e:
        logging.error(f"Error fetching audit logs: {str(e)}")
        return None, endtime
 
def process_data(records):
    for record in records:
        # Example: Print record to console
        data_logger.info(json.dumps(record))  # Only these go to file
        # You could forward to Splunk, save to DB, write to file, etc.
 
def main():
    while True:
        checkpoint = load_checkpoint()
        starttime = checkpoint["starttime"]
        offset = checkpoint.get("offset", 0)
 
        data, new_endtime = fetch_audit_logs(starttime, offset)
 
        if data and "result" in data and data["result"]:
            records = data["result"]
            process_data(records)
 
            # If we got fewer results than the limit, assume we're done with this window
            if len(records) < LIMIT:
                save_checkpoint(new_endtime, 0)
                main_logger.info("All records pulled. Moving to next polling window.")
                time.sleep(POLL_INTERVAL)
            else:
                # More data likely exists — increment offset
                new_offset = offset + LIMIT
                save_checkpoint(starttime, new_offset)
                main_logger.info("More records exist. Continuing with next offset.")
        else:
            # No new data, move to next polling window
            main_logger.info("No new records. Advancing time window.")
            save_checkpoint(new_endtime, 0)
            time.sleep(POLL_INTERVAL)
 
if __name__ == "__main__":
    main()

EOF

# Create systemd service file
cat <<EOF > /etc/systemd/system/netskope.service
[Unit]
Description=Netskope Audit Log Collector
After=network.target

[Service]
Type=simple
User=blusapphire
WorkingDirectory=/opt/blusapphire/Netskope
ExecStart=/usr/bin/python3 /opt/blusapphire/Netskope/script.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Create Filebeat config
cat <<EOF > /opt/blusapphire/Netskope/filebeat.yaml
##################### Filebeat Configuration - Netskope #########################

filebeat.inputs:
  - type: log
    enabled: true
    paths:
      - "/opt/blusapphire/Netskope/*.log"
    close_inactive: 10s
    scan_frequency: 60s
    fields:
      log.type: "netskope"
      sensor_id: "${SENSOR_ID}"
      client_id: "${CLIENT_ID}"
    fields_under_root: true

filebeat.registry.path: "/opt/blusapphire/conf/etc/registry/netskope"

filebeat.config.modules:
  path: \${path.config}/modules.d/*.yml
  reload.enabled: true
  reload.period: 60s

output.logstash:
  hosts: ["${REMOTE_HOST}:${PORT}"]
  loadbalance: true
  worker: 5
  bulk_max_size: 8192

logging.level: info
logging.to_files: true
logging.files:
  path: "/var/log/filebeat"
  name: "netskope"
  keepfiles: 7
  permissions: 0644

logging.metrics:
  enabled: true
  period: 60s

queue.mem:
  events: 4096
  flush.min_events: 512
  flush.timeout: 1s
EOF

# Set ownership
chown -R blusapphire:blusapphire /opt/blusapphire

# Reload systemd and start service
systemctl daemon-reload
systemctl enable netskope.service
systemctl start netskope.service

echo "✅ netskope service installed and started."
