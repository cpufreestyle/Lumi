#!/bin/bash
set -e
cd "/Users/a1-6/AI Shared/repo/Lumi"
rm -f Lumi-v1.1.2.zip
ditto -c -k --keepParent "Lumi/.build/Lumi.app" Lumi-v1.1.2.zip
ls -lh Lumi-v1.1.2.zip
echo "DONE_ZIP"
