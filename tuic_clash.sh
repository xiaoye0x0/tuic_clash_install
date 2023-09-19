#!/usr/bin/env bash

export LANG=en_US.UTF-8
echoType='echo -e'

installPath="/opt/test/tuic_clash"
corePath=${installPath}/clash_core


echoContent() {
  case $1 in
  # 红色
  "red")
    # shellcheck disable=SC2154
    ${echoType} "\033[31m${printN}$2 \033[0m"
    ;;
    # 天蓝色
  "skyBlue")
    ${echoType} "\033[1;36m${printN}$2 \033[0m"
    ;;
    # 绿色
  "green")
    ${echoType} "\033[32m${printN}$2 \033[0m"
    ;;
    # 白色
  "white")
    ${echoType} "\033[37m${printN}$2 \033[0m"
    ;;
  "magenta")
    ${echoType} "\033[31m${printN}$2 \033[0m"
    ;;
    # 黄色
  "yellow")
    ${echoType} "\033[33m${printN}$2 \033[0m"
    ;;
  esac
}

installPrecheck(){
  if [[ $(id -u) != 0 ]]; then
    red "请使用root用户运行此脚本"
    exit 1
  fi
  if [ -f "/usr/bin/apt-get" ]; then
    apt-get update -y
    apt-get install -y curl socat jq
    mkdir $installPath
  else
    yum update -y
    yum install -y epel-release
    yum install -y curl socat jq
    mkdir $installPath
  fi
}

getArch() {
    archCmd=$(uname -m)
    if [[ "$archCmd" == "arm"* ]]; then
        echo "设备架构为 ARM"
        arch=linux-arm64-alpha
    elif [[ "$archCmd" == "x86_64" ]]; then
        echo "设备架构为 AMD64"
        arch=linux-amd64-alpha
    else
        echo "无法确定设备架构"
        exit 1
    fi
}

