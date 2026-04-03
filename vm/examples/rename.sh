#! /usr/bin/env bash

for i in $(find . -iname "*.flux"); do
    git mv "$i" "$(echo $i | rev | cut -d '.' -f 2- | rev).cht";
done
