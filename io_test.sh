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

# 定义函数进行 dd 测试
function dd_test() {
  echo "执行 dd 写入测试..."
  WRITE_SPEED=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count=1024 oflag=direct 2>&1 | grep -o '[0-9\\.]* MB/s' | awk '{print $1}')
  echo "写入速度: $WRITE_SPEED MB/s"

  echo "执行 dd 读取测试..."
  READ_SPEED=$(dd if="$TEST_FILE" of=/dev/null bs=1M count=1024 iflag=direct 2>&1 | grep -o '[0-9\\.]* MB/s' | awk '{print $1}')
  echo "读取速度: $READ_SPEED MB/s"
}

# 定义函数进行 fio 测试
function fio_test() {
  echo "执行 fio 测试..."
  fio --name=io_test --size=1G --filename="$TEST_FILE" --rw=randrw --bs=4k --direct=1 --numjobs=4 --time_based --runtime=30 --output="$TEST_DIR/fio_output.log"
  
  RW_SPEED=$(grep 'READ:' "$TEST_DIR/fio_output.log" | awk -F',' '{for(i=1;i<=NF;i++) if($i ~ /bw=/) {print $i} }' | sed 's/bw=\\([0-9.]*\\).*/\\1/')
  WW_SPEED=$(grep 'WRITE:' "$TEST_DIR/fio_output.log" | awk -F',' '{for(i=1;i<=NF;i++) if($i ~ /bw=/) {print $i} }' | sed 's/bw=\\([0-9.]*\\).*/\\1/')
  
  echo "fio 读取速度: $RW_SPEED KiB/s"
  echo "fio 写入速度: $WW_SPEED KiB/s"
}

# 运行 dd 和 fio 测试两次并取平均值
declare -a dd_write_results dd_read_results fio_write_results fio_read_results

for i in {1..2}; do
  echo "\\n开始第 $i 次测试..."
  dd_test
  fio_test

  # 保存结果
  dd_write_results+=("$WRITE_SPEED")
  dd_read_results+=("$READ_SPEED")
  fio_write_results+=("$WW_SPEED")
  fio_read_results+=("$RW_SPEED")
done

# 计算平均值
function calculate_average() {
  local sum=0
  local count=$#
  for value in "$@"; do
    sum=$(echo "$sum + $value" | bc)
  done
  echo "scale=2; $sum / $count" | bc
}

dd_write_avg=$(calculate_average "${dd_write_results[@]}")
dd_read_avg=$(calculate_average "${dd_read_results[@]}")
fio_write_avg=$(calculate_average "${fio_write_results[@]}")
fio_read_avg=$(calculate_average "${fio_read_results[@]}")

# 输出平均值
echo "\\n测试结果汇总:"
echo "DD 写入速度平均值: $dd_write_avg MB/s"
echo "DD 读取速度平均值: $dd_read_avg MB/s"
echo "FIO 写入速度平均值: $fio_write_avg KiB/s"
echo "FIO 读取速度平均值: $fio_read_avg KiB/s"

# 清理测试文件
rm -rf "$TEST_DIR"
echo "测试文件已清理，测试完成。"
