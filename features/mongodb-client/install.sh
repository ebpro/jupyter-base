#!/usr/bin/env bash
set -euo pipefail

# MongoDB Client Tools Installation
# Installs mongosh, mongoimport, mongoexport, mongodump, mongorestore

VERSION="${VERSION:-8.0}"

echo "===================================================================="
echo "Feature: MongoDB Client Tools"
echo "===================================================================="
echo "MongoDB Version: ${VERSION}"
echo "===================================================================="

# Resolve version from centralized versions.json if available
resolve_version() {
  local tool="$1"
  local default="$2"
  
  # Try feature-specific versions.json first
  if [ -f "/tmp/artefacts/mongodb-client/versions.json" ]; then
    local ver=$(jq -r ".tools[\"${tool}\"] // empty" "/tmp/artefacts/mongodb-client/versions.json" 2>/dev/null || true)
    if [ -n "$ver" ] && [ "$ver" != "null" ]; then
      echo "$ver"
      return
    fi
  fi
  
  # Try central versions.json
  if [ -f "/tmp/Artefacts/versions.json" ]; then
    local ver=$(jq -r ".tools[\"${tool}\"] // empty" "/tmp/Artefacts/versions.json" 2>/dev/null || true)
    if [ -n "$ver" ] && [ "$ver" != "null" ]; then
      echo "$ver"
      return
    fi
  fi
  
  # Fallback to default
  echo "$default"
}

# Determine actual MongoDB version
if [ "${VERSION}" = "latest" ]; then
    MONGO_VERSION=$(resolve_version "mongodb" "8.0")
else
    MONGO_VERSION=$(resolve_version "mongodb" "${VERSION}")
fi

echo "📦 Adding MongoDB APT repository (version ${MONGO_VERSION})..."

# Install prerequisites
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Modern GPG keyring approach (replaces deprecated apt-key)
curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGO_VERSION}.asc" | \
  gpg --dearmor -o "/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg"

echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/${MONGO_VERSION} multiverse" | \
    tee "/etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list" > /dev/null

apt-get update -qq

echo "📦 Installing MongoDB ${MONGO_VERSION} client tools..."

# Install MongoDB client tools
apt-get install -y --no-install-recommends \
    mongodb-mongosh \
    mongodb-database-tools

# Create MongoDB client configuration directory
mkdir -p ~/.mongodb
cat > ~/.mongorc.js << 'EOF'
// MongoDB shell configuration
print("MongoDB shell configured with helpful defaults");
print("- Pretty print enabled");
print("- Autocomplete enabled");
EOF

# Verify installation
echo ""
echo "✅ Verifying MongoDB client installation..."
mongosh --version
mongoimport --version
mongoexport --version
mongodump --version

echo ""
echo "✅ MongoDB client tools installed successfully!"
echo ""
echo "Available commands:"
echo "  - mongosh: Interactive MongoDB shell"
echo "  - mongoimport: Import data into MongoDB"
echo "  - mongoexport: Export MongoDB data"
echo "  - mongodump: Create binary database backups"
echo "  - mongorestore: Restore MongoDB databases"
echo ""
echo "Example usage:"
echo "  mongosh 'mongodb://localhost:27017/mydb'"
echo "  mongoimport --db mydb --collection users --file users.json"
echo "  mongodump --db mydb --out /backup/"
