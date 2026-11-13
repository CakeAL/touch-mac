#!/system/bin/sh
# 在 root 安卓平板上，把自己变成 USB HID 触屏。
#
# 两种挂法：
#   attach —— 把 HID 功能加到系统默认 gadget（g1）上，USB adb 不掉，推荐。
#   setup  —— 独占 UDC 建一个只有 HID 的 gadget，USB adb 会消失（需要无线 adb 兜底）。
#
# 用法：
#   su -c sh hid_gadget.sh check
#   su -c sh hid_gadget.sh attach-mt   # 16 指（推荐，97 字节报告）
#   su -c sh hid_gadget.sh attach      # 单指（6 字节报告，先验证链路）
#   su -c sh hid_gadget.sh detach
#   su -c sh hid_gadget.sh setup-mt    # 独占（老路，会断 USB adb）
#   su -c sh hid_gadget.sh tap         # 在屏幕正中点一下
#   su -c sh hid_gadget.sh tap2        # 两指捏合（仅 mt 布局有效）
#   su -c sh hid_gadget.sh rollback
#
# 前提：内核带 CONFIG_USB_CONFIGFS_F_HID，且有 root。

G=/sys/kernel/config/usb_gadget/touchmac
DEF=/config/usb_gadget/g1
FN=hid.usb0                                  # 功能名（设备节点编号会变，见 HIDDEV）
HIDDEV=/dev/hidgtouch                        # 稳定节点：按 function 的 dev 号 mknod
STATE=/data/local/tmp/touchmac.state         # own-single | own-mt | attach-single | attach-mt
FUNCDIR=/data/local/tmp/touchmac.funcdir     # 当前 report_desc 所在目录
TMP=/data/local/tmp/touchmac.report
DESC=/data/local/tmp/touchmac.desc
LEN=6
FORCE=0

# ---- 安全网：独占方案会解绑默认 gadget，USB adb 必然消失 ----

has_net_adb() {
  P=$(getprop service.adb.tcp.port 2>/dev/null)
  [ -n "$P" ] && [ "$P" != "0" ] && return 0
  P=$(getprop persist.adb.tcp.port 2>/dev/null)
  [ -n "$P" ] && [ "$P" != "0" ] && return 0
  return 1
}

guard_net_adb() {
  [ "$FORCE" = "1" ] && return 0
  has_net_adb && return 0
  echo "⚠️  没检测到无线 adb（service.adb.tcp.port 未设置）。"
  echo "   独占 gadget 会让 USB adb 消失，到时候只能重启平板才能恢复控制。"
  echo "   要么改用 attach-mt（不影响 USB adb），要么先执行："
  echo "     adb tcpip 5555 && adb connect <平板IP>:5555"
  echo "   确实要冒险：$0 setup-mt --force"
  exit 2
}

