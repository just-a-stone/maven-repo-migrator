#!/bin/bash

# 简单测试脚本
cd /Users/shield/workspace/test/maven

echo "测试1: 查看帮助信息"
./maven-deploy.sh --help | head -10

echo ""
echo "测试2: 缺少参数时的错误提示"
./maven-deploy.sh -d ./test-repo 2>&1 | grep "错误"

echo ""
echo "测试3: 验证文件查找"
find ./test-repo -type f \( -name "*.jar" -o -name "*.pom" \) | wc -l

echo ""
echo "测试4: 运行test模式（完整输出保存到test-output.txt）"
./maven-deploy.sh \
  -d ./test-repo \
  --release-url http://nexus.example.com/repository/releases \
  --release-id release-repo \
  --snapshot-url http://nexus.example.com/repository/snapshots \
  --snapshot-id snapshot-repo \
  -m test > test-output.txt 2>&1

EXIT_CODE=$?
echo "脚本退出码: $EXIT_CODE"

echo ""
echo "测试5: 查看输出文件的关键信息"
echo "--- 配置信息 ---"
grep -A 8 "Maven仓库推送脚本" test-output.txt | tail -7

echo ""
echo "--- Release版本命令 ---"
grep "\[RELEASE\]" test-output.txt | head -2

echo ""
echo "--- Snapshot版本命令 ---"
grep "\[SNAPSHOT\]" test-output.txt | head -2

echo ""
echo "--- 统计信息 ---"
grep -A 10 "推送统计" test-output.txt | tail -8

echo ""
echo "测试完成!"
