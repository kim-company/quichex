#!/bin/bash
# Compare packet flow between quiche client and our client

echo "=== Running quiche client ==="
timeout 2 /Users/dmorn/projects/quiche/target/debug/examples/client https://127.0.0.1:4433/index.html 2>&1 > /tmp/quiche_client_output.txt
echo "Quiche client output:"
cat /tmp/quiche_client_output.txt

echo ""
echo "=== Running our client ==="
timeout 2 mix run scripts/test_simple.exs 2>&1 > /tmp/our_client_output.txt
echo "Our client output:"
cat /tmp/our_client_output.txt | grep -v "\[NIF\]"

echo ""
echo "=== Comparison ==="
echo "Quiche client received HTML: $(grep -c 'html>' /tmp/quiche_client_output.txt) times"
echo "Our client received data: $(grep -c 'Got message.*quic_stream' /tmp/our_client_output.txt) times"
