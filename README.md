# Maven仓库推送脚本使用说明

## 功能简介

`maven-deploy.sh` 是一个用于批量推送Maven构件到私有仓库的Shell脚本。它可以扫描指定的Maven仓库目录，解析构件信息，并使用Maven命令将其推送到目标私有仓库。**脚本支持自动识别release和snapshot版本，并将它们推送到不同的目标仓库。**

## 主要特性

- ✅ 自动扫描指定groupId目录下的所有Maven构件
- ✅ 自动解析groupId、artifactId、version信息
- ✅ **智能识别Release和Snapshot版本，自动路由到对应仓库**
- ✅ 支持指定自定义settings.xml文件
- ✅ 支持test/prod双模式（test模式仅打印命令，不执行）
- ✅ 支持多种构件类型（jar、pom、war、ear）
- ✅ 自动关联pom文件
- ✅ 智能过滤校验和文件和元数据文件
- ✅ 彩色输出和详细的分类统计信息（Release/Snapshot）

## 使用方法

### 基本语法

```bash
./maven-deploy.sh [选项]
```

### 参数说明

| 参数 | 长格式 | 说明 | 必需 | 默认值 |
|------|--------|------|------|--------|
| `-d` | `--directory` | 要扫描的Maven仓库目录 | ✅ | - |
| | `--release-url` | Release版本仓库URL | ✅ | - |
| | `--release-id` | Release版本仓库ID | ✅ | - |
| | `--snapshot-url` | Snapshot版本仓库URL | ✅ | - |
| | `--snapshot-id` | Snapshot版本仓库ID | ✅ | - |
| `-s` | `--settings` | Maven settings.xml文件路径 | ❌ | - |
| `-m` | `--mode` | 运行模式（test/prod） | ❌ | test |
| `-h` | `--help` | 显示帮助信息 | ❌ | - |

### 使用示例

#### 1. Test模式 - 预览推送命令（推荐先执行）

```bash
./maven-deploy.sh \
  -d /path/to/maven/repo/com/example \
  --release-url http://nexus.example.com/repository/releases \
  --release-id release-repo \
  --snapshot-url http://nexus.example.com/repository/snapshots \
  --snapshot-id snapshot-repo \
  -m test
```

输出示例：
```
========================================
Maven仓库推送脚本
========================================
扫描目录:         /path/to/maven/repo/com/example
Release仓库URL:   http://nexus.example.com/repository/releases
Release仓库ID:    release-repo
Snapshot仓库URL:  http://nexus.example.com/repository/snapshots
Snapshot仓库ID:   snapshot-repo
运行模式:         test
========================================

[TEST][RELEASE] mvn deploy:deploy-file -DgroupId=com.example -DartifactId=my-app -Dversion=1.0.0 ...
[TEST][SNAPSHOT] mvn deploy:deploy-file -DgroupId=com.example.service -DartifactId=user-service -Dversion=1.0.1-SNAPSHOT ...

========================================
推送统计
========================================
总文件数:   45
跳过文件:   20
测试命令:   25
  - Release:  15
  - Snapshot: 10
========================================
```

#### 2. Prod模式 - 实际执行推送

```bash
./maven-deploy.sh \
  -d /path/to/maven/repo/com/example \
  --release-url http://nexus.example.com/repository/releases \
  --release-id release-repo \
  --snapshot-url http://nexus.example.com/repository/snapshots \
  --snapshot-id snapshot-repo \
  -s /path/to/settings.xml \
  -m prod
```

#### 3. 推送整个本地仓库的某个groupId

```bash
./maven-deploy.sh \
  -d ~/.m2/repository/com/mycompany \
  --release-url http://nexus.internal/repository/releases \
  --release-id internal-releases \
  --snapshot-url http://nexus.internal/repository/snapshots \
  --snapshot-id internal-snapshots \
  -s ~/.m2/settings.xml \
  -m prod
```

#### 4. 扫描多个groupId（使用循环）

