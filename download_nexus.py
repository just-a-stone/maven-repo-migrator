#!/usr/bin/env python3
"""
Nexus Maven Repository Jar Download Script

从Nexus仓库下载指定groupId的所有jar和pom文件
"""

import argparse
import os
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

    print(f"\n共找到 {len(all_assets)} 个文件，开始下载...\n")

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
