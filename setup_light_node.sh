#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "请以 root 用户运行此脚本"
  exit 1
fi

WORK_DIR="/root/light-node"
echo "工作目录: $WORK_DIR"

echo "安装基本工具（git, curl, netcat）..."
apt update
apt install -y git curl netcat-openbsd

if [ -d "$WORK_DIR" ]; then
  echo "检测到 $WORK_DIR 已存在，尝试更新..."
  cd $WORK_DIR
  git pull
else
  echo "克隆 Layer Edge Light Node 仓库..."
  git clone https://github.com/Layer-Edge/light-node.git $WORK_DIR
  cd $WORK_DIR
fi
if [ $? -ne 0 ]; then
  echo "克隆或更新仓库失败，请检查网络或权限"
  exit 1
fi

if ! command -v rustc &> /dev/null; then
  echo "安装 Rust..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source $HOME/.cargo/env
fi
rust_version=$(rustc --version)
echo "当前 Rust 版本: $rust_version"

echo "安装 RISC0 工具链管理器 (rzup)..."
curl -L https://risczero.com/install | bash
export PATH=$PATH:/root/.risc0/bin
echo 'export PATH=$PATH:/root/.risc0/bin' >> /root/.bashrc
source /root/.bashrc
if ! command -v rzup &> /dev/null; then
  echo "rzup 安装失败，请检查网络或手动安装"
  exit 1
fi
echo "安装 RISC0 工具链..."
rzup install
rzup_version=$(rzup --version)
echo "当前 rzup 版本: $rzup_version"

echo "正在安装/升级 Go 到 1.23.1..."
wget -q https://go.dev/dl/go1.23.1.linux-amd64.tar.gz -O /tmp/go1.23.1.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go1.23.1.tar.gz
export PATH=/usr/local/go/bin:$PATH
echo 'export PATH=/usr/local/go/bin:$PATH' >> /root/.bashrc
source /root/.bashrc
go_version=$(go version)
echo "当前 Go 版本: $go_version"

if ! command -v go &> /dev/null; then
  echo "Go 安装失败，请检查网络或手动安装"
  exit 1
fi
if [[ "$go_version" != *"go1.23"* ]]; then
  echo "Go 版本未升级到 1.23.1，请检查安装步骤"
  exit 1
fi

echo "请在下方输入你的 PRIVATE_KEY（64位十六进制字符串，输入后按 Enter）："
read -r PRIVATE_KEY
if [ -z "$PRIVATE_KEY" ] || [ ${#PRIVATE_KEY} -ne 64 ]; then
  echo "私钥无效，必须为 64 位十六进制字符串，请重新运行脚本"
  exit 1
fi

echo "请在下方输入你的 GRPC_URL（默认 34.31.74.109:9090，输入后按 Enter，或直接按 Enter 使用默认值）："
read -r GRPC_URL
if [ -z "$GRPC_URL" ]; then
  GRPC_URL="34.31.74.109:9090"
fi

echo "测试 GRPC_URL 可达性: $GRPC_URL..."
GRPC_HOST=$(echo $GRPC_URL | cut -d: -f1)
GRPC_PORT=$(echo $GRPC_URL | cut -d: -f2)
nc -zv $GRPC_HOST $GRPC_PORT
if [ $? -ne 0 ]; then
  echo "警告：无法连接到 $GRPC_URL，请确认地址正确或稍后重试"
fi

echo "设置环境变量..."
cat << EOF > $WORK_DIR/.env
GRPC_URL=$GRPC_URL
CONTRACT_ADDR=cosmos1ufs3tlq4umljk0qfe8k5ya0x6hpavn897u2cnf9k0en9jr7qarqqt56709
ZK_PROVER_URL=http://127.0.0.1:3001
API_REQUEST_TIMEOUT=100
POINTS_API=http://127.0.0.1:8080
PRIVATE_KEY='$PRIVATE_KEY'
EOF
if [ ! -f "$WORK_DIR/.env" ]; then
  echo "创建 .env 文件失败，请检查权限或磁盘空间"
  exit 1
fi
echo "环境变量已写入 $WORK_DIR/.env"
cat $WORK_DIR/.env

echo "构建并启动 risc0-merkle-service..."
cd $WORK_DIR/risc0-merkle-service
cargo build
if [ $? -ne 0 ]; then
  echo "risc0-merkle-service 构建失败，请检查 Rust 和 RISC0 环境"
  exit 1
fi
cargo run > risc0.log 2>&1 &
RISC0_PID=$!
echo "risc0-merkle-service 已启动，PID: $RISC0_PID，日志输出到 risc0.log"

sleep 5
if ! ps -p $RISC0_PID > /dev/null; then
  echo "risc0-merkle-service 启动失败，请检查 $WORK_DIR/risc0-merkle-service/risc0.log"
  cat $WORK_DIR/risc0-merkle-service/risc0.log
  exit 1
fi

echo "构建并启动 light-node..."
cd $WORK_DIR
go mod tidy
go build
if [ $? -ne 0 ]; then
  echo "light-node 构建失败，请检查 Go 环境或依赖"
  exit 1
fi

source $WORK_DIR/.env
./light-node > light-node.log 2>&1 &
LIGHT_NODE_PID=$!
echo "light-node 已启动，PID: $LIGHT_NODE_PID，日志输出到 light-node.log"

sleep 5
if ! ps -p $LIGHT_NODE_PID > /dev/null; then
  echo "light-node 启动失败，请检查 $WORK_DIR/light-node.log"
  cat $WORK_DIR/light-node.log
  exit 1
fi

echo "所有服务已启动！"
echo "检查日志："
echo "- risc0-merkle-service: $WORK_DIR/risc0-merkle-service/risc0.log"
echo "- light-node: $WORK_DIR/light-node.log"
