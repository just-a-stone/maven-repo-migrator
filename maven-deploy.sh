#!/usr/bin/env bash

# Maven仓库推送脚本
# 功能：扫描指定groupId目录，将jar包推送到新的私有仓库

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印使用说明
usage() {
    cat << EOF
使用说明:
    $0 [选项]

选项:
    -d, --directory <目录>          指定要扫描的Maven仓库目录（必需）
    --release-url <URL>             Release仓库URL（必需）
    --release-id <ID>               Release仓库ID（必需）
    --snapshot-url <URL>            Snapshot仓库URL（必需）
    --snapshot-id <ID>              Snapshot仓库ID（必需）
    -s, --settings <文件>           指定Maven settings.xml文件路径（可选）
    -m, --mode <模式>               运行模式: test 或 prod（默认: test）
    -j, --jobs <数量>               并发上传数量（默认: 4）
    -h, --help                      显示此帮助信息

示例:
    # test模式（仅打印命令）
    $0 -d /path/to/maven/repo/com/example \\
       --release-url http://nexus.example.com/repository/releases \\
       --release-id release-repo \\
       --snapshot-url http://nexus.example.com/repository/snapshots \\
       --snapshot-id snapshot-repo \\
       -m test

    # prod模式（实际执行）
    $0 -d /path/to/maven/repo/com/example \\
       --release-url http://nexus.example.com/repository/releases \\
       --release-id release-repo \\
       --snapshot-url http://nexus.example.com/repository/snapshots \\
       --snapshot-id snapshot-repo \\
       -s /path/to/settings.xml \\
       -m prod

EOF
    exit 1
}

# 参数初始化
REPO_DIR=""
RELEASE_REPO_URL=""
RELEASE_REPO_ID=""
SNAPSHOT_REPO_URL=""
SNAPSHOT_REPO_ID=""
SETTINGS_FILE=""
MODE="test"
PARALLEL_JOBS=4  # 默认并发数

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--directory)
            REPO_DIR="$2"
            shift 2
            ;;
        --release-url)
            RELEASE_REPO_URL="$2"
            shift 2
            ;;
        --release-id)
            RELEASE_REPO_ID="$2"
            shift 2
            ;;
        --snapshot-url)
            SNAPSHOT_REPO_URL="$2"
            shift 2
            ;;
        --snapshot-id)
            SNAPSHOT_REPO_ID="$2"
            shift 2
            ;;
        -s|--settings)
            SETTINGS_FILE="$2"
            shift 2
            ;;
        -m|--mode)
            MODE="$2"
            shift 2
            ;;
        -j|--jobs)
            if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo -e "${RED}错误: 并发数必须是正整数${NC}"
                exit 1
            fi
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}错误: 未知参数 $1${NC}"
            usage
            ;;
    esac
done

# 验证必需参数
if [[ -z "$REPO_DIR" ]]; then
    echo -e "${RED}错误: 必须指定仓库目录 (-d)${NC}"
    usage
fi

if [[ -z "$RELEASE_REPO_URL" ]]; then
    echo -e "${RED}错误: 必须指定Release仓库URL (--release-url)${NC}"
    usage
fi

if [[ -z "$RELEASE_REPO_ID" ]]; then
    echo -e "${RED}错误: 必须指定Release仓库ID (--release-id)${NC}"
    usage
fi

if [[ -z "$SNAPSHOT_REPO_URL" ]]; then
    echo -e "${RED}错误: 必须指定Snapshot仓库URL (--snapshot-url)${NC}"
    usage
fi

if [[ -z "$SNAPSHOT_REPO_ID" ]]; then
    echo -e "${RED}错误: 必须指定Snapshot仓库ID (--snapshot-id)${NC}"
    usage
fi

# 验证目录存在
if [[ ! -d "$REPO_DIR" ]]; then
    echo -e "${RED}错误: 目录不存在: $REPO_DIR${NC}"
    exit 1
fi

# 验证settings文件（如果指定）
if [[ -n "$SETTINGS_FILE" ]] && [[ ! -f "$SETTINGS_FILE" ]]; then
    echo -e "${RED}错误: Settings文件不存在: $SETTINGS_FILE${NC}"
    exit 1
fi