```bash
# 推送多个groupId
for group_dir in /path/to/maven/repo/com/example /path/to/maven/repo/org/mycompany; do
  ./maven-deploy.sh \
    -d "$group_dir" \
    --release-url http://nexus.example.com/repository/releases \
    --release-id release-repo \
    --snapshot-url http://nexus.example.com/repository/snapshots \
    --snapshot-id snapshot-repo \
    -m prod
done
```

## 版本类型识别

脚本会自动识别Maven构件的版本类型：

- **Release版本**：版本号不包含`-SNAPSHOT`后缀
  - 示例：`1.0.0`、`2.3.1`、`1.0.0-RC1`
  - 推送到：`--release-url` 指定的仓库

- **Snapshot版本**：版本号以`-SNAPSHOT`结尾
  - 示例：`1.0.0-SNAPSHOT`、`2.3.1-SNAPSHOT`
  - 推送到：`--snapshot-url` 指定的仓库

## 工作原理

1. **扫描阶段**：递归扫描指定目录，查找所有 `.jar`、`.pom`、`.war`、`.ear` 文件
2. **解析阶段**：从文件路径中解析出 `groupId`、`artifactId`、`version` 信息
3. **过滤阶段**：自动跳过校验和文件（.md5、.sha1等）和元数据文件
4. **版本识别**：判断版本是Release还是Snapshot（检查版本号是否包含`-SNAPSHOT`）
5. **推送阶段**：
   - **Test模式**：打印完整的Maven推送命令（标注版本类型）
   - **Prod模式**：实际执行 `mvn deploy:deploy-file` 命令，根据版本类型路由到对应仓库

## Settings.xml配置

如果目标仓库需要认证，需要在 `settings.xml` 中配置仓库凭据：

```xml
<settings>
  <servers>
    <!-- Release仓库认证 -->
    <server>
      <id>release-repo</id>  <!-- 与脚本的 --release-id 参数匹配 -->
      <username>your-username</username>
      <password>your-password</password>
    </server>

    <!-- Snapshot仓库认证 -->
    <server>
      <id>snapshot-repo</id>  <!-- 与脚本的 --snapshot-id 参数匹配 -->
      <username>your-username</username>
      <password>your-password</password>
    </server>
  </servers>
</settings>
```

**注意**：
- `<server><id>` 必须与脚本的 `--release-id` 和 `--snapshot-id` 参数匹配
- Release和Snapshot可以使用相同的认证凭据（如果仓库配置允许）
- 如果两个仓库使用相同的认证凭据，仓库ID可以相同

## 注意事项

1. **先切换到仓库目录**：执行脚本前，请先 `cd` 到 Maven 仓库目录，确保脚本能正确扫描构件
2. **先用test模式测试**：建议先使用 `-m test` 模式查看将要执行的命令，确认无误后再使用 `-m prod` 执行
2. **仓库ID匹配**：确保 `--release-id` 和 `--snapshot-id` 参数与 `settings.xml` 中的 `<server><id>` 匹配
3. **网络连接**：确保能够访问目标仓库URL
4. **权限验证**：确保提供的认证凭据具有推送权限
5. **目录结构**：脚本假设输入目录遵循标准Maven仓库结构：`groupId/artifactId/version/artifactId-version.jar`
6. **版本混合**：脚本可以在一次执行中同时处理Release和Snapshot版本，自动路由到正确的仓库

## 典型使用场景

### 场景1：迁移Maven本地仓库到私有仓库

```bash
# 1. 先测试某个groupId
./maven-deploy.sh \
  -d ~/.m2/repository/com/mycompany \
  --release-url http://nexus.internal/repository/releases \
  --release-id internal-releases \
  --snapshot-url http://nexus.internal/repository/snapshots \
  --snapshot-id internal-snapshots \
  -m test

# 2. 确认无误后执行
./maven-deploy.sh \
  -d ~/.m2/repository/com/mycompany \
  --release-url http://nexus.internal/repository/releases \
  --release-id internal-releases \
  --snapshot-url http://nexus.internal/repository/snapshots \
  --snapshot-id internal-snapshots \
  -s ~/.m2/settings.xml \
  -m prod
```

