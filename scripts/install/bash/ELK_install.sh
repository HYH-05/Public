#!/bin/bash


set -e

error_handler() {
  echo "오류 발생! 마지막 명령이 실패했습니다."
  echo "실패한 명령: $BASH_COMMAND"
  exit 1
}

trap error_handler ERR

sed -i "1i $(hostname -I | awk '{print $1}') ELK" /etc/hosts

echo "#############시스템 업데이트 중 및 필수 패키지 설치 중..."
apt update -y && apt install -y apt-transport-https gnupg curl wget expect tcl rpm zip


echo "#############Elasticsearch 설치 중..."
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo tee /usr/share/keyrings/elasticsearch.asc
echo "deb [signed-by=/usr/share/keyrings/elasticsearch.asc] https://artifacts.elastic.co/packages/8.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-8.x.list
apt update && apt install -y elasticsearch

echo "##############인증서 패스워드 생성"
#CA_PASSWORD=$(openssl rand -base64 24)
CA_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
expect <<EOF
spawn /usr/share/elasticsearch/bin/elasticsearch-certutil ca --out /usr/share/elasticsearch/elastic-stack-ca.p12
expect -re "Enter password for elastic-stack-ca.p12"
send "${CA_PASSWORD}\r"
expect eof
EOF

cat > /usr/share/elasticsearch/instances.yml <<EOL
instances:
  - name: 'ES'
    dns: [ 'ELK' ]
  - name: 'Kibana'
    dns: [ 'ELK' ]
  - name: 'Logstash'
    dns: [ 'ELK' ]
EOL

echo "###############node 인증서 생성 중..."
NODE_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
expect  <<EOF
spawn /usr/share/elasticsearch/bin/elasticsearch-certutil cert --silent --in /usr/share/elasticsearch/instances.yml --out /usr/share/elasticsearch/certs.zip --ca /usr/share/elasticsearch/elastic-stack-ca.p12
expect -re "Enter password for"
send "${CA_PASSWORD}\r"
expect -re "Enter password for ES/ES.p12"
send "${NODE_PASSWORD}\r"
expect -re "Enter password for Kibana/Kibana.p12"
send "${NODE_PASSWORD}\r"
expect -re "Enter password for Logstash/Logstash.p12"
send "${NODE_PASSWORD}\r"
expect eof
EOF

echo "#######################인증서 랜덤 패스워드 저장 중... >> /usr/share/elasticsearch/PASSWORD.txt"
sleep 5
cat > /usr/share/elasticsearch/PASSWORD.txt <<EOL
CA 인증서 패스워드
$CA_PASSWORD

NODE(ES, KIBANA, LOGSTASH) 인증서 패스워드
$NODE_PASSWORD
EOL


echo "#############node 인증서 확인 - 5초 대기"
unzip /usr/share/elasticsearch/certs.zip -d /usr/share/elasticsearch/
sleep 5

echo "############node 인증서 키 저장소에 암호 추가"
expect <<EOF
spawn /usr/share/elasticsearch/bin/elasticsearch-keystore add xpack.security.transport.ssl.keystore.secure_password
expect -re "Setting xpack.security.transport.ssl.keystore.secure_password already exists. Overwrite? \[y/N\]"
send "y\r"
expect -re "Enter value for xpack.security.transport.ssl.keystore.secure_password:"
send "${NODE_PASSWORD}\r"
expect eof
EOF

expect <<EOF
spawn /usr/share/elasticsearch/bin/elasticsearch-keystore add xpack.security.transport.ssl.truststore.secure_password
expect -re "Setting xpack.security.transport.ssl.truststore.secure_password already exists. Overwrite? \[y/N\]"
send "y\r"
expect -re "Enter value for xpack.security.transport.ssl.truststore.secure_password:"
send "${NODE_PASSWORD}\r"
expect eof
EOF

echo "#######################NODE 인증서 키 저장소 암호 저장 중... >> /usr/share/elasticsearch/PASSWORD.txt"
cat >> /usr/share/elasticsearch/PASSWORD.txt <<EOL

NODE 인증서 키 저장소 암호
$NODE_PASSWORD
아래 명령어로 확인 가능
/usr/share/elasticsearch/bin/elasticsearch-keystore show xpack.security.transport.ssl.keystore.secure_password
/usr/share/elasticsearch/bin/elasticsearch-keystore show xpack.security.transport.ssl.truststore.secure_password
EOL


