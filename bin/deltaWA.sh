#!/bin/bash

# define variables
WORKDIR="/srv/portals/ulbbnepflicht/danrw-sip"

# find all Delta files and rename these files
find $WORKDIR -name '*gen*.zip'  -printf "%f\n" | { while read -r DeltaFile
do
  echo "Found Delta file: $DeltaFile"
  mv $WORKDIR/$DeltaFile $WORKDIR/$DeltaFile.delta
done
}