### 场景2：批量推送离线拷贝的jar包

```bash
# 假设从其他机器拷贝了jar包到 /tmp/maven-backup
# 该目录包含混合的release和snapshot版本
./maven-deploy.sh \
  -d /tmp/maven-backup/com/example \
  --release-url http://nexus.example.com/repository/releases \
  --release-id release-repo \
  --snapshot-url http://nexus.example.com/repository/snapshots \
  --snapshot-id snapshot-repo \
  -s /opt/maven/settings.xml \
  -m prod
```

### 场景3：推送第三方库到团队私有仓库

```bash
# 推送第三方开源库（通常只有release版本）
./maven-deploy.sh \
  -d ~/.m2/repository/org/springframework \
  --release-url http://nexus.company.com/repository/third-party \
  --release-id company-third-party \
  --snapshot-url http://nexus.company.com/repository/snapshots \
  --snapshot-id company-snapshots \
  -s ~/.m2/company-settings.xml \
  -m prod
```

### 场景4：持续集成环境构件推送

```bash
# CI/CD流程中推送构建产物
# 通常snapshot用于开发分支，release用于发布分支
./maven-deploy.sh \
  -d ./target/maven-repository \
  --release-url ${NEXUS_RELEASE_URL} \
  --release-id nexus-releases \
  --snapshot-url ${NEXUS_SNAPSHOT_URL} \
  --snapshot-id nexus-snapshots \
  -s ./ci-settings.xml \
  -m prod
```

## 故障排查

### 问题1：推送失败 - 401 Unauthorized

**原因**：认证失败

**解决**：检查 `settings.xml` 中的用户名密码是否正确，仓库ID是否匹配（`--release-id` 和 `--snapshot-id`）

### 问题2：推送失败 - 400 Bad Request

**原因**：可能构件已存在且仓库不允许重新部署，或版本类型不匹配

**解决**：
- 检查目标仓库的部署策略（Snapshot vs Release）
- 确认Snapshot版本是否被推送到了Snapshot仓库
- 确认Release版本是否被推送到了Release仓库
- 或者使用允许重新部署的仓库

### 问题3：版本类型识别错误

**原因**：版本号命名不符合Maven规范

**解决**：
- Snapshot版本必须以`-SNAPSHOT`结尾
- 检查版本号格式是否正确
- 使用test模式查看版本类型标签 `[RELEASE]` 或 `[SNAPSHOT]`

### 问题4：找不到构件

**原因**：目录结构不符合Maven仓库标准

**解决**：确保目录结构为：`groupId/artifactId/version/`

### 问题5：缺少必需参数

**原因**：未提供所有必需的仓库配置

**解决**：必须同时提供4个仓库参数：
```bash
--release-url <URL>
--release-id <ID>
--snapshot-url <URL>
--snapshot-id <ID>
```

### 问题4：mvn命令未找到

**原因**：Maven未安装或未添加到PATH

**解决**：
```bash
# macOS
brew install maven

# Linux
sudo apt-get install maven  # Debian/Ubuntu
sudo yum install maven      # CentOS/RHEL
```

---

# Nexus仓库下载脚本使用说明

## 功能简介

`download_nexus.py` 是一个用于从Nexus私有仓库批量下载Maven构件的Python脚本。它可以下载指定groupId（及其子group）的所有jar和pom文件，并保持Maven标准目录结构。

## 主要特性

- ✅ 支持指定groupId下载，自动包含所有子group
- ✅ 自动下载jar和pom文件
- ✅ 保持Maven仓库标准目录结构
- ✅ 支持分页获取大量构件
- ✅ 自动跳过已存在的文件（断点续传）
- ✅ 网络错误自动重试
- ✅ 404文件自动跳过（不浪费重试次数）

## 环境准备