getIpV4orV6(){
  serverIP=$(curl -s -$1 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
  if [[ -z "${serverIP}" ]]; then
      echoContent red "获取外网IPv$1失败"
      exit 1
  fi
  echoContent green "当前外网 IPv$1 为: $serverIP"
}

tuicPort(){
  read -p "设置 tuic 端口[1-65535]（回车则随机分配端口）：" port
  [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
  until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; do
    if [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; then
      echo -e "${RED} $port ${PLAIN} 端口已经被其他程序占用，请更换端口重试！"
      read -p "设置 tuic 端口[1-65535]（回车则随机分配端口）：" port
      [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    fi
  done
  echoContent green "将在 tuic 节点使用的端口是：$port"
}

installAcme(){
  curl https://get.acme.sh | sh
}

initAcme(){
  read -p "请输入绑定服务器IP的域名: " domain
  if [ -z "$domain" ]; then
    echoContent red "域名不能为空"
    exit 1
  fi
  read -e -i "n" -p "是否使用已有证书 [Y/n]: " input
  if [ "$input" = "y" ] || [ "$input" = "Y" ]
  then
    read -p "完整证书链（包含公钥和中间证书）的文件路径: " fkeyPath
    read -p "私钥的文件路径: " pkeyPath
    echoContent green "证书路径为: \n$fkeyPath \n$pkeyPath"
  elif [ "$input" = "n" ] || [ "$input" = "N" ]
  then
    echoContent yellow "开始申请证书"
    mkdir -p $acmeSavePath
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d $domain --standalone --keylength ec-256
    ~/.acme.sh/acme.sh --install-cert -d $domain --ecc --fullchain-file $fkeyPath --key-file $pkeyPath
    echoContent green "申请成功"
  else
    echoContent red "无效的输入"
    exit 1
  fi
}

installTuic(){
  getArch
  echoContent yellow "将下载${arch}版本的Clash Meta Core"
  result=$(curl -s https://api.github.com/repos/MetaCubeX/Clash.Meta/releases | jq -r --arg custom_str $arch '.[0].assets[] | select(.browser_download_url | contains($custom_str)) | { url: .browser_download_url, name: .name }')
  pre_release_name=$(echo "$result" | jq -r '.name')
  pre_release_url=$(echo "$result" | jq -r '.url')
  echoContent yellow "正在下载最新Pre-Release版Clash-Meta $pre_release_name"
  wget -q ${pre_release_url} -O ${installPath}/${pre_release_name} 
  gunzip -c ${installPath}/${pre_release_name} > $corePath && rm -rf ${installPath}/${pre_release_name}
  if [[ $? -eq 0 ]]; then
    chmod +x ${corePath}
    echoContent green "下载完成"
  else
    echoContent red "下载失败,检查和Github的连接状态"
    exit 1
  fi
}

initInstallConf(){
  acmeSavePath=${installPath}/${port}/ssl
  fkeyPath=${acmeSavePath}/fullchain.cer
  pkeyPath=${acmeSavePath}/private.key
  serverConfPath=${installPath}/${port}/server.yaml
  clientConfPath=${installPath}/${port}/client.yaml
}

initTuicServerConf(){
  read -p "设置 tuic v5 UUID (回车跳过为随机 UUID): " uuid
  [[ -z $uuid ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
  read -p "设置 tuic 密码（回车跳过为随机字符）：" passwd
  [[ -z $passwd ]] && passwd=$(date +%s%N | md5sum | cut -c 1-8)
  cat >$serverConfPath<<EOF
ipv6: true
tuic-server:
  enable: true 
  listen: :$port
  users:
    $uuid: $passwd
  certificate: $fkeyPath
  private-key: $pkeyPath
  congestion-controller: bbr
  max-idle-time: 8000
  authentication-timeout: 1000
  alpn: [h3]
EOF

  cat >$clientConfPath<<EOF
- name: Tuic
  server: $domain
  port: $port
  type: tuic
  uuid: $uuid
  password: $passwd
  ip: $serverIP
  alpn: [h3]
  request-timeout: 8000
  udp-relay-mode: quic
  congestion-controller: bbr
  fast-open: true
  skip-cert-verify: false
  max-open-streams: 10
EOF

  cat >/etc/systemd/system/tuic_clash_$port.service<<EOF
[Unit]
After=network.target

[Service]
Type=simple
Restart=always
ExecStart=$corePath -f $serverConfPath
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable --now tuic_clash_$port && sleep 0.2
  if [[ -n $(systemctl status tuic_clash_$port 2>/dev/null | grep -w active) && -f $serverConfPath ]]; then
    echoContent green "Tuic(Clash内核) 安装成功！"
    echoContent skyBlue "在Clash Meta 中的配置如下"
    cat $clientConfPath
  else
    echoContent red "Tuic 安装失败！请运行systemctl status tuic_clash_${port}查看错误信息！"
    exit 1
  fi
}

show_config(){
  echoContent skyBlue "当前已管理的配置:"
  find $installPath -type d -name '[0-9]*'
  read -p "选择要查看的配置(输入最后的端口号即可):" conf
  if [ -e ${installPath}/${conf} ]; then
    cat ${installPath}/${conf}/client.yaml
  else
    echo "指定配置不存在"
    exit 1
  fi
}

uninstall_tuic(){
  echoContent skyBlue "当前已管理的配置:"
  find $installPath -type d -name '[0-9]*'
  read -p "选择要删除的配置(输入最后的端口号即可):" conf
  if [ -e ${installPath}/${conf} ]; then
    systemctl stop tuic_clash_${conf} && systemctl disable tuic_clash_${conf}
    rm -rf ${installPath}/${conf} /etc/systemd/system/tuic_clash_${conf}.service
    echoContent green "已经删除端口为${conf}的配置"
  else
    echo "指定配置不存在"
    exit 1
  fi
}

main(){
  clear
  echo "###############################################################"
  echo -e "#           \033[32m 咲夜的Tuic V5(Clash内核)一键安装脚本 \033[0m            #"
  echo "#                                                             #"
  echo "#                                                             #"
  echo -e "#  \033[32m 请注意: 此服务端为Clash Meta核心提供,不兼容Tuic原版核心! \033[0m #"
  echo "###############################################################"
  echo ""
  echo " 1. 安装 Tuic(Clash内核)"
  echo " 2. 更新 Tuic(Clash内核)"
  echo " 3. 查看 Tuic(Clash内核) 配置"
  echo " 4. 卸载 Tuic(Clash内核)"
  echo " 0. 退出脚本"
  echo
  read -p "请输入数字:" num
  case "$num" in
  1)
  installPrecheck
  valid=false
  while [ "$valid" = false ]
  do
    read -p "使用IPv4 or IPv6 [4/6]:" ipv
    if [ "$ipv" = "4" ] || [ "$ipv" = "6" ]
    then
      valid=true
    else
      echoContent red "无效的输入，请重新输入。"
    fi
  done
  getIpV4orV6 $ipv
  tuicPort
  initInstallConf
  echoContent yellow "开始下载必要软件"
  installAcme
  installTuic
  initAcme
  initTuicServerConf
  ;;
  2)
  installTuic
  ;;
  3)
  show_config
  ;;
  4)
  uninstall_tuic
  ;;
  0)
  exit 1
  ;;
  *)
  echoContent red "请输入正确数字"
  sleep 2s
  main
  ;;
  esac
}

main
