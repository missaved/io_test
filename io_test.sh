#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 权限运行此脚本！"
  exit 1
fi

# 设置测试目录和文件
TEST_DIR="/tmp/io_test"
mkdir -p "$TEST_DIR"
TEST_FILE="$TEST_DIR/testfile"

# 安装必要工具
if ! command -v fio &> /dev/null; then
  echo "fio 未安装，正在安装..."
  apt update && apt install -y fio || { echo "安装 fio 失败！请检查网络连接。"; exit 1; }
fi

if ! command -v bc &> /dev/null; then
  echo "bc 未安装，正在安装..."
  apt update && apt install -y bc || { echo "安装 bc 失败！请检查网络连接。"; exit 1; }
fi

# 通用函数：将任意速率字符串（如"96.9 MB/s", "2.1 GB/s", "302kB/s", "31.6MiB/s"等）
# 转换成 MB/s 数值（浮点）。未匹配则返回0。
function parse_speed_to_mb() {
  local input="$1"
  input=$(echo "$input" | xargs) # 去除前后空格

  # 提取数值和单位
  local value=$(echo "$input" | grep -Eo '[0-9]+(\.[0-9]+)?')
  local unit=$(echo "$input" | grep -Eo '[KMG]?[i]?B/s')

  if [ -z "$value" ] || [ -z "$unit" ]; then
    echo "0"
    return
  fi

  local speed_mb
  case "$unit" in
    "MB/s"|"MiB/s")
      # 直接使用数值
      speed_mb="$value"
      ;;
    "kB/s"|"KiB/s")
      # 除以1024
      speed_mb=$(echo "scale=4; $value/1024" | bc)
      ;;
    "GB/s"|"GiB/s")
      # 乘以1024
      speed_mb=$(echo "scale=4; $value*1024" | bc)
      ;;
    *)
      # 未知单位，返回0
      speed_mb="0"
      ;;
  esac

  echo "$speed_mb"
}

# 定义函数进行 dd 测试
function dd_test() {
  echo "执行 dd 写入测试..."
  WRITE_OUTPUT=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count=1024 oflag=direct 2>&1)
  WRITE_LINE=$(echo "$WRITE_OUTPUT" | grep 'copied')
  # 使用grep正则匹配速率
  WRITE_SPEED_STR=$(echo "$WRITE_LINE" | grep -oE '[0-9\.]+ [GMk]?B/s')
  WRITE_SPEED=$(parse_speed_to_mb "$WRITE_SPEED_STR")
  echo "$WRITE_OUTPUT" > "$TEST_DIR/dd_write_output.log"
  sleep 1
  echo "写入速度: $WRITE_SPEED MB/s"

  echo "执行 dd 读取测试..."
  READ_OUTPUT=$(dd if="$TEST_FILE" of=/dev/null bs=1M count=1024 iflag=direct 2>&1)
  READ_LINE=$(echo "$READ_OUTPUT" | grep 'copied')
  READ_SPEED_STR=$(echo "$READ_LINE" | grep -oE '[0-9\.]+ [GMk]?B/s')
  READ_SPEED=$(parse_speed_to_mb "$READ_SPEED_STR")
  echo "$READ_OUTPUT" > "$TEST_DIR/dd_read_output.log"
  sleep 1
  echo "读取速度: $READ_SPEED MB/s"
}


# 定义函数进行 fio 测试
function fio_test() {
  echo "执行 fio 测试..."
  fio --name=io_test --size=1G --filename="$TEST_FILE" --rw=randrw --bs=4k --direct=1 --numjobs=4 --time_based --runtime=30 --output="$TEST_DIR/fio_output.log"
  sleep 2

  RW_LINE=$(grep "^ *READ:" "$TEST_DIR/fio_output.log")
  WW_LINE=$(grep "^ *WRITE:" "$TEST_DIR/fio_output.log")

  # 提取如 "(302kB/s)" 的模式
  RW_UNIT=$(echo "$RW_LINE" | grep -oP '\([0-9\.]+[kMGT]?[i]?B/s\)' | tr -d '()')
  WW_UNIT=$(echo "$WW_LINE" | grep -oP '\([0-9\.]+[kMGT]?[i]?B/s\)' | tr -d '()')

  RW_SPEED=$(parse_speed_to_mb "$RW_UNIT")
  WW_SPEED=$(parse_speed_to_mb "$WW_UNIT")

  echo "fio 读取速度: $RW_SPEED MB/s"
  echo "fio 写入速度: $WW_SPEED MB/s"
}

# 运行 dd 和 fio 测试两次并取平均值
declare -a dd_write_results dd_read_results fio_write_results fio_read_results

for i in {1..2}; do
  echo "\n开始第 $i 次测试..."
  dd_test
  fio_test

  dd_write_results+=("$WRITE_SPEED")
  dd_read_results+=("$READ_SPEED")
  fio_write_results+=("$WW_SPEED")
  fio_read_results+=("$RW_SPEED")
done

# 输出每次的详细结果
echo "\nDD 写入测试输出:" && cat "$TEST_DIR/dd_write_output.log"
echo "\nDD 读取测试输出:" && cat "$TEST_DIR/dd_read_output.log"
echo "\nFIO 测试输出:" && cat "$TEST_DIR/fio_output.log"

# 计算平均值函数
function calculate_average() {
  local sum=0
  local count=$#
  for value in "$@"; do
    if [[ $value =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      sum=$(echo "$sum + $value" | bc)
    fi
  done
  echo "scale=2; $sum / $count" | bc
}

dd_write_avg=$(calculate_average "${dd_write_results[@]}")
dd_read_avg=$(calculate_average "${dd_read_results[@]}")
fio_write_avg=$(calculate_average "${fio_write_results[@]}")
fio_read_avg=$(calculate_average "${fio_read_results[@]}")

# 输出平均值
echo "\n测试结果汇总:"
echo "DD 写入速度平均值: $dd_write_avg MB/s"
echo "DD 读取速度平均值: $dd_read_avg MB/s"
echo "FIO 写入速度平均值: $fio_write_avg MB/s"
echo "FIO 读取速度平均值: $fio_read_avg MB/s"

# 清理测试文件
rm -rf "$TEST_DIR"
echo "测试文件已清理，测试完成。"