echo "#############node 인증서 키 저장소 확인 - 5초 대기"
/usr/share/elasticsearch/bin/elasticsearch-keystore list
sleep 5


HTTP_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
MY_IP=$(hostname -I | awk '{print $1}')
echo "#############http 인증서 생성 중..."
#/usr/share/elasticsearch/bin/elasticsearch-certutil http
expect <<EOF
spawn /usr/share/elasticsearch/bin/elasticsearch-certutil http
expect -re "Generate a CSR"
send "n\r"
expect -re "Use an existing CA"
send "y\r"
expect -re "CA Path"
send "/usr/share/elasticsearch/elastic-stack-ca.p12\r"
expect -re "Password for elastic-stack-ca.p12"
send "${CA_PASSWORD}\r"
expect -re "For how long should your certificate be valid?"
send "5y\r"
expect -re "Generate a certificate per node"
send "n\r"
expect -re "When you are done, press <ENTER> once more to move on to the next step"
send "ELK\r\r"
expect -re "Is this correct"
send "y\r"
expect -re "When you are done, press <ENTER> once more to move on to the next step"
send "${MY_IP}\r\r"
expect -re "Is this correct"
send "y\r"
expect -re "Do you wish to change any of these options"
send "n\r"
expect -re "Provide a password for the"
send "${HTTP_PASSWORD}\r"
expect -re "Repeat password to confirm"
send "${HTTP_PASSWORD}\r"
expect -re "What filename should be used for the output zip file"
send "\r"
expect eof
EOF




echo "############http 인증서 확인 - 5초 대기"
unzip /usr/share/elasticsearch/elasticsearch-ssl-http.zip -d /usr/share/elasticsearch/
sleep 5



echo "############http 인증서 키 저장소에 암호 추가"
expect <<EOF
spawn /usr/share/elasticsearch/bin/elasticsearch-keystore add xpack.security.http.ssl.keystore.secure_password
expect -re "Setting xpack.security.http.ssl.keystore.secure_password already exists. Overwrite? \[y/N\]"
send "y\r"
expect -re "Enter value for xpack.security.http.ssl.keystore.secure_password:"
send "${HTTP_PASSWORD}\r"
expect eof
EOF

expect <<EOF
spawn /usr/share/elasticsearch/bin/elasticsearch-keystore add xpack.security.http.ssl.truststore.secure_password
expect -re "Enter value for xpack.security.http.ssl.truststore.secure_password:"
send "${HTTP_PASSWORD}\r"
expect eof
EOF

echo "#######################HTTP 인증서 키 저장소 암호 저장 중... >> /usr/share/elasticsearch/PASSWORD.txt"
cat >> /usr/share/elasticsearch/PASSWORD.txt <<EOL

HTTP 인증서 키 저장소 암호
$HTTP_PASSWORD
아래 명령어로 확인 가능
/usr/share/elasticsearch/bin/elasticsearch-keystore show xpack.security.http.ssl.keystore.secure_password
/usr/share/elasticsearch/bin/elasticsearch-keystore show xpack.security.http.ssl.truststore.secure_password
EOL


echo "################http 인증서 키 저장소 확인 - 5초 대기"
/usr/share/elasticsearch/bin/elasticsearch-keystore list
sleep 5

