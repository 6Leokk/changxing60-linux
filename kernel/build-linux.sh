#!/bin/bash
# Build the changxing60 Linux kernel: stock F50 config + changxing60-linux.fragment, ThinLTO
set -e
cd /src/zte-u30air
OUT=/src/out-linux
mkdir -p $OUT
# 7552n-port: CROSS_COMPILE=aarch64-linux-gnu- enables the x86_64 cross build
# (route A of docs/changxing60/port-design.md); unset keeps the original arm64-native call.
M="make O=$OUT ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=clang LD=ld.lld ${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE} -j${JOBS:-10}"
cp /work/device.config $OUT/.config
./scripts/config --file $OUT/.config --enable THINLTO
KCONFIG_CONFIG=$OUT/.config ./scripts/kconfig/merge_config.sh -m -O $OUT $OUT/.config /work/changxing60-linux.fragment > /work/merge.log 2>&1
$M olddefconfig
# report fragment options that Kconfig refused (dependency not met / symbol missing)
python3 - <<'P'
import re
want={}
for l in open('/work/changxing60-linux.fragment'):
    m=re.match(r'(CONFIG_[A-Z0-9_]+)=(.*)',l) or re.match(r'# (CONFIG_[A-Z0-9_]+) is not set',l)
    if m: want[m.group(1)]=m.group(2) if m.lastindex==2 else 'n'
got={}
for l in open('/src/out-linux/.config'):
    m=re.match(r'(CONFIG_[A-Z0-9_]+)=(.*)',l) or re.match(r'# (CONFIG_[A-Z0-9_]+) is not set',l)
    if m: got[m.group(1)]=m.group(2) if m.lastindex==2 else 'n'
bad=[f'{k}: want {v} got {got.get(k,"absent")}' for k,v in want.items() if got.get(k,'n' if v=='n' else 'absent')!=v]
open('/work/fragment-rejected.txt','w').write('\n'.join(bad)+'\n'); print('fragment rejected:',len(bad))
P
cp $OUT/.config /work/linux.config
start=$(date +%s)
$M Image modules 2>&1 | grep -E "error|Error|warning: unused|LTO|^make" | tail -40
echo "BUILD_SECONDS $(( $(date +%s) - start ))"
ls -la $OUT/arch/arm64/boot/Image
find $OUT -name "*.ko" | wc -l
