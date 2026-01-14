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
if [[ -n "$SETTINGS_FILE" ]]; then
    echo "Settings:         $SETTINGS_FILE"
fi
echo -e "${GREEN}========================================${NC}"
echo ""

# 文件收集数组
declare -A snapshot_files  # 关联数组：key=groupId:artifactId:version:extension, value=文件路径列表（换行分隔）
declare -a release_files   # 普通数组：存储 release 文件路径

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

    # 获取相对路径
    local relative_path="${file_path#$repo_base/}"

    # 提取文件名和版本目录
    local filename=$(basename "$file_path")
    local version_dir=$(dirname "$file_path")
    local version=$(basename "$version_dir")

    # 提取artifactId
    local artifact_dir=$(dirname "$version_dir")
    local artifact_id=$(basename "$artifact_dir")

    # 提取groupId（剩余路径，转换/为.）
    local group_path=$(dirname "$artifact_dir")
    group_path="${group_path#$repo_base/}"
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

    # 如果存在pom文件，添加pom参数
    local pom_file="${file_path%.*}.pom"
    if [[ -f "$pom_file" ]] && [[ "$file_type" != "pom" ]]; then
        maven_cmd="$maven_cmd -DpomFile=$pom_file"
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
    local extension="${filename##*.}"

    # 分组键：groupId:artifactId:version:extension
    local group_key="$group_id:$artifact_id:$version:$extension"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))

    # 按版本类型分类
    if is_snapshot_version "$version"; then
        # SNAPSHOT版本：添加到分组（用换行分隔多个文件）
        if [[ -z "${snapshot_files[$group_key]}" ]]; then
            snapshot_files["$group_key"]="$file"
        else
            snapshot_files["$group_key"]+=$'\n'"$file"
        fi
    else
        # RELEASE版本：直接添加到列表
        release_files+=("$file")
    fi
}

# 处理单个构件
process_artifact() {
    local file="$1"

    # 解析Maven信息
    local maven_info=$(parse_maven_info "$file" "$REPO_DIR")
    IFS='|' read -r group_id artifact_id version <<< "$maven_info"

    # 获取文件扩展名
    local filename=$(basename "$file")
    local extension="${filename##*.}"

    # 推送文件并更新统计
    if deploy_file "$file" "$extension" "$group_id" "$artifact_id" "$version"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        if is_snapshot_version "$version"; then
            SNAPSHOT_SUCCESS=$((SNAPSHOT_SUCCESS + 1))
        else
            RELEASE_SUCCESS=$((RELEASE_SUCCESS + 1))
        fi
    else
        ERROR_COUNT=$((ERROR_COUNT + 1))
        if is_snapshot_version "$version"; then
            SNAPSHOT_ERROR=$((SNAPSHOT_ERROR + 1))
        else
            RELEASE_ERROR=$((RELEASE_ERROR + 1))
        fi
    fi
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

# 第二阶段：处理 RELEASE 文件
for file in "${release_files[@]}"; do
    process_artifact "$file"
done

# 第三阶段：处理 SNAPSHOT 文件（去重后）
for group_key in "${!snapshot_files[@]}"; do
    files="${snapshot_files[$group_key]}"

    # 如果该组只有一个文件，直接处理
    if [[ "$files" != *$'\n'* ]]; then
        process_artifact "$files"
    else
        # 多个文件：选择最新的
        latest=$(select_latest_snapshot "$files")
        file_count=$(echo "$files" | wc -l)

        if [[ "$MODE" == "test" ]]; then
            echo -e "${YELLOW}[DEDUP]${NC} $group_key: 发现 $file_count 个文件，选择最新: $(basename "$latest")"
        fi

        process_artifact "$latest"

        # 更新跳过计数（去重的文件算作跳过）
        SKIP_COUNT=$((SKIP_COUNT + file_count - 1))
    fi
done

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