check() {
  echo "== 内核 f_hid =="
  ls -d /sys/module/usb_f_hid 2>/dev/null || echo "usb_f_hid 未加载（尝试 mkdir 时会自动加载）"
  echo "== configfs =="
  mount | grep -q configfs || echo "configfs 未挂载（脚本会尝试挂载）"
  echo "== /dev/hidg* =="
  ls -l /dev/hidg* 2>/dev/null || echo "暂无"
  echo "== 当前模式 =="
  cat $STATE 2>/dev/null || echo "未挂载"
  echo "== 功能目录 =="
  cat $FUNCDIR 2>/dev/null
  echo "== 默认 gadget 里有没有 hid =="
  ls -l $DEF/configs/*/ 2>/dev/null | grep hid || echo "没有"
  echo "== UDC =="
  ls /sys/class/udc 2>/dev/null || echo "无 UDC（USB 口不支持 device 模式）"
  echo "== 默认 gadget UDC =="
  cat $DEF/UDC 2>/dev/null
  echo "== SELinux =="
  getenforce 2>/dev/null
}

# ---- 描述符 ----

# 单指：Digitizer 0x0D / Touch Screen 0x04
# TipSwitch(1bit)+InRange(1bit)+6bit pad => 1 字节
# ContactID(8bit) => 1 字节；X/Y(16bit) => 4 字节；共 6 字节
build_desc_single() {
  printf '\005\015\011\004\241\001\011\042\241\002\011\102\025\000\045\001\165\001\225\001\201\002\011\062\201\002\225\006\201\003\011\121\045\177\165\010\225\001\201\002\005\001\011\060\011\061\047\377\377\000\000\165\020\225\002\201\002\300\300' \
    > $DESC
  LEN=6
}

# 16 指：16 个 Finger collection（每个 6 字节）+ ContactCount(1 字节) = 97 字节
build_desc_mt() {
  printf '\005\015\011\004\241\001' > $DESC
  i=0
  while [ $i -lt 16 ]; do
    printf '\005\015\011\042\241\002\011\102\011\062\011\107\025\000\045\001\165\001\225\003\201\002\165\005\225\001\201\003\011\121\045\177\165\010\225\001\201\002\005\001\011\060\011\061\047\377\377\000\000\165\020\225\002\201\002\300' >> $DESC
    i=$((i + 1))
  done
  printf '\005\015\011\124\025\000\045\020\165\010\225\001\201\002\300' >> $DESC
  LEN=97
}

# 把 $DESC / $LEN 写进功能目录。
# report_length 是 f_hid 的独立选项（最小 16），不设就是 0，
# 而 f_hidg_write 里 count = min(len, report_length) = 0 → 一个字节都发不出去。
apply_to() {
  F=$1
  cat $DESC > $F/report_desc
  echo 0 > $F/protocol
  echo 0 > $F/subclass
  echo $LEN > $F/report_length
  echo $F > $FUNCDIR
  echo "report_length = $(cat $F/report_length)（应为 $LEN）"
}

# ---- 稳定设备节点：function 重建后 /dev/hidgN 的编号会变，写死会写出普通文件 ----
ensure_dev() {
  F=${F:-$(cat $FUNCDIR 2>/dev/null)}
  [ -n "$F" ] && [ -f "$F/dev" ] || return 1
  DEVID=$(cat "$F/dev" 2>/dev/null)          # 形如 479:1
  [ -n "$DEVID" ] || return 1
  rm -f "$HIDDEV" 2>/dev/null
  mknod "$HIDDEV" c "${DEVID%:*}" "${DEVID#*:}" 2>/dev/null
  chmod 666 "$HIDDEV" 2>/dev/null
  [ -c "$HIDDEV" ] || return 1
  return 0
}

# ---- attach：加到默认 gadget，不动 UDC，adb 不断 ----

attach() {
  layout=$1
  mount -t configfs none /sys/kernel/config 2>/dev/null
  [ -f $DEF/UDC ] || { echo "没有 $DEF（默认 gadget 不存在？）"; exit 1; }
  F=$DEF/functions/$FN            # 注意：g1 在 /config/usb_gadget/g1，不是 $G
  rm -f $DEF/configs/*/$FN 2>/dev/null
  rmdir $F 2>/dev/null
  mkdir -p $F || { echo "mkdir $F 失败"; exit 1; }
  case $layout in
    mt) build_desc_mt ;;
    *)  build_desc_single ;;
  esac
  apply_to $F
  # configfs 的符号链接必须用绝对目标；相对路径 ln 会报 No such file or directory
  ln -s "$DEF/functions/$FN" "$DEF/configs/b.1/$FN" || { echo "link 失败"; exit 1; }
  echo "attach-$layout" > $STATE
  # 热加进已绑定的 config 不会重建描述符：必须重绑 UDC，主机才能看到新接口。
  # （只判断 /dev/hidgN 是否存在会误判：function 一创建就有 dev 号，但没进配置。）
  CUR=$(cat $DEF/UDC 2>/dev/null)
  if [ -n "$CUR" ]; then
    echo "重绑 UDC（$CUR）让新功能生效…"
    # 太快重绑主机可能不重新枚举，留足断开时间
    echo "" > $DEF/UDC 2>/dev/null; sleep 3
    echo "$CUR" > $DEF/UDC; sleep 3
  fi
  ensure_dev
  ensure_dev
  if [ -c "$HIDDEV" ]; then
    echo "✅ $HIDDEV 就绪（attach-$layout，dev=$(cat ${F:-$DEF/functions/$FN}/dev)），USB adb 会自行恢复"
  else
    echo "⚠️ 没出现 $HIDDEV：这台机的 UDC 不支持热加功能，试试 setup-$layout"
  fi
}

detach() {
  F=$(cat $FUNCDIR 2>/dev/null)
  CUR=$(cat $DEF/UDC 2>/dev/null)
  rm -f $DEF/configs/*/$FN 2>/dev/null
  # 功能仍被绑定中的 config 引用时 rmdir 会 busy，先重绑 UDC 再删
  if [ -n "$F" ] && ! rmdir "$F" 2>/dev/null; then
    if [ -n "$CUR" ]; then
      echo "" > $DEF/UDC 2>/dev/null; sleep 1
      rm -f $DEF/configs/*/$FN 2>/dev/null
      rmdir "$F" 2>/dev/null
      echo "$CUR" > $DEF/UDC; sleep 2
    fi
  fi
  rm -f $STATE $FUNCDIR "$HIDDEV"
  echo "detached"
}

