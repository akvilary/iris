#!/bin/bash
# Test runner for Iris compiler
# Each .is file has first-line comment(s):
#   # EXPECT ERROR: <substring>  — must fail with output containing substring
#   # EXPECT OK: ...             — must pass (exit 0)
#   # EXPECT C: <substring>      — generated C must contain substring
#   # EXPECT RUN: <substring>    — program output must contain substring

IRISC="./irisc"
PASS=0
FAIL=0

for f in tests/*.is; do
  name=$(basename "$f")
  first_line=$(head -1 "$f")

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

  elif [[ "$first_line" == *"EXPECT C:"* ]]; then
    # Check generated C for expected patterns (one per # EXPECT C: line)
    c_output=$($IRISC emit "$f" 2>&1)
    emit_code=$?
    if [[ $emit_code -ne 0 ]]; then
      echo "FAIL  $name (emit failed: $c_output)"
      ((FAIL++))
      continue
    fi
    all_ok=true
    while IFS= read -r line; do
      if [[ "$line" == "# EXPECT C:"* ]]; then
        expected=$(echo "$line" | sed 's/^# EXPECT C: //')
        if [[ "$c_output" != *"$expected"* ]]; then
          echo "FAIL  $name (expected C to contain '$expected')"
          all_ok=false
          break
        fi
      fi
    done < "$f"
    if $all_ok; then
      echo "PASS  $name"
      ((PASS++))
    else
      ((FAIL++))
    fi

  elif [[ "$first_line" == *"EXPECT RUN:"* ]]; then
    expected_substr=$(echo "$first_line" | sed 's/.*EXPECT RUN: //')
    output=$($IRISC run "$f" 2>&1)
    exit_code=$?
    if [[ $exit_code -eq 0 ]] && [[ "$output" == *"$expected_substr"* ]]; then
      echo "PASS  $name"
      ((PASS++))
    else
      echo "FAIL  $name (expected output containing '$expected_substr', got exit=$exit_code: $output)"
      ((FAIL++))
    fi

  else
    echo "SKIP  $name (no EXPECT directive)"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
