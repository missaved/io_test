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
  WRITE_OUTPUT=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count=1024 oflag=direct 2>&1)
  # 从最后一行提取速度
  WRITE_LINE=$(echo "$WRITE_OUTPUT" | grep 'copied')
  WRITE_VALUE=$(echo "$WRITE_LINE" | awk -F, '{print $3}' | awk '{print $1}')    # 数值部分
  WRITE_UNIT=$(echo "$WRITE_LINE" | awk -F, '{print $3}' | awk '{print $2}')     # 单位部分，比如MB/s或GB/s

  if [ "$WRITE_UNIT" = "GB/s" ]; then
    WRITE_SPEED=$(echo "$WRITE_VALUE * 1024" | bc)
  else
    WRITE_SPEED=$WRITE_VALUE
  fi

  echo "$WRITE_OUTPUT" > "$TEST_DIR/dd_write_output.log"
  sleep 1
  echo "写入速度: $WRITE_SPEED MB/s"

  echo "执行 dd 读取测试..."
  READ_OUTPUT=$(dd if="$TEST_FILE" of=/dev/null bs=1M count=1024 iflag=direct 2>&1)
  # 同样解析读取速度
  READ_LINE=$(echo "$READ_OUTPUT" | grep 'copied')
  READ_VALUE=$(echo "$READ_LINE" | awk -F, '{print $3}' | awk '{print $1}')
  READ_UNIT=$(echo "$READ_LINE" | awk -F, '{print $3}' | awk '{print $2}')

  if [ "$READ_UNIT" = "GB/s" ]; then
    READ_SPEED=$(echo "$READ_VALUE * 1024" | bc)
  else
    READ_SPEED=$READ_VALUE
  fi

  echo "$READ_OUTPUT" > "$TEST_DIR/dd_read_output.log"
  sleep 1
  echo "读取速度: $READ_SPEED MB/s"
}


# 定义函数进行 fio 测试
function fio_test() {
  echo "执行 fio 测试..."
  fio --name=io_test --size=1G --filename="$TEST_FILE" --rw=randrw --bs=4k --direct=1 --numjobs=4 --time_based --runtime=30 --output="$TEST_DIR/fio_output.log"
  sleep 2

  # 使用最终汇总信息行解析
  # 提取READ行中括号内的MB/s数值
  RW_SPEED=$(grep 'READ:' "$TEST_DIR/fio_output.log" | grep -Eo '\([0-9\.]+MB/s\)' | sed -E 's/\(([0-9\.]+)MB\/s\)/\1/')
  # 提取WRITE行中括号内的MB/s数值
  WW_SPEED=$(grep 'WRITE:' "$TEST_DIR/fio_output.log" | grep -Eo '\([0-9\.]+MB/s\)' | sed -E 's/\(([0-9\.]+)MB\/s\)/\1/')

  RW_SPEED=${RW_SPEED:-0}
  WW_SPEED=${WW_SPEED:-0}

  echo "fio 读取速度: $RW_SPEED MB/s"
  echo "fio 写入速度: $WW_SPEED MB/s"
}

# 运行 dd 和 fio 测试两次并取平均值
declare -a dd_write_results dd_read_results fio_write_results fio_read_results

for i in {1..2}; do
  echo "\n开始第 $i 次测试..."
  dd_test
  fio_test

  # 保存结果
  dd_write_results+=("$WRITE_SPEED")
  dd_read_results+=("$READ_SPEED")
  fio_write_results+=("$WW_SPEED")
  fio_read_results+=("$RW_SPEED")
done

# 输出每次的详细结果
echo "\nDD 写入测试输出:" && cat "$TEST_DIR/dd_write_output.log"
echo "\nDD 读取测试输出:" && cat "$TEST_DIR/dd_read_output.log"
echo "\nFIO 测试输出:" && cat "$TEST_DIR/fio_output.log"

# 计算平均值
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
fio_read_avg=$(calculate_average "${fio_read_results[@]}" )

# 输出平均值
echo "\n测试结果汇总:"
echo "DD 写入速度平均值: $dd_write_avg MB/s"
echo "DD 读取速度平均值: $dd_read_avg MB/s"
echo "FIO 写入速度平均值: $fio_write_avg MB/s"
echo "FIO 读取速度平均值: $fio_read_avg MB/s"

# 清理测试文件
rm -rf "$TEST_DIR"
echo "测试文件已清理，测试完成。"