echo "#################기존인증서 삭제"
rm -rf /etc/elasticsearch/certs/*

echo "#################ca 인증서 이동"
cp -arf /usr/share/elasticsearch/elastic-stack-ca.p12 /etc/elasticsearch/certs/
echo "##################node 인증서 이동"
cp -arf /usr/share/elasticsearch/ES/ES.p12 /etc/elasticsearch/certs/
echo "#####################http 인증서 이동"
cp -arf /usr/share/elasticsearch/elasticsearch/http.p12 /etc/elasticsearch/certs/

chown -R root:elasticsearch /etc/elasticsearch/certs
chmod 660 /etc/elasticsearch/certs/*

echo "###############ES configuration 설정 중..."
cat > /etc/elasticsearch/elasticsearch.yml <<EOL
cluster.name: es-cluster
node.name: ES
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

#bootstrap.memory_lock: true
#bootstrap.memory_lock : [true|false] # ES가 사용하는 heap 영역을 간섭받지 않도록 미리 점유하는 설정.
#사용방법 메뉴얼 참고

network.host: "0.0.0.0" # 모두 접근 허용
http.port: 9200
discovery.seed_hosts: ["ELK"]
cluster.initial_master_nodes: ["ES"]

xpack.security.enabled: true
xpack.security.enrollment.enabled: true
xpack.security.http.ssl:
  enabled: true
  verification_mode: certificate
  keystore.path: certs/http.p12
  truststore.path: certs/http.p12
xpack.security.transport.ssl:
  enabled: true
  verification_mode: certificate
  keystore.path: certs/ES.p12
  truststore.path: certs/ES.p12

#xpack.monitoring.collection.enabled: true
EOL

echo "##################ES 서비스를 시작"
systemctl daemon-reload
systemctl enable elasticsearch
systemctl start elasticsearch




echo "###############Kibana 설치"
apt install -y kibana

echo "################xpack.security 인증서 설정(CA, http, node)"
echo "################ES 설치할 때 생성했던 것"
sleep 3
mkdir /etc/kibana/certs
cp -arf /usr/share/elasticsearch/elastic-stack-ca.p12 /etc/kibana/certs/
cp -arf /usr/share/elasticsearch/ES/ES.p12 /etc/kibana/certs/
cp -arf /usr/share/elasticsearch/elasticsearch/http.p12 /etc/kibana/certs/


echo "#################kibana_system 사용자 패스워드 재설정 및 저장 중..."
sleep 3
echo -e "\nkibana_system 패스워드" >> /usr/share/elasticsearch/PASSWORD.txt
yes y | /usr/share/elasticsearch/bin/elasticsearch-reset-password -u kibana_system | grep -i "New value:" | sed 's/.*New value: \(.*\)/\1/' >> /usr/share/elasticsearch/PASSWORD.txt
KIBANA_SYSTEM_PASSWORD=$(grep -A1 'kibana_system 패스워드' /usr/share/elasticsearch/PASSWORD.txt | tail -n1)


echo "#######################kibana 설정 중..."
chown -R root:kibana /etc/kibana/certs
chmod 660 /etc/kibana/certs/*
cat > /etc/kibana/kibana.yml <<EOL
pid.file: /run/kibana/kibana.pid

server.port: 5601
server.host: "0.0.0.0"
server.name: "ES"

server.ssl.enabled: true
server.ssl.keystore.path: /etc/kibana/certs/ES.p12
server.ssl.keystore.password: $NODE_PASSWORD
server.ssl.truststore.path: /etc/kibana/certs/ES.p12
server.ssl.truststore.password: $NODE_PASSWORD

elasticsearch.hosts: ["https://ELK:9200"]

elasticsearch.username: "kibana_system"
elasticsearch.password: "$KIBANA_SYSTEM_PASSWORD"

#elasticsearch.ssl.verificationMode: none

elasticsearch.ssl.certificateAuthorities: [ "/etc/kibana/certs/elastic-stack-ca.p12" ]

elasticsearch.ssl.keystore.path: /etc/kibana/certs/http.p12
elasticsearch.ssl.keystore.password: $HTTP_PASSWORD
elasticsearch.ssl.truststore.path: /etc/kibana/certs/http.p12
elasticsearch.ssl.truststore.password: $HTTP_PASSWORD
elasticsearch.ssl.verificationMode: certificate


logging:
  appenders:
    file:
      type: file
      fileName: /var/log/kibana/kibana.log
      layout:
        type: json
  root:
    appenders:
      - default
      - file

# Kibana Stack Monitoring 활성화
#xpack.monitoring.enabled: true
EOL

echo "###############kibana 시작"
systemctl daemon-reload
systemctl enable kibana
systemctl start kibana




echo "####################logstash 설치"
apt install -y logstash

echo "####################logstash 인증서 설정"
mkdir /etc/logstash/certs
cp -arf /usr/share/elasticsearch/elastic-stack-ca.p12 /etc/logstash/certs/
cp -arf /usr/share/elasticsearch/Logstash/Logstash.p12 /etc/logstash/certs/
cp -arf /usr/share/elasticsearch/elasticsearch/http.p12 /etc/logstash/certs/

chown -R root:logstash /etc/logstash/certs
chmod 660 /etc/logstash/certs/*

echo "#################logstash_system 사용자 패스워드 재설정 및 저장 중..."
sleep 3
echo -e "\nlogstash_system 패스워드" >> /usr/share/elasticsearch/PASSWORD.txt
yes y | /usr/share/elasticsearch/bin/elasticsearch-reset-password -u logstash_system | grep -i "New value:" | sed 's/.*New value: \(.*\)/\1/' >> /usr/share/elasticsearch/PASSWORD.txt
LOGSTASH_SYSTEM_PASSWORD=$(grep -A1 'logstash_system 패스워드' /usr/share/elasticsearch/PASSWORD.txt | tail -n1)


echo -e "\n#################elastic(super user) 사용자 패스워드 재설정 및 저장 중..."
sleep 3
echo -e "\nelastic 패스워드" >> /usr/share/elasticsearch/PASSWORD.txt
yes y | /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic | grep -i "New value:" | sed 's/.*New value: \(.*\)/\1/' >> /usr/share/elasticsearch/PASSWORD.txt
ELASTIC_PASSWORD=$(grep -A1 'elastic 패스워드' /usr/share/elasticsearch/PASSWORD.txt | tail -n1)

echo -e "\n"
curl -u elastic:$ELASTIC_PASSWORD  -k -X POST "https://$MY_IP:9200/_security/role/logstash_write_role" -H 'Content-Type: application/json' -d' { "cluster": ["manage_index_templates", "monitor"], "indices": [ { "names": [ "default" ], "privileges": ["write", "create", "create_index", "manage", "manage_ilm"] } ] } '


echo -e "\n#########################Logstash 사용자 패스워드 재설정 및 저장 중..."
LOGSTASH_WRITER_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
curl -u elastic:$ELASTIC_PASSWORD -k -X POST "https://$MY_IP:9200/_security/user/logstash_writer" -H 'Content-Type: application/json' -d' { "password" : "$LOGSTASH_WRITE_PASSWORD", "roles" : [ "logstash_write_role" ] } '

cat >> /usr/share/elasticsearch/PASSWORD.txt <<EOL

logstash_write 계정 패스워드
$LOGSTASH_WRITER_PASSWORD
EOL




echo -e "\n#########################Logstash.yml 설정 중..."
sleep 3
cat > /etc/logstash/logstash.yml <<EOL
node.name: ES
path.data: /var/lib/logstash

path.logs: /var/log/logstash


xpack.monitoring.enabled: true
xpack.monitoring.elasticsearch.username: logstash_system
xpack.monitoring.elasticsearch.password: $LOGSTASH_SYSTEM_PASSWORD
xpack.monitoring.elasticsearch.hosts: ["https://ELK:9200"]

# CA 인증서 경로
xpack.monitoring.elasticsearch.ssl.certificate_authority: "/etc/logstash/certs/elastic-stack-ca.p12"

# 인증 모드, node 일 경우 SSL 검증을 사용하지 않는다.
xpack.monitoring.elasticsearch.ssl.verification_mode: certificate

# keystore, truststore 인증서 경로
xpack.monitoring.elasticsearch.ssl.truststore.path: /etc/logstash/certs/Logstash.p12
xpack.monitoring.elasticsearch.ssl.truststore.password: $NODE_PASSWORD
xpack.monitoring.elasticsearch.ssl.keystore.path: /etc/logstash/certs/Logstash.p12
xpack.monitoring.elasticsearch.ssl.keystore.password: $NODE_PASSWORD
EOL



echo "########################파이프라인(default) 설정 중.."
cat > /etc/logstash/conf.d/default.conf <<EOL
input {
  beats {
    port => 5044
                host => "0.0.0.0"
  }
}

filter {
  json {
    source => "message"
  }
}

output {
  elasticsearch {
    hosts => ["https://ELK:9200"]
    ssl_enabled => true
    ssl_keystore_path => "/etc/logstash/certs/http.p12"
    ssl_keystore_password => $HTTP_PASSWORD
    ssl_truststore_path => "/etc/logstash/certs/http.p12"
    ssl_truststore_password => $HTTP_PASSWORD
    user => "logstash_writer"
    password => $LOGSTASH_WRITER_PASSWORD
    index => "default"
  }
}
EOL

echo "###################logstash는 conf 수정 후 수동 시작 바랍니다.#############################"
systemctl daemon-reload
#systemctl enable logstash
#systemctl start logstash

echo "#################모든 작업이 마무리 되었습니다.#################"
echo "###/usr/share/elasticsearch/PASSWORD.txt에 패스워드 있습니다.###"
echo "##################메뉴얼 문서를 참고해 주세요###################"
echo "################################################################"
