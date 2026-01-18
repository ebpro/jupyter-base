#!/usr/bin/env bash
set -euo pipefail

echo "Running java-jdk feature tests"

if command -v java >/dev/null 2>&1; then
  java -version
else
  echo "ERROR: java not found" >&2
  exit 1
fi

if command -v javac >/dev/null 2>&1; then
  javac -version
else
  echo "ERROR: javac not found" >&2
  exit 1
fi

echo "java-jdk feature tests passed"
