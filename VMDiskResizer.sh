#!/bin/sh

# =======================================================================================
#   VMDiskResizer
# =======================================================================================
#   [Window -> Linux] 줄바꿈 형식 변환
#   sed -i 's/\r$//' VMDiskResizer_UTF8.sh
#
#   [UTF8 -> EUCKR] 파일 인코딩 변환
#   iconv -f UTF-8 -t EUC-KR VMDiskResizer_UTF8.sh -o VMDiskResizer_EUCKR.sh
# =======================================================================================

# 색상 변수 정의
C_BOLD=$(printf '\033[1m')
C_RED=$(printf '\033[0;31m')
C_YELLOW=$(printf '\033[0;33m')
C_GREEN=$(printf '\033[0;32m')
C_CYAN=$(printf '\033[1;36m')
C_RESET=$(printf '\033[0m')

# 함수: Step 제목 출력
print_step_header() {
    printf "${C_GREEN}${C_BOLD}%s${C_RESET}\n" "$1"
}

# 사용법 안내
echo
echo
echo
print_step_header " [ VMDiskResizer ]"
echo "  - 이 스크립트는 LVM으로 구성된 루트(/) 파티션의 용량을 확장합니다."
echo "  - 이 스크립트를 실행하기 전, 먼저 하이퍼바이저에서 VM의 디스크 크기를 늘려야 합니다."
echo
echo "     [1] VM 종료"
echo "     [2] XCP-ng에서 VM 선택"
echo "     [3] 'Storage' 탭에서 스토리지 선택"
echo "     [4] 'Size and Location' 탭에서 크기 조정"
echo
echo "  - 디스크 용량 증가 후, VM에 접속하여 이 스크립트를 실행합니다."
printf "  - 이 스크립트로 ${C_YELLOW}XFS 파일 시스템${C_RESET}의 크기를 한번 늘리면, ${C_RED}${C_BOLD}다시는 축소할 수 없습니다.${C_RESET}\n"
echo "  - 작업을 진행하기 전, 중요한 데이터는 반드시 백업해주십시오."
echo
printf "위 내용을 모두 확인했으며, 계속 진행하려면 'y'를 입력하고 Enter를 누르세요: "
read USER_INPUT
echo
echo

if [ "$USER_INPUT" != "y" ] && [ "$USER_INPUT" != "Y" ]; then
  printf "${C_RED}${C_BOLD}진행이 취소되었습니다. 'y'를 입력해야 진행됩니다.${C_RESET}\n"
  exit 1
fi

# 스크립트 시작
printf "> ${C_YELLOW}LVM Root Filesystem Resize Script Start.${C_RESET}\n"
echo

set -e

# [Step 1] 현재 디스크 크기 확인 (AS-IS)
print_step_header "[Step 1] Checking Current Disk Size (AS-IS)..."
FILE_PATH=$(df | grep -w '/' | awk '{print $1}')
df -hT / | awk -v cyan="$C_CYAN" -v reset="$C_RESET" 'NR==1 {printf "       %s\n", $0} NR==2 {printf "       %s%s%s\n", cyan, $0, reset}'
echo

# [Step 2] 루트 권한 확인
print_step_header "[Step 2] Checking Current User..."
if [ "$(whoami)" != "root" ]; then
  printf "${C_RED}Error: This script can only be run as the root user.${C_RESET}\n"
  printf "${C_YELLOW}Hint: Try running with 'sudo'${C_RESET}\n"
  exit 1
fi
echo "  > Root user check: OK"
echo

# [Step 3] 지원 OS 확인
print_step_header "[Step 3] Checking Operating System..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_MAJOR_VERSION=$(echo "$VERSION_ID" | cut -d. -f1)
else
    printf "${C_RED}Error: Cannot determine OS. /etc/os-release not found.${C_RESET}\n"
    exit 1
fi

# 지원 목록과 현재 OS를 비교
case "$ID-$OS_MAJOR_VERSION" in
    centos-7|centos-8)             ;;  # CentOS 7, 8 Stream
    rhel-7|rhel-8|rhel-9)          ;;  # RHEL 7, 8, 9
    rocky-8|rocky-9|rocky-10)      ;;  # Rocky Linux 8, 9, 10 -- 테스트예정
    almalinux-8|almalinux-9)       ;;  # AlmaLinux 8, 9
    ol-7|ol-8|ol-9)                ;;  # Oracle Linux 7, 8, 9
    ubuntu-20|ubuntu-22|ubuntu-24) ;;  # Ubuntu 20, 22, 24
    *)
        printf "${C_RED}Error: Unsupported OS detected.${C_RESET}\n"
        echo "  - Detected OS: ${PRETTY_NAME}"
        echo "  - This script is validated for: RHEL/CentOS 7/8/9, Ubuntu 20/22/24 and their derivatives."
        exit 1
        ;;
esac
echo "  > OS check: OK (${PRETTY_NAME})"
echo

# 명령어 실패 시 즉시 중단
set -e

# [Step 4] 디스크 및 LVM 정보 수집
print_step_header "[Step 4] Gathering Disk & LVM Information..."
FILE_PATH=$(df | grep -w '/' | awk '{print $1}')
FILE_TYPE=$(df -T | grep -w '/' | awk '{print $2}')
VG_NAME=$(lvs --noheadings -o vg_name "$FILE_PATH" | xargs)
LV_NAME=$(lvs --noheadings -o lv_name "$FILE_PATH" | xargs)
LV_PATH="/dev/$VG_NAME/$LV_NAME"
PV_NAME=$(pvs --noheadings -o pv_name,vg_name | grep -w "$VG_NAME" | awk '{print $1}')
DISK_NAME=$(echo "$PV_NAME" | sed 's/[0-9]*$//')
PART_NUM=$(echo "$PV_NAME" | sed 's/.*[^0-9]\([0-9]*\)$/\1/')
echo "  - LV Path         : ${FILE_PATH}"
echo "  - Filesystem Type : ${FILE_TYPE}"
echo "  - Volume Group    : ${VG_NAME}"
echo "  - Logical Volume  : ${LV_NAME}"
echo "  - Physical Volume : ${PV_NAME}"
echo "  - Target Disk     : ${DISK_NAME}"
echo "  - Partition Num   : ${PART_NUM}"
echo


