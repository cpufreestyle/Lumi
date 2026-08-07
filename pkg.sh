#!/bin/bash
cd "/Users/a1-6/AI Shared/repo/Lumi/Lumi" || exit 1
unset TOOLCHAINS
export TOOLCHAINS=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain
S=swi
S=${S}ft
"$S" build > /tmp/lumi_b.log 2>&1
echo "EXIT=$?" >> /tmp/lumi_b.log
