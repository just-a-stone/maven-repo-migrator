#!/usr/bin/env python3
"""
Nexus Maven Repository Jar Download Script

从Nexus仓库下载指定groupId的所有jar和pom文件
"""

import argparse
import os
import re
import sys
from urllib.parse import urljoin
import requests
from requests.auth import HTTPBasicAuth


# 默认配置
DEFAULT_REPOSITORY = "maven-releases"
OUTPUT_DIR = "repo"


def parse_args():
    """解析命令行参数"""
    parser = argparse.ArgumentParser(
        description="从Nexus仓库下载指定groupId的jar和pom文件"
    )
    parser.add_argument(
        "-u", "--url",
        required=True,
        help="Nexus仓库URL (例如: https://nexus.example.com)"
    )
    parser.add_argument(
        "--user",
        required=True,
        help="Nexus用户名"
    )
    parser.add_argument(
        "--password",
        required=True,
        help="Nexus密码"
    )
    parser.add_argument(
        "-g", "--group",
        required=True,
        help="要下载的groupId (例如: com.csntcorp.common)"
    )
    parser.add_argument(
        "-r", "--repository",
        default=DEFAULT_REPOSITORY,
        help=f"仓库名称 (默认: {DEFAULT_REPOSITORY})"
    )
    return parser.parse_args()


def group_to_path_prefix(group_id):
    """将groupId转换为路径前缀 (com.example -> com/example)"""
    return group_id.replace(".", "/")


def search_assets(nexus_url, group_id, repository, extension, auth):
    """
    搜索Nexus仓库中的assets（包括子group）

    Args:
        nexus_url: Nexus仓库URL
        group_id: Maven groupId (支持前缀匹配，如 com.example 会匹配 com.example.*)
        repository: 仓库名称
        extension: 文件扩展名 (jar/pom)
        auth: HTTP认证信息

    Returns:
        所有匹配的assets列表
    """
    assets = []
    continuation_token = None
    search_url = urljoin(nexus_url, "/service/rest/v1/search/assets")

    # 将groupId转换为路径前缀用于过滤
    path_prefix = group_to_path_prefix(group_id)

    while True:
        params = {
            "repository": repository,
            "group": group_id + "*",  # 使用通配符匹配子group
            "maven.extension": extension,
        }
        if continuation_token:
            params["continuationToken"] = continuation_token

        try:
            response = requests.get(
                search_url,
                params=params,
                auth=auth,
                timeout=30
            )
            response.raise_for_status()
        except requests.RequestException as e:
            print(f"搜索API调用失败: {e}")
            sys.exit(1)

        data = response.json()
        items = data.get("items", [])

        # 过滤确保path以指定group路径开头
        for item in items:
            item_path = item.get("path", "").lstrip("/")
            if item_path.startswith(path_prefix + "/") or item_path.startswith(path_prefix):
                assets.append(item)

        continuation_token = data.get("continuationToken")
        if not continuation_token:
            break

        print(f"  继续获取下一页... (已获取 {len(assets)} 个)")

    return assets


def parse_artifact_info(path):
    """
    从路径中解析 artifact 信息

    路径格式: groupPath/artifactId/version/filename
    例如: com/example/mylib/1.0-SNAPSHOT/mylib-1.0-20230101.123456-1.jar

    Returns:
        (group_path, artifact_id, base_version, filename, timestamp) 或 None
    """
    parts = path.strip("/").split("/")
    if len(parts) < 4:
        return None

    filename = parts[-1]
    version = parts[-2]
    artifact_id = parts[-3]
    group_path = "/".join(parts[:-3])

    # 提取时间戳（用于 snapshot 版本排序）
    # 格式: artifactId-version-YYYYMMDD.HHMMSS-buildNum.ext
    timestamp = None
    timestamp_match = re.search(r'-(\d{8}\.\d{6})-(\d+)\.', filename)
    if timestamp_match:
        timestamp = timestamp_match.group(1) + "-" + timestamp_match.group(2)

    # 获取基础版本（去掉时间戳部分）
    # 例如: 1.0-SNAPSHOT 或 1.0-20230101.123456-1 -> 1.0-SNAPSHOT
    base_version = version
    if "-SNAPSHOT" not in version:
        # 检查是否是带时间戳的 snapshot 版本
        version_match = re.match(r'^(.+)-\d{8}\.\d{6}-\d+$', version)
        if version_match:
            base_version = version_match.group(1) + "-SNAPSHOT"

    return (group_path, artifact_id, base_version, filename, timestamp)


def get_version_key(group_path, artifact_id, base_version):
    """
    获取 artifact 版本的唯一标识
    用于对同一个 artifact 版本的所有文件（jar、pom、sources等）进行分组

    Returns:
        groupPath/artifactId/baseVersion 格式的 key
    """
    return f"{group_path}/{artifact_id}/{base_version}"


