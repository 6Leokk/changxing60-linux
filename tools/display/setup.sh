#!/bin/sh
set -e
H=$1
cd /tmp && rm -rf changxing60d && mkdir changxing60d && cd changxing60d
for f in changxing60-display-load changxing60-display.service changxing60-desktop.service changxing60-hdmi-test labwc/autostart; do
    mkdir -p "$(dirname "$f")"; wget -q -O "$f" "http://$H:8100/files/$f"
done
install -m 755 changxing60-display-load /usr/local/sbin/changxing60-display-load
install -m 755 changxing60-hdmi-test /usr/local/bin/changxing60-hdmi-test
install -m 644 changxing60-display.service changxing60-desktop.service /etc/systemd/system/
install -d -o ubuntu -g ubuntu /home/ubuntu/.config/labwc
install -m 644 -o ubuntu -g ubuntu labwc/autostart /home/ubuntu/.config/labwc/autostart
usermod -aG video,input,render ubuntu
systemctl daemon-reload
systemctl enable changxing60-display.service changxing60-desktop.service
sync
echo SETUP-OK
