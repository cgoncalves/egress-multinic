#!/bin/bash
echo "--- IP rules (priority 5550) ---"
ip rule show priority 5550

echo ""
echo "--- IP rules (priority 6000) ---"
ip rule show priority 6000

echo ""
echo "--- Routes (main table, non-default) ---"
ip route show table main | grep -v "^default"

echo ""
echo "--- nftables egress-snat ---"
nft list table inet egress-snat 2>/dev/null || echo "(table not found)"

echo ""
echo "--- egress-multinic.service ---"
systemctl is-active egress-multinic.service 2>/dev/null || echo "not running"