def filter_latest_snapshots(assets):
    """
    过滤 snapshot 版本，只保留最新的

    对于同一个 artifact 版本的多个 snapshot 构建，只保留构建号最新的那批文件
    （包括 jar、pom、sources.jar 等）
    """
    # 按 version key 分组，记录每个版本的最新时间戳
    version_latest_timestamp = {}
    non_snapshot = []

    # 第一遍：找出每个版本的最新时间戳
    for asset in assets:
        path = asset.get("path", "").strip("/")
        if not path:
            continue

        # 检查是否是 snapshot 版本（包含 SNAPSHOT 或时间戳格式）
        if "-SNAPSHOT" in path or re.search(r'-\d{8}\.\d{6}-\d+\.', path):
            info = parse_artifact_info(path)
            if info:
                group_path, artifact_id, base_version, filename, timestamp = info
                if timestamp:
                    key = get_version_key(group_path, artifact_id, base_version)
                    if key not in version_latest_timestamp or timestamp > version_latest_timestamp[key]:
                        version_latest_timestamp[key] = timestamp

    # 第二遍：只保留最新时间戳的文件
    latest_snapshots = []
    for asset in assets:
        path = asset.get("path", "").strip("/")
        if not path:
            continue

        if "-SNAPSHOT" in path or re.search(r'-\d{8}\.\d{6}-\d+\.', path):
            info = parse_artifact_info(path)
            if info:
                group_path, artifact_id, base_version, filename, timestamp = info
                key = get_version_key(group_path, artifact_id, base_version)
                # 保留最新时间戳的文件，或没有时间戳的文件（如 maven-metadata.xml）
                if not timestamp or timestamp == version_latest_timestamp.get(key):
                    latest_snapshots.append(asset)
            else:
                non_snapshot.append(asset)
        else:
            non_snapshot.append(asset)

    return non_snapshot + latest_snapshots


def download_file(url, local_path, auth, retries=3):
    """
    下载单个文件

    Args:
        url: 下载URL
        local_path: 本地保存路径
        auth: HTTP认证信息
        retries: 重试次数

    Returns:
        (success, skipped) - success表示下载成功，skipped表示文件不存在被跳过
    """
    # 创建目录
    os.makedirs(os.path.dirname(local_path), exist_ok=True)

    for attempt in range(retries):
        try:
            response = requests.get(url, auth=auth, stream=True, timeout=60)

            # 404表示文件不存在，不需要重试
            if response.status_code == 404:
                print(f"    跳过: 文件不存在 (404)")
                return False, True

            response.raise_for_status()

            with open(local_path, "wb") as f:
                for chunk in response.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)

            return True, False

        except requests.RequestException as e:
            if attempt < retries - 1:
                print(f"    下载失败，重试中 ({attempt + 1}/{retries}): {e}")
            else:
                print(f"    下载失败: {e}")
                return False, False

    return False, False


def main():
    args = parse_args()
    auth = HTTPBasicAuth(args.user, args.password)

    print(f"Nexus仓库: {args.url}")
    print(f"Repository: {args.repository}")
    print(f"GroupId: {args.group}")
    print(f"输出目录: {OUTPUT_DIR}/")
    print()

    # 搜索jar和pom文件
    all_assets = []
    for ext in ["jar", "pom"]:
        print(f"搜索 {ext} 文件...")
        assets = search_assets(args.url, args.group, args.repository, ext, auth)
        print(f"  找到 {len(assets)} 个 {ext} 文件")
        all_assets.extend(assets)

    if not all_assets:
        print("\n未找到任何文件")
        return

    # 过滤 snapshot 版本，只保留最新的
    original_count = len(all_assets)
    all_assets = filter_latest_snapshots(all_assets)
    filtered_count = original_count - len(all_assets)
    if filtered_count > 0:
        print(f"\n已过滤 {filtered_count} 个旧版本 snapshot 文件")

    print(f"\n共 {len(all_assets)} 个文件需要下载...\n")

    # 下载文件
    success_count = 0
    fail_count = 0
    skip_count = 0

    for i, asset in enumerate(all_assets, 1):
        path = asset.get("path", "")
        download_url = asset.get("downloadUrl", "")

        if not path or not download_url:
            print(f"[{i}/{len(all_assets)}] 跳过: 缺少路径或下载URL")
            skip_count += 1
            continue

        # 构建本地路径 (去掉开头的斜杠)
        local_path = os.path.join(OUTPUT_DIR, path.lstrip("/"))

        # 检查文件是否已存在
        if os.path.exists(local_path):
            print(f"[{i}/{len(all_assets)}] 已存在: {path}")
            success_count += 1
            continue

        print(f"[{i}/{len(all_assets)}] 下载: {path}")

        success, skipped = download_file(download_url, local_path, auth)
        if success:
            success_count += 1
        elif skipped:
            skip_count += 1
        else:
            fail_count += 1

    print()
    print(f"下载完成: 成功 {success_count}, 跳过 {skip_count}, 失败 {fail_count}")


if __name__ == "__main__":
    main()