# 验证模式
if [[ "$MODE" != "test" ]] && [[ "$MODE" != "prod" ]]; then
    echo -e "${RED}错误: 模式必须是 'test' 或 'prod'${NC}"
    usage
fi

# 打印配置信息
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Maven仓库推送脚本${NC}"
echo -e "${GREEN}========================================${NC}"
echo "扫描目录:         $REPO_DIR"
echo "Release仓库URL:   $RELEASE_REPO_URL"
echo "Release仓库ID:    $RELEASE_REPO_ID"
echo "Snapshot仓库URL:  $SNAPSHOT_REPO_URL"
echo "Snapshot仓库ID:   $SNAPSHOT_REPO_ID"
echo "运行模式:         $MODE"
echo "并发数:           $PARALLEL_JOBS"
if [[ -n "$SETTINGS_FILE" ]]; then
    echo "Settings:         $SETTINGS_FILE"
fi
echo -e "${GREEN}========================================${NC}"
echo ""

# 创建临时目录存储并发结果
RESULT_DIR=$(mktemp -d)
trap 'rm -rf "$RESULT_DIR"' EXIT

# 文件收集数组
# snapshot_files: key=groupId:artifactId:version, value=文件路径列表（换行分隔，包含jar/pom等）
declare -A snapshot_files
# release_files: key=groupId:artifactId:version, value=文件路径列表（换行分隔）
declare -A release_files

# 统计变量
TOTAL_COUNT=0
SUCCESS_COUNT=0
SKIP_COUNT=0
ERROR_COUNT=0
RELEASE_SUCCESS=0
RELEASE_ERROR=0
SNAPSHOT_SUCCESS=0
SNAPSHOT_ERROR=0

# 从文件路径解析groupId, artifactId, version
parse_maven_info() {
    local file_path="$1"
    local repo_base="$2"

    # 提取文件名和版本目录
    local filename=$(basename "$file_path")
    local version_dir=$(dirname "$file_path")
    local version=$(basename "$version_dir")

    # 提取artifactId
    local artifact_dir=$(dirname "$version_dir")
    local artifact_id=$(basename "$artifact_dir")

    # 提取groupId（使用完整路径，转换/为.）
    local group_path=$(dirname "$artifact_dir")
    local group_id=$(echo "$group_path" | tr '/' '.')

    echo "$group_id|$artifact_id|$version"
}

# 判断版本是否为snapshot
is_snapshot_version() {
    local version="$1"
    if [[ "$version" =~ -SNAPSHOT$ ]]; then
        return 0  # 是snapshot
    else
        return 1  # 是release
    fi
}

# 检查是否为有效的maven构件文件
is_valid_artifact() {
    local file="$1"
    local filename=$(basename "$file")

    # 排除校验和文件、临时文件等
    if [[ "$filename" =~ \.(md5|sha1|sha256|sha512|asc|lastUpdated|repositories)$ ]]; then
        return 1
    fi

    # 排除 maven-metadata 文件
    if [[ "$filename" =~ ^maven-metadata ]]; then
        return 1
    fi

    return 0
}

# 推送单个文件
deploy_file() {
    local file_path="$1"
    local file_type="$2"
    local group_id="$3"
    local artifact_id="$4"
    local version="$5"
    local paired_pom="$6"  # 配对的pom文件（可能为空）

    # 根据版本类型选择仓库
    local target_url
    local target_id
    local version_type
    if is_snapshot_version "$version"; then
        target_url="$SNAPSHOT_REPO_URL"
        target_id="$SNAPSHOT_REPO_ID"
        version_type="SNAPSHOT"
    else
        target_url="$RELEASE_REPO_URL"
        target_id="$RELEASE_REPO_ID"
        version_type="RELEASE"
    fi

    # 构建Maven命令
    local maven_cmd="mvn deploy:deploy-file"
    maven_cmd="$maven_cmd -DgroupId=$group_id"
    maven_cmd="$maven_cmd -DartifactId=$artifact_id"
    maven_cmd="$maven_cmd -Dversion=$version"
    maven_cmd="$maven_cmd -Dpackaging=$file_type"
    maven_cmd="$maven_cmd -Dfile=$file_path"
    maven_cmd="$maven_cmd -Durl=$target_url"
    maven_cmd="$maven_cmd -DrepositoryId=$target_id"

    # 使用配对的pom文件
    if [[ -n "$paired_pom" ]] && [[ -f "$paired_pom" ]] && [[ "$file_type" != "pom" ]]; then
        maven_cmd="$maven_cmd -DpomFile=$paired_pom"
    elif [[ "$file_type" == "pom" ]]; then
        # 上传pom文件时，使用pom文件本身作为pomFile
        maven_cmd="$maven_cmd -DpomFile=$file_path"
    fi

    # 添加settings参数
    if [[ -n "$SETTINGS_FILE" ]]; then
        maven_cmd="$maven_cmd -s $SETTINGS_FILE"
    fi

    # test模式：仅打印命令
    if [[ "$MODE" == "test" ]]; then
        echo -e "${YELLOW}[TEST][$version_type]${NC} $maven_cmd"
        return 0
    fi

    # prod模式：执行命令
    echo -e "${GREEN}[DEPLOY][$version_type]${NC} $group_id:$artifact_id:$version ($file_type)"
    if eval "$maven_cmd" > /dev/null 2>&1; then
        echo -e "${GREEN}  ✓ 成功${NC}"
        return 0
    else
        echo -e "${RED}  ✗ 失败${NC}"
        return 1
    fi
}