# [Step 5] 파티션 확장
#if [ "$ID" = "ubuntu" ]; then
#    # growpart
#    print_step_header "[Step 5] Expanding Partition using growpart..."
#    if ! command -v growpart >/dev/null 2>&1; then
#        printf "${C_RED}Error: 'growpart' command not found.${C_RESET}\n"
#        printf "${C_YELLOW}Hint: On Ubuntu/Debian run 'sudo apt install -y cloud-guest-utils'${C_RESET}\n"
#        printf "${C_YELLOW}Hint: On RHEL/CentOS run 'sudo yum install -y cloud-utils-growpart'${C_RESET}\n"
#        exit 1
#    fi
#    growpart "$DISK_NAME" "$PART_NUM"
#else
#    # parted
#    print_step_header "[Step 5] Expanding Partition using parted..."
#    if ! command -v parted >/dev/null 2>&1; then
#        printf "${C_RED}Error: 'parted' command not found.${C_RESET}\n"
#        printf "${C_YELLOW}Hint (Ubuntu/Debian): sudo apt install -y parted${C_RESET}\n"
#        printf "${C_YELLOW}Hint (RHEL/CentOS):   sudo yum install -y parted${C_RESET}\n"
#        exit 1
#    fi
#    parted -s -- "$DISK_NAME" resizepart "$PART_NUM" 100%
#fi
#echo "  > Partition expanded successfully"
#echo



# [Step 5] 파티션 확장
if command -v growpart >/dev/null 2>&1; then
    print_step_header "[Step 5] Expanding Partition using growpart..."
    growpart "$DISK_NAME" "$PART_NUM"
    echo "  > Partition expanded successfully."
else
    if [ "$ID" = "ubuntu" ]; then
	    printf "${C_RED}Error: 'growpart' command not found.${C_RESET}\n"
		printf "${C_YELLOW}Hint: On Ubuntu/Debian run 'sudo apt install -y cloud-guest-utils'${C_RESET}\n"
        exit 1
    else
	    printf "${C_YELLOW}Notice: 'growpart' command not found. Trying parted...${C_RESET}\n"
        printf "${C_YELLOW}Hint: For best results, On RHEL/CentOS run 'sudo yum install -y cloud-utils-growpart'${C_RESET}\n"
        print_step_header "[Step 5] Expanding Partition using parted (Fallback)..."
        if ! command -v parted >/dev/null 2>&1; then
            printf "${C_RED}Error: Fallback command 'parted' also not found.${C_RESET}\n"
			printf "${C_YELLOW}Hint: On RHEL/CentOS run 'sudo yum install -y parted'${C_RESET}\n"
            exit 1
        fi
        parted -s -- "$DISK_NAME" resizepart "$PART_NUM" 100%
        echo "  > Partition expanded successfully using fallback method."
    fi
fi
echo
	
	

# [Step 6] 물리 볼륨(PV) 사이즈 변경
print_step_header "[Step 6] Resizing Physical Volume (PV)..."
pvresize_output=$(pvresize "$PV_NAME" 2>&1)
echo "  > PV resized successfully."
echo "     ${pvresize_output}"
echo

# [Step 7] 논리 볼륨(LV) 확장
print_step_header "[Step 7] Extending Logical Volume (LV)..."
FREE_PE=$(vgs --noheadings -o vg_free_count "$VG_NAME" | xargs)
if [ "$FREE_PE" -gt 0 ]; then
  if lvextend_output=$(lvextend -l +100%FREE "$LV_PATH" 2>&1); then
    printf "  > LV extended successfully.\n"
    echo "     ${lvextend_output}"
  else
    printf "${C_RED}Error: Failed to extend Logical Volume.${C_RESET}\n"
    printf "${C_YELLOW}Error Details:${C_RESET}\n%s\n" "${lvextend_output}"
    exit 1
  fi
else
  echo "  > No free space available in Volume Group '${VG_NAME}' to extend."
fi
echo

# [Step 8] 파일 시스템 확장
print_step_header "[Step 8] Expanding Filesystem..."
if [ "$FILE_TYPE" = "xfs" ]; then
  xfs_growfs "$FILE_PATH" >/dev/null 2>&1
  echo "  > Filesystem (xfs) expanded successfully."
elif [ "$FILE_TYPE" = "ext4" ]; then
  resize2fs "$FILE_PATH" > /dev/null 2>&1
  echo "  > Filesystem (ext4) expanded successfully."
else
  printf "${C_RED}Error: Unsupported filesystem: ${FILE_TYPE}${C_RESET}\n"
  exit 1
fi
echo

# [Step 9] 최종 디스크 크기 확인 (TO-BE)
print_step_header "[Step 9] Checking Final Disk Size (TO-BE)..."
df -hT / | awk -v cyan="$C_CYAN" -v reset="$C_RESET" 'NR==1 {printf "       %s\n", $0} NR==2 {printf "       %s%s%s\n", cyan, $0, reset}'
echo

# 스크립트 종료
printf "> ${C_YELLOW}Disk Resize Completed Successfully.${C_RESET}\n"
echo