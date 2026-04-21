#!/bin/bash
#
# Node-level cleanup script. Called by 07-cleanup.sh.

# Stop HTTP listener services
systemctl stop http-server-oam.service 2>/dev/null && echo "Stopped http-server-oam" || true
systemctl stop http-server-signaling.service 2>/dev/null && echo "Stopped http-server-signaling" || true
systemctl reset-failed http-server-oam.service 2>/dev/null || true
systemctl reset-failed http-server-signaling.service 2>/dev/null || true
rm -f /usr/local/bin/http-echo-server.py

# Remove network namespaces and veth pairs
ip netns del oam 2>/dev/null && echo "Removed netns oam" || true
ip netns del signaling 2>/dev/null && echo "Removed netns signaling" || true
ip link del oam-host 2>/dev/null && echo "Removed veth oam-host" || true
ip link del sig-host 2>/dev/null && echo "Removed veth sig-host" || true