# 从SNAPSHOT文件名提取时间戳和构建号
extract_snapshot_build_number() {
    local filepath="$1"
    local filename=$(basename "$filepath")

    # 匹配模式：artifactId-version-YYYYMMDD.HHMMSS-buildNumber.extension
    # 例如：myapp-1.0.0-20231201.120000-1.jar
    # 提取：20231201120000001（用于数字排序）

    if [[ "$filename" =~ -([0-9]{8}\.[0-9]{6})-([0-9]+)\. ]]; then
        local timestamp="${BASH_REMATCH[1]/./}"  # 移除点号：20231201120000
        local buildnum="${BASH_REMATCH[2]}"       # 构建号：1
        printf "%s%05d" "$timestamp" "$buildnum"  # 组合：20231201120000000001
        return 0
    fi
    return 1  # 没有时间戳
}

# 从SNAPSHOT文件列表中选择最新的文件
select_latest_snapshot() {
    local files="$1"  # 换行分隔的文件列表

    local latest_file=""
    local latest_sort_key=""

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # 尝试提取时间戳构建号
        local build_key
        if build_key=$(extract_snapshot_build_number "$file"); then
            # 有时间戳：使用时间戳+构建号排序
            local sort_key="$build_key"
        else
            # 无时间戳：使用文件修改时间（秒级时间戳）
            local sort_key=$(stat -f "%m" "$file" 2>/dev/null || stat -c "%Y" "$file" 2>/dev/null)
        fi

        # 比较并保留最新的
        if [[ -z "$latest_file" ]] || [[ "$sort_key" > "$latest_sort_key" ]]; then
            latest_file="$file"
            latest_sort_key="$sort_key"
        fi
    done <<< "$files"

    echo "$latest_file"
}

# 从文件组中选择主构件及其配对的pom
# 返回格式：主构件路径|pom路径（pom可能为空）
select_artifact_with_pom() {
    local files="$1"  # 换行分隔的文件列表
    local is_snapshot="$2"  # 是否为snapshot版本

    # 分离主构件（jar/war/ear）和pom文件
    local main_artifacts=""
    local pom_files=""

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local ext="${file##*.}"
        if [[ "$ext" == "pom" ]]; then
            if [[ -z "$pom_files" ]]; then
                pom_files="$file"
            else
                pom_files+=$'\n'"$file"
            fi
        else
            if [[ -z "$main_artifacts" ]]; then
                main_artifacts="$file"
            else
                main_artifacts+=$'\n'"$file"
            fi
        fi
    done <<< "$files"

    # 如果没有主构件，只有pom，则返回pom作为主构件
    if [[ -z "$main_artifacts" ]]; then
        if [[ "$is_snapshot" == "true" ]]; then
            local selected_pom=$(select_latest_snapshot "$pom_files")
        else
            local selected_pom=$(echo "$pom_files" | head -1)
        fi
        echo "$selected_pom|"
        return
    fi

    # 选择最新的主构件
    local selected_main
    if [[ "$is_snapshot" == "true" ]]; then
        selected_main=$(select_latest_snapshot "$main_artifacts")
    else
        selected_main=$(echo "$main_artifacts" | head -1)
    fi

    # 查找配对的pom（同名但扩展名为.pom）
    local main_base="${selected_main%.*}"
    local paired_pom="${main_base}.pom"

    if echo "$pom_files" | grep -qxF "$paired_pom"; then
        echo "$selected_main|$paired_pom"
    else
        echo "$selected_main|"
    fi
}

