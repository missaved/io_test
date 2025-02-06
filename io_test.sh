#!/usr/bin/env bash
#
# 自动检测当前系统的所有物理磁盘挂载点，获取硬盘型号和文件系统类型，
# 使用 fio 分别测试：顺序写、顺序读、随机写、随机读 的带宽(MB/s)，
# 最终输出一张汇总表格。

################################################################################
# 1) 准备工作：检查是否 root、安装 fio + jq
################################################################################
if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 权限执行此脚本 (sudo 或者直接在 root 下)。"
  exit 1
fi

if ! command -v fio &>/dev/null; then
  echo "未检测到 fio，正在自动安装..."
  apt-get update && apt-get install -y fio
  if ! command -v fio &>/dev/null; then
    echo "安装 fio 失败，请手动安装后重试。"
    exit 1
  fi
fi

if ! command -v jq &>/dev/null; then
  echo "未检测到 jq，正在自动安装..."
  apt-get update && apt-get install -y jq
  if ! command -v jq &>/dev/null; then
    echo "安装 jq 失败，请手动安装后重试。"
    exit 1
  fi
fi

################################################################################
# 2) 筛选当前系统的真实挂载点
#    - 排除 tmpfs / devtmpfs / overlay / squashfs 等虚拟文件系统
#    - 取出: 设备名 / 文件系统类型 / 挂载点
################################################################################
EXCLUDE_FS_REGEX="^(tmpfs|devtmpfs|overlay|squashfs|proc|sysfs|cgroup|pstore|aufs|ramfs)$"

# 用 df -T 列出所有挂载的文件系统, 跳过表头
# 格式：Filesystem Type Size Used Avail Use% Mounted on
ALL_MOUNTS=()
while read -r line; do
  # 示例行：/dev/sda1 ext4  50G  10G  37G  22%  /
  # 用 awk 拆分
  dev=$(echo "$line" | awk '{print $1}')       # 设备名
  fstype=$(echo "$line" | awk '{print $2}')    # 文件系统类型
  mountp=$(echo "$line" | awk '{print $7}')    # 挂载点

  # 排除不需要的类型
  if echo "$fstype" | grep -Eq "$EXCLUDE_FS_REGEX"; then
    continue
  fi

  # 排除类似 /dev/loopX 这种只读镜像（snap等），你可自行选择是否排除
  if [[ "$dev" =~ ^/dev/loop[0-9]+$ ]]; then
    continue
  fi

  # 收集
  ALL_MOUNTS+=("$dev|$fstype|$mountp")
done < <(df -T | tail -n +2)

# 如果没有找到任何挂载点，就退出
if [[ ${#ALL_MOUNTS[@]} -eq 0 ]]; then
  echo "未找到可测试的物理磁盘挂载点(全部是虚拟文件系统或被排除)。"
  exit 0
fi

################################################################################
# 3) 准备数组来存放测试结果
################################################################################
declare -A MODEL        # [mount_point] -> 磁盘型号
declare -A FS_TYPE      # [mount_point] -> 文件系统类型
declare -A SEQW         # [mount_point] -> 顺序写 MB/s
declare -A SEQR         # [mount_point] -> 顺序读 MB/s
declare -A RANDW        # [mount_point] -> 随机写 MB/s
declare -A RANDR        # [mount_point] -> 随机读 MB/s

################################################################################
# 4) 定义一个函数：对单个挂载点执行 fio 测试
#    - 4个job：seq_write, seq_read, rand_write, rand_read
#    - 大小默认: size=1G (可自行修改)
#    - 解析JSON输出并将结果存入关联数组
################################################################################
function run_fio_test_for_mount() {
  local mountp="$1"

  # 为了安全，做一个临时 config 文件
  local fio_conf
  fio_conf=$(mktemp /tmp/fio_conf.XXXXXX)
  cat <<EOF > "$fio_conf"
[global]
ioengine=libaio
direct=1
bs=4k
iodepth=4
size=1G
directory=$mountp
# 如需限制时间，可设置 time_based=1, runtime=30 等

[seq_write]
rw=write
filename=fio_seq_write.bin
stonewall
unlink=1

[seq_read]
rw=read
filename=fio_seq_read.bin
stonewall
unlink=1

[rand_write]
rw=randwrite
filename=fio_rand_write.bin
stonewall
unlink=1

[rand_read]
rw=randread
filename=fio_rand_read.bin
stonewall
unlink=1
EOF

  # 执行 fio 测试，输出 JSON
  local fio_output
  fio_output=$(fio --output-format=json "$fio_conf" 2>/dev/null)

  # 删除临时文件
  rm -f "$fio_conf"

  # 解析 JSON，提取4个job的带宽(bw: KB/s) -> 转成 MB/s
  # seq_write => write
  local bw_seqw_kb
  bw_seqw_kb=$(echo "$fio_output" | jq '.jobs[] | select(.jobname=="seq_write").write.bw')
  local bw_seqw_mb
  bw_seqw_mb=$(awk -v kb="$bw_seqw_kb" 'BEGIN { printf "%.1f", kb/1024 }')

  # seq_read => read
  local bw_seqr_kb
  bw_seqr_kb=$(echo "$fio_output" | jq '.jobs[] | select(.jobname=="seq_read").read.bw')
  local bw_seqr_mb
  bw_seqr_mb=$(awk -v kb="$bw_seqr_kb" 'BEGIN { printf "%.1f", kb/1024 }')

  # rand_write => write
  local bw_randw_kb
  bw_randw_kb=$(echo "$fio_output" | jq '.jobs[] | select(.jobname=="rand_write").write.bw')
  local bw_randw_mb
  bw_randw_mb=$(awk -v kb="$bw_randw_kb" 'BEGIN { printf "%.1f", kb/1024 }')

  # rand_read => read
  local bw_randr_kb
  bw_randr_kb=$(echo "$fio_output" | jq '.jobs[] | select(.jobname=="rand_read").read.bw')
  local bw_randr_mb
  bw_randr_mb=$(awk -v kb="$bw_randr_kb" 'BEGIN { printf "%.1f", kb/1024 }')

  # 存入全局数组
  SEQW["$mountp"]="$bw_seqw_mb"
  SEQR["$mountp"]="$bw_seqr_mb"
  RANDW["$mountp"]="$bw_randw_mb"
  RANDR["$mountp"]="$bw_randr_mb"
}

################################################################################
# 5) 主循环：对每个挂载点：
#    - 获取其父块设备 + 磁盘型号
#    - 运行 fio 测试
################################################################################
for item in "${ALL_MOUNTS[@]}"; do
  # 拆分 dev|fstype|mount
  dev="${item%%|*}"              # /dev/sda1
  rest="${item#*|}"              # fstype|mount
  fstype="${rest%%|*}"
  mountp="${rest#*|}"

  # 取父块设备(物理磁盘)：lsblk -no PKNAME /dev/sda1 => sda
  # 如果 dev 本身就是整块设备 /dev/sda，则 PKNAME 可能为空
  parent_blk=$(lsblk -no PKNAME "$dev" 2>/dev/null)
  if [[ -z "$parent_blk" ]]; then
    # 可能本身就是 /dev/sda 这种整块磁盘
    parent_blk=$(basename "$dev")
  fi

  # 磁盘型号: lsblk -no MODEL /dev/sda
  disk_model=$(lsblk -no MODEL "/dev/$parent_blk" 2>/dev/null)
  [[ -z "$disk_model" ]] && disk_model="(Unknown)"

  # 存起来
  MODEL["$mountp"]="$disk_model"
  FS_TYPE["$mountp"]="$fstype"

  echo "------------------------------------------------"
  echo "挂载点: $mountp"
  echo "设备: $dev (物理磁盘: /dev/$parent_blk)"
  echo "文件系统: $fstype"
  echo "磁盘型号: $disk_model"
  echo "开始执行 fio 测试(顺序读写 & 随机读写)..."
  run_fio_test_for_mount "$mountp"
  echo "完成。"
done

################################################################################
# 6) 打印结果汇总表
################################################################################
echo
echo "===================== 测试结果汇总表 ====================="
printf "| %-20s | %-18s | %-7s | %-7s | %-7s | %-7s |\n" \
  "挂载点" "磁盘型号" "SeqW" "SeqR" "RandW" "RandR"
echo "|----------------------|--------------------|---------|---------|---------|---------|"

for item in "${ALL_MOUNTS[@]}"; do
  rest="${item#*|}"
  fstype="${rest%%|*}"
  mountp="${rest#*|}"
  
  local_model="${MODEL[$mountp]}"
  local_seqw="${SEQW[$mountp]}"
  local_seqr="${SEQR[$mountp]}"
  local_randw="${RANDW[$mountp]}"
  local_randr="${RANDR[$mountp]}"

  # 若某次测试失败(取不到值)，设为 "N/A"
  [[ -z "$local_seqw" ]] && local_seqw="N/A"
  [[ -z "$local_seqr" ]] && local_seqr="N/A"
  [[ -z "$local_randw" ]] && local_randw="N/A"
  [[ -z "$local_randr" ]] && local_randr="N/A"

  printf "| %-20s | %-18s | %-7s | %-7s | %-7s | %-7s |\n" \
    "$mountp" \
    "$local_model" \
    "$local_seqw" \
    "$local_seqr" \
    "$local_randw" \
    "$local_randr"
done

echo "==========================================================="
echo
echo "说明：以上带宽单位均为 MB/s (测试时使用 bs=4k, iodepth=4, size=1G)。"
echo "      SeqW/SeqR = 顺序写/读，RandW/RandR = 随机写/读。"
echo "      可在脚本中自行修改 fio 配置参数以适配实际需求。"
