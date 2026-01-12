#!/bin/bash
set -e

# Install Redis client tools
apt-get update
apt-get install -y redis-tools

echo "Redis client tools installed successfully"