# 收集构件文件（分类为SNAPSHOT和RELEASE）
collect_artifact() {
    local file="$1"

    # 检查是否为有效构件
    if ! is_valid_artifact "$file"; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi

    # 跳过源码和javadoc包
    local filename=$(basename "$file")
    if [[ "$filename" =~ -sources\. ]] || [[ "$filename" =~ -javadoc\. ]]; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi

    # 解析Maven信息
    local maven_info=$(parse_maven_info "$file" "$REPO_DIR")
    IFS='|' read -r group_id artifact_id version <<< "$maven_info"

    # 分组键：groupId:artifactId:version（不含extension，让jar和pom配对）
    local group_key="$group_id:$artifact_id:$version"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))

    # 按版本类型分类
    if is_snapshot_version "$version"; then
        # SNAPSHOT版本：添加到分组
        if [[ -z "${snapshot_files[$group_key]}" ]]; then
            snapshot_files["$group_key"]="$file"
        else
            snapshot_files["$group_key"]+=$'\n'"$file"
        fi
    else
        # RELEASE版本：也按分组存储
        if [[ -z "${release_files[$group_key]}" ]]; then
            release_files["$group_key"]="$file"
        else
            release_files["$group_key"]+=$'\n'"$file"
        fi
    fi
}

# 处理单个构件
process_artifact() {
    local file="$1"
    local paired_pom="$2"  # 配对的pom文件路径（可能为空）

    # 解析Maven信息
    local maven_info=$(parse_maven_info "$file" "$REPO_DIR")
    IFS='|' read -r group_id artifact_id version <<< "$maven_info"

    # 获取文件扩展名
    local filename=$(basename "$file")
    local extension="${filename##*.}"

    # 确定版本类型
    local version_type
    if is_snapshot_version "$version"; then
        version_type="SNAPSHOT"
    else
        version_type="RELEASE"
    fi

    # 推送文件并记录结果到临时文件
    local result_file="$RESULT_DIR/result_$$_$RANDOM"
    if deploy_file "$file" "$extension" "$group_id" "$artifact_id" "$version" "$paired_pom"; then
        echo "SUCCESS|$version_type" >> "$result_file"
    else
        echo "ERROR|$version_type" >> "$result_file"
    fi
}

