#!/bin/bash
# Semantic analyzer test runner
# Each .is file has a first-line comment:
#   # EXPECT ERROR: <substring>  — must fail with output containing substring
#   # EXPECT OK: ...             — must pass (exit 0)

IRISC="src/irisc"
PASS=0
FAIL=0

for f in tests/sema_*.is; do
  first_line=$(head -1 "$f")
  name=$(basename "$f")

  if [[ "$first_line" == *"EXPECT ERROR:"* ]]; then
    expected_substr=$(echo "$first_line" | sed 's/.*EXPECT ERROR: //')
    output=$($IRISC check "$f" 2>&1)
    exit_code=$?
    if [[ $exit_code -ne 0 ]] && [[ "$output" == *"$expected_substr"* ]]; then
      echo "PASS  $name"
      ((PASS++))
    else
      echo "FAIL  $name (expected error containing '$expected_substr', got exit=$exit_code: $output)"
      ((FAIL++))
    fi

  elif [[ "$first_line" == *"EXPECT OK:"* ]]; then
    output=$($IRISC check "$f" 2>&1)
    exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
      echo "PASS  $name"
      ((PASS++))
    else
      echo "FAIL  $name (expected OK, got exit=$exit_code: $output)"
      ((FAIL++))
    fi

  else
    echo "SKIP  $name (no EXPECT directive)"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
