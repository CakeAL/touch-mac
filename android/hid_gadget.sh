#!/system/bin/sh
# 在 root 安卓平板上，把自己变成 USB HID 触屏。
#
# 用法：
#   su -c sh hid_gadget.sh check
#   su -c sh hid_gadget.sh setup        # 单指（6 字节报告，先验证链路）
#   su -c sh hid_gadget.sh setup-mt     # 16 指（97 字节报告，双指缩放用这个）
#   su -c sh hid_gadget.sh tap          # 在屏幕正中点一下
#   su -c sh hid_gadget.sh tap2         # 两指捏合（仅 setup-mt 后有效）
#   su -c sh hid_gadget.sh rollback
#
# 前提：内核带 CONFIG_USB_CONFIGFS_F_HID，且有 root。

G=/sys/kernel/config/usb_gadget/touchmac
DEF=/config/usb_gadget/g1
STATE=/data/local/tmp/touchmac.layout   # single | mt
TMP=/data/local/tmp/touchmac.report
DESC=/data/local/tmp/touchmac.desc
LEN=6

check() {
  echo "== 内核 f_hid =="
  if [ -d /sys/module/usb_f_hid ] || [ -d /sys/module/libcomposite ]; then
    ls -d /sys/module/usb_f_hid 2>/dev/null || echo "libcomposite 有，f_hid 未加载"
  fi
  echo "== configfs =="
  mount | grep -q configfs || echo "configfs 未挂载（setup 会尝试挂载）"
  echo "== /dev/hidg* =="
  ls -l /dev/hidg* 2>/dev/null || echo "暂无（setup 后出现）"
  echo "== 当前布局 =="
  cat $STATE 2>/dev/null || echo "未 setup"
  echo "== 报告长度（读回，应为 6 或 97）=="
  cat $G/functions/hid.usb0/report_length 2>/dev/null
  echo "== UDC =="
  ls /sys/class/udc 2>/dev/null || echo "无 UDC（这台机器的 USB 口不支持 device 模式）"
  echo "== 当前 gadget =="
  ls $DEF 2>/dev/null | head -5
  cat $DEF/UDC 2>/dev/null
  echo "== SELinux =="
  getenforce 2>/dev/null
}

create_gadget() {
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
}

# 单指：Digitizer 0x0D / Touch Screen 0x04
# TipSwitch(1bit)+InRange(1bit)+6bit pad => 1 字节
# ContactID(8bit) => 1 字节；X/Y(16bit) => 4 字节；共 6 字节
write_desc_single() {
  printf '\005\015\011\004\241\001\011\042\241\002\011\102\025\000\045\001\165\001\225\001\201\002\011\062\201\002\225\006\201\003\011\121\045\177\165\010\225\001\201\002\005\001\011\060\011\061\047\377\377\000\000\165\020\225\002\201\002\300\300' \
    > $TMP.desc
  cat $TMP.desc > $G/functions/hid.usb0/report_desc
  # report_length 是 f_hid 的独立选项（最小 16），必须显式设置，
  # 否则为 0，f_hidg_write 里 count = min(len, report_length) = 0，什么都发不出去。
  echo 64 > $G/functions/hid.usb0/report_length
  LEN=6
}

# 16 指：16 个 Finger collection（每个 6 字节）+ ContactCount(1 字节) = 97 字节
# 每个 Finger：TipSwitch/InRange/Confidence(3bit)+5bit pad=1B，ContactID=1B，X/Y 各 2B
write_desc_mt() {
  printf '\005\015\011\004\241\001' > $TMP.desc
  i=0
  while [ $i -lt 16 ]; do
    printf '\005\015\011\042\241\002\011\102\011\062\011\107\025\000\045\001\165\001\225\003\201\002\165\005\225\001\201\003\011\121\045\177\165\010\225\001\201\002\005\001\011\060\011\061\047\377\377\000\000\165\020\225\002\201\002\300' >> $TMP.desc
    i=$((i + 1))
  done
  printf '\005\015\011\124\025\000\045\020\165\010\225\001\201\002\300' >> $TMP.desc
  # 一次性写入（configfs 的 report_desc 每次 store 是整体替换，不能分段追加）
  cat $TMP.desc > $G/functions/hid.usb0/report_desc
  echo 97 > $G/functions/hid.usb0/report_length
  LEN=97
}