```bash
# 创建虚拟环境
python3 -m venv venv

# 激活虚拟环境
source venv/bin/activate

# 安装依赖
pip install requests
```

## 使用方法

### 基本语法

```bash
python3 download_nexus.py [选项]
```

### 参数说明

| 参数 | 长格式 | 说明 | 必需 | 默认值 |
|------|--------|------|------|--------|
| `-u` | `--url` | Nexus仓库URL | ✅ | - |
| | `--user` | Nexus用户名 | ✅ | - |
| | `--password` | Nexus密码 | ✅ | - |
| `-g` | `--group` | 要下载的groupId | ✅ | - |
| `-r` | `--repository` | 仓库名称 | ❌ | maven-releases |

### 使用示例

#### 1. 下载指定groupId的所有构件

```bash
python3 download_nexus.py \
  -u https://nexus.example.com \
  --user repo-reader \
  --password 'your-password' \
  -g com.csntcorp.common
```

#### 2. 下载groupId及其所有子group

```bash
# 下载 com.iflorens 及 com.iflorens.framework、com.iflorens.common 等所有子group
python3 download_nexus.py \
  -u https://nexus.example.com \
  --user repo-reader \
  --password 'your-password' \
  -g com.iflorens
```

#### 3. 指定仓库名称

```bash
python3 download_nexus.py \
  -u https://nexus.example.com \
  --user repo-reader \
  --password 'your-password' \
  -g com.csntcorp \
  -r maven-releases
```

### 输出示例

```
Nexus仓库: https://nexus.example.com
Repository: maven-releases
GroupId: com.iflorens
输出目录: repo/

搜索 jar 文件...
  继续获取下一页... (已获取 85 个)
  找到 173 个 jar 文件
搜索 pom 文件...
  继续获取下一页... (已获取 50 个)
  找到 111 个 pom 文件

共找到 284 个文件，开始下载...

[1/284] 下载: /com/iflorens/framework/my-app/1.0.0/my-app-1.0.0.jar
[2/284] 已存在: /com/iflorens/framework/my-app/1.0.0/my-app-1.0.0.pom
[3/284] 下载: /com/iflorens/common/utils/2.0.0/utils-2.0.0.jar
    跳过: 文件不存在 (404)
...

下载完成: 成功 250, 跳过 30, 失败 4
```

## 输出目录结构

下载的文件保存在 `repo/` 目录，遵循Maven标准结构：

```
repo/
└── com/
    └── iflorens/
        ├── framework/
        │   └── my-app/
        │       └── 1.0.0/
        │           ├── my-app-1.0.0.jar
        │           └── my-app-1.0.0.pom
        └── common/
            └── utils/
                └── 2.0.0/
                    ├── utils-2.0.0.jar
                    └── utils-2.0.0.pom
```

## 与推送脚本配合使用

下载的 `repo/` 目录可以直接作为 `maven-deploy.sh` 的输入目录：

```bash
# 1. 从源Nexus下载
python3 download_nexus.py \
  -u https://source-nexus.example.com \
  --user repo-reader \
  --password 'your-password' \
  -g com.iflorens

# 2. 推送到目标Nexus
./maven-deploy.sh \
  -d ./repo/com/iflorens \
  --release-url http://target-nexus/repository/releases \
  --release-id target-releases \
  --snapshot-url http://target-nexus/repository/snapshots \
  --snapshot-id target-snapshots \
  -m prod
```

## 故障排查

### 问题1：搜索API调用失败 - 401 Unauthorized

**原因**：认证失败

**解决**：检查 `--user` 和 `--password` 参数是否正确

### 问题2：大量文件显示404跳过

**原因**：Nexus索引中存在记录但实际文件已被删除

**解决**：这是正常情况，脚本会自动跳过这些文件

### 问题3：下载速度慢

**原因**：网络问题或文件较大

**解决**：脚本支持断点续传，可以中断后重新运行，已下载的文件会自动跳过

---

## 许可证

MIT License
