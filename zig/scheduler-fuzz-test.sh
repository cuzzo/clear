#!/bin/bash
count=0
while true; do
    count=$((count+1))
    printf "\rRun #$count"

    # Run with TSan for maximum sensitivity
    zig test scheduler-test.zig switch.S -fsanitize-thread -lc > /dev/null 2>&1

    # Check exit code
    if [ $? -ne 0 ]; then
        echo "FAILED on run #$count"
        # Run it one last time with output so you can see the error
        zig test scheduler-test.zig switch.S -fsanitize-thread -lc
        break
    fi
done