bind_udc() {
  ln -s $G/functions/hid.usb0 $G/configs/c.1/ 2>/dev/null
  UDC=$(ls /sys/class/udc | head -1)
  echo "bind UDC: $UDC"
  echo "$UDC" > $G/UDC || exit 1
  sleep 1
  ls -l /dev/hidg* 2>/dev/null
  echo "report_length = $(cat $G/functions/hid.usb0/report_length 2>/dev/null)（应为 $LEN）"
  echo "layout = $(cat $STATE)"
}

setup_single() {
  create_gadget
  write_desc_single
  echo single > $STATE
  bind_udc
  echo "setup done（单指）"
}

setup_mt() {
  create_gadget
  write_desc_mt
  echo mt > $STATE
  bind_udc
  echo "setup done（16 指）"
}

# ---- 报告构造：先写临时文件，再一次性 cat 给 /dev/hidg0 ----

blank() { dd if=/dev/zero of=$TMP bs=$LEN count=1 2>/dev/null; }

# poke OFFSET BYTES
poke() { printf "$2" | dd of=$TMP bs=1 seek=$1 conv=notrunc 2>/dev/null; }

send() { cat $TMP > /dev/hidg0; }

# 屏幕正中点一下（x=y=0x8000）
tap() {
  [ -e /dev/hidg0 ] || { echo "没有 /dev/hidg0"; exit 1; }
  LEN=$(cat $G/functions/hid.usb0/report_length 2>/dev/null)
  [ -n "$LEN" ] || LEN=64
  if [ "$(cat $STATE 2>/dev/null)" = "mt" ]; then
    blank
    poke 0  '\007\001\000\200\000\200'
    poke 96 '\001'
    send
    sleep 0.08
    blank
    poke 0  '\004\001\000\200\000\200'
    poke 96 '\001'
    send
  else
    printf '\007\001\000\200\000\200' > /dev/hidg0
    sleep 0.08
    printf '\004\001\000\200\000\200' > /dev/hidg0
  fi
  echo "tap sent"
}

# 两指捏合：两指从中间向两侧分开（验证双指/缩放手势）
tap2() {
  [ "$(cat $STATE 2>/dev/null)" = "mt" ] || { echo "先 setup-mt"; exit 1; }
  [ -e /dev/hidg0 ] || { echo "没有 /dev/hidg0"; exit 1; }
  LEN=$(cat $G/functions/hid.usb0/report_length 2>/dev/null)
  [ -n "$LEN" ] || LEN=97
  blank
  poke 0  '\007\001\000\060\000\200'   # finger1 x=0x3000
  poke 6  '\007\002\000\320\000\200'   # finger2 x=0xD000
  poke 96 '\002'
  send
  sleep 0.05
  poke 0  '\007\001\000\020\000\200'   # finger1 x=0x1000
  poke 6  '\007\002\000\360\000\200'   # finger2 x=0xF000
  send
  sleep 0.05
  poke 0  '\004\001\000\020\000\200'
  poke 6  '\004\002\000\360\000\200'
  send
  echo "tap2 sent"
}

rollback() {
  echo "" > $G/UDC 2>/dev/null
  rm -rf $G
  rm -f $STATE $TMP $TMP.desc
  UDC=$(ls /sys/class/udc | head -1)
  [ -n "$UDC" ] && echo "$UDC" > $DEF/UDC 2>/dev/null
  echo "rolled back（若 adb 未恢复，重启设备）"
}

case "$1" in
  check) check ;;
  setup) setup_single ;;
  setup-mt) setup_mt ;;
  tap) tap ;;
  tap2) tap2 ;;
  rollback) rollback ;;
  *) echo "用法: $0 check|setup|setup-mt|tap|tap2|rollback" ;;
esac