# ---- setup：独占 UDC（老路） ----

create_gadget() {
  mount -t configfs none /sys/kernel/config 2>/dev/null
  [ -f $DEF/UDC ] && echo "" > $DEF/UDC 2>/dev/null

  rm -rf $G
  mkdir -p $G || exit 1
  echo 0x1209 > $G/idVendor
  echo 0x4c53 > $G/idProduct
  echo 0x0100 > $G/bcdDevice
  echo 0x0200 > $G/bcdUSB
  mkdir -p $G/strings/0x409
  echo "TABLET0001"  > $G/strings/0x409/serialnumber
  echo "Tablet"      > $G/strings/0x409/manufacturer
  echo "Touchscreen" > $G/strings/0x409/product
  mkdir -p $G/configs/c.1/strings/0x409
  echo "hid" > $G/configs/c.1/strings/0x409/configuration
  mkdir -p $G/functions/$FN
}

bind_udc() {
  ln -s $G/functions/$FN $G/configs/c.1/ 2>/dev/null
  UDC=$(ls /sys/class/udc | head -1)
  echo "bind UDC: $UDC"
  echo "$UDC" > $G/UDC || exit 1
  sleep 1
  ls -l /dev/hidg* 2>/dev/null
  echo "layout = $(cat $STATE)"
}

setup() {
  layout=$1
  guard_net_adb
  create_gadget
  case $layout in
    mt) build_desc_mt ;;
    *)  build_desc_single ;;
  esac
  apply_to $G/functions/$FN
  echo "own-$layout" > $STATE
  bind_udc
  echo "setup done（$layout）"
}

# ---- 报告构造：先写临时文件，再一次性 cat 给 HID 设备节点 ----

blank() { dd if=/dev/zero of=$TMP bs=$LEN count=1 2>/dev/null; }

# poke OFFSET BYTES
poke() { printf "$2" | dd of=$TMP bs=1 seek=$1 conv=notrunc 2>/dev/null; }

send() { ensure_dev || { echo "没有 $HIDDEV"; exit 1; }; cat $TMP > "$HIDDEV"; }

is_mt() { case "$(cat $STATE 2>/dev/null)" in *-mt) return 0 ;; *) return 1 ;; esac; }

tap() {
  ensure_dev || { echo "没有 $HIDDEV"; exit 1; }
  if is_mt; then
    LEN=97
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
    printf '\007\001\000\200\000\200' > "$HIDDEV"
    sleep 0.08
    printf '\004\001\000\200\000\200' > "$HIDDEV"
  fi
  echo "tap sent"
}

# 两指张开（验证双指）
tap2() {
  is_mt || { echo "先 attach-mt 或 setup-mt"; exit 1; }
  ensure_dev || { echo "没有 $HIDDEV"; exit 1; }
  LEN=97
  blank
  poke 0  '\007\001\000\060\000\200'
  poke 6  '\007\002\000\320\000\200'
  poke 96 '\002'
  send
  sleep 0.05
  poke 0  '\007\001\000\020\000\200'
  poke 6  '\007\002\000\360\000\200'
  send
  sleep 0.05
  poke 0  '\004\001\000\020\000\200'
  poke 6  '\004\002\000\360\000\200'
  send
  echo "tap2 sent"
}

rollback() {
  detach
  echo "" > $G/UDC 2>/dev/null
  rm -rf $G
  rm -f $STATE $FUNCDIR
  UDC=$(ls /sys/class/udc | head -1)
  [ -n "$UDC" ] && echo "$UDC" > $DEF/UDC 2>/dev/null
  echo "rolled back"
}

case "$1" in
  check) check ;;
  attach) attach single ;;
  attach-mt) attach mt ;;
  detach) detach ;;
  setup) [ "$2" = "--force" ] && FORCE=1; setup single ;;
  setup-mt) [ "$2" = "--force" ] && FORCE=1; setup mt ;;
  tap) tap ;;
  tap2) tap2 ;;
  rollback) rollback ;;
  *) echo "用法: $0 check|attach|attach-mt|detach|setup|setup-mt|tap|tap2|rollback [--force]" ;;
esac