# 并发执行函数
# 参数格式：file1|pom1 file2|pom2 ...
run_parallel() {
    local pids=()
    for item in "$@"; do
        local file="${item%%|*}"
        local pom="${item#*|}"
        [[ "$pom" == "$file" ]] && pom=""  # 没有|分隔符时pom为空

        (process_artifact "$file" "$pom") &
        pids+=($!)
        # 达到并发上限时等待一个任务完成
        if [[ ${#pids[@]} -ge $PARALLEL_JOBS ]]; then
            # 等待任意一个任务完成
            wait -n 2>/dev/null || wait "${pids[0]}"
            # 清理已完成的进程
            local new_pids=()
            for pid in "${pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids+=("$pid")
                fi
            done
            pids=("${new_pids[@]}")
        fi
    done
    # 等待所有剩余任务完成
    wait
}

# 扫描并处理所有构件
echo -e "${GREEN}开始扫描目录...${NC}"
echo ""

# 第一阶段：收集所有文件
while IFS= read -r -d '' file; do
    collect_artifact "$file"
done < <(find "$REPO_DIR" -type f \( -name "*.jar" -o -name "*.pom" -o -name "*.war" -o -name "*.ear" \) -print0)

echo -e "${GREEN}文件收集完成，开始处理...${NC}"
echo ""

# 第二阶段：处理 RELEASE 文件（并发）
declare -a release_to_process
for group_key in "${!release_files[@]}"; do
    files="${release_files[$group_key]}"

    # 选择主构件及配对的pom
    result=$(select_artifact_with_pom "$files" "false")
    main_file="${result%%|*}"
    paired_pom="${result#*|}"

    if [[ -n "$main_file" ]]; then
        release_to_process+=("$main_file|$paired_pom")

        # 计算跳过的文件数（总文件数 - 1个主构件 - 配对pom是否被使用）
        file_count=$(echo "$files" | wc -l)
        skipped=$((file_count - 1))
        [[ -n "$paired_pom" ]] && skipped=$((skipped - 1))
        [[ $skipped -gt 0 ]] && SKIP_COUNT=$((SKIP_COUNT + skipped))
    fi
done

if [[ ${#release_to_process[@]} -gt 0 ]]; then
    run_parallel "${release_to_process[@]}"
fi

# 第三阶段：处理 SNAPSHOT 文件（去重后，并发）
declare -a snapshot_to_process
for group_key in "${!snapshot_files[@]}"; do
    files="${snapshot_files[$group_key]}"

    # 选择最新的主构件及配对的pom
    result=$(select_artifact_with_pom "$files" "true")
    main_file="${result%%|*}"
    paired_pom="${result#*|}"

    if [[ -n "$main_file" ]]; then
        snapshot_to_process+=("$main_file|$paired_pom")

        # 计算跳过的文件数
        file_count=$(echo "$files" | wc -l)
        skipped=$((file_count - 1))
        [[ -n "$paired_pom" ]] && skipped=$((skipped - 1))

        if [[ $skipped -gt 0 ]]; then
            if [[ "$MODE" == "test" ]]; then
                echo -e "${YELLOW}[DEDUP]${NC} $group_key: 发现 $file_count 个文件，选择最新: $(basename "$main_file")"
            fi
            SKIP_COUNT=$((SKIP_COUNT + skipped))
        fi
    fi
done

if [[ ${#snapshot_to_process[@]} -gt 0 ]]; then
    run_parallel "${snapshot_to_process[@]}"
fi

# 汇总统计结果
while IFS='|' read -r status type; do
    case "$status|$type" in
        SUCCESS|RELEASE)
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            RELEASE_SUCCESS=$((RELEASE_SUCCESS + 1))
            ;;
        SUCCESS|SNAPSHOT)
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            SNAPSHOT_SUCCESS=$((SNAPSHOT_SUCCESS + 1))
            ;;
        ERROR|RELEASE)
            ERROR_COUNT=$((ERROR_COUNT + 1))
            RELEASE_ERROR=$((RELEASE_ERROR + 1))
            ;;
        ERROR|SNAPSHOT)
            ERROR_COUNT=$((ERROR_COUNT + 1))
            SNAPSHOT_ERROR=$((SNAPSHOT_ERROR + 1))
            ;;
    esac
done < <(cat "$RESULT_DIR"/result_* 2>/dev/null)

# 打印统计信息
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}推送统计${NC}"
echo -e "${GREEN}========================================${NC}"
echo "总文件数:   $TOTAL_COUNT"
echo "跳过文件:   $SKIP_COUNT"
if [[ "$MODE" == "test" ]]; then
    echo -e "${YELLOW}测试命令:   $((TOTAL_COUNT - SKIP_COUNT))${NC}"
    echo "  - Release:  $((RELEASE_SUCCESS + RELEASE_ERROR))"
    echo "  - Snapshot: $((SNAPSHOT_SUCCESS + SNAPSHOT_ERROR))"
else
    echo -e "${GREEN}成功推送:   $SUCCESS_COUNT${NC}"
    echo "  - Release:  $RELEASE_SUCCESS"
    echo "  - Snapshot: $SNAPSHOT_SUCCESS"
    if [[ $ERROR_COUNT -gt 0 ]]; then
        echo -e "${RED}失败推送:   $ERROR_COUNT${NC}"
        echo "  - Release:  $RELEASE_ERROR"
        echo "  - Snapshot: $SNAPSHOT_ERROR"
    fi
fi
echo -e "${GREEN}========================================${NC}"

# 根据模式提示
if [[ "$MODE" == "test" ]]; then
    echo ""
    echo -e "${YELLOW}注意: 当前为TEST模式，未实际执行推送${NC}"
    echo -e "${YELLOW}如需实际推送，请使用 -m prod 参数${NC}"
fi

# 返回错误码
if [[ $ERROR_COUNT -gt 0 ]]; then
    exit 1
fi

exit 0
