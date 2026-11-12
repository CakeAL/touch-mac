#!/system/bin/sh
# 在 root 安卓平板上，把自己变成 USB HID 触屏（单指版，先验证）
# 用法： su -c sh hid_gadget.sh check | setup | tap | rollback
# 前提：内核带 CONFIG_USB_CONFIGFS_F_HID，且有 root

G=/sys/kernel/config/usb_gadget/touchmac
DEF=/config/usb_gadget/g1

check() {
  echo "== 内核 f_hid =="
  if [ -d /sys/module/usb_f_hid ] || [ -d /sys/module/libcomposite ]; then
    ls -d /sys/module/usb_f_hid 2>/dev/null || echo "libcomposite 有，f_hid 未加载"
  fi
  echo "== configfs =="
  mount | grep -q configfs || echo "configfs 未挂载（setup 会尝试挂载）"
  echo "== /dev/hidg* =="
  ls -l /dev/hidg* 2>/dev/null || echo "暂无（setup 后出现）"
  echo "== UDC =="
  ls /sys/class/udc 2>/dev/null || echo "无 UDC（这台机器的 USB 口不支持 device 模式）"
  echo "== 当前 gadget =="
  ls $DEF 2>/dev/null | head -5
  cat $DEF/UDC 2>/dev/null
  echo "== SELinux =="
  getenforce 2>/dev/null
}

setup() {
  mount -t configfs none /sys/kernel/config 2>/dev/null
  # 释放默认 gadget 占用的 UDC
  [ -f $DEF/UDC ] && echo "" > $DEF/UDC 2>/dev/null

  rm -rf $G
  mkdir -p $G || exit 1
  echo 0x1209 > $G/idVendor
  echo 0x4c53 > $G/idProduct
  echo 0x0100 > $G/bcdDevice
  echo 0x0200 > $G/bcdUSB
  mkdir -p $G/strings/0x409
  echo "TABLET0001" > $G/strings/0x409/serialnumber
  echo "Tablet"     > $G/strings/0x409/manufacturer
  echo "Touchscreen" > $G/strings/0x409/product
  mkdir -p $G/configs/c.1/strings/0x409
  echo "hid" > $G/configs/c.1/strings/0x409/configuration
  mkdir -p $G/functions/hid.usb0
  echo 0 > $G/functions/hid.usb0/protocol
  echo 0 > $G/functions/hid.usb0/subclass
  echo 6 > $G/functions/hid.usb0/report_length 2>/dev/null

  # 单指 Touch Screen 描述符（Digitizer 0x0D / Touch Screen 0x04）
  # TipSwitch, InRange, 6bit pad, ContactID, X/Y(16bit) => 6 字节报告
  printf '\005\015\011\004\241\001\011\042\241\002\011\102\025\000\045\001\165\001\225\001\201\002\011\062\201\002\225\006\201\003\011\121\045\177\165\010\225\001\201\002\005\001\011\060\011\061\047\377\377\000\000\165\020\225\002\201\002\300\300' \
    > $G/functions/hid.usb0/report_desc

  ln -s $G/functions/hid.usb0 $G/configs/c.1/ 2>/dev/null
  UDC=$(ls /sys/class/udc | head -1)
  echo "bind UDC: $UDC"
  echo "$UDC" > $G/UDC || exit 1
  sleep 1
  ls -l /dev/hidg* 2>/dev/null
  echo "setup done"
}

# 在屏幕正中点一下（x=y=0x8000）
tap() {
  D=/dev/hidg0
  [ -e $D ] || { echo "没有 $D"; exit 1; }
  # X/Y 小端：0x8000 = 屏幕中央
  printf '\007\001\000\200\000\200' > $D
  sleep 0.08
  printf '\004\001\000\200\000\200' > $D
  echo "tap sent"
}

rollback() {
  echo "" > $G/UDC 2>/dev/null
  rm -rf $G
  UDC=$(ls /sys/class/udc | head -1)
  [ -n "$UDC" ] && echo "$UDC" > $DEF/UDC 2>/dev/null
  echo "rolled back（若 adb 未恢复，重启设备）"
}

case "$1" in
  check) check ;;
  setup) setup ;;
  tap) tap ;;
  rollback) rollback ;;
  *) echo "用法: $0 check|setup|tap|rollback" ;;
esac
