#!/usr/bin/env bats

function setup {
  #create a self-signed cert 
  cert_dir=$(mktemp -d /tmp/certs.XXXXXX)
  docker run -v "$cert_dir":/certs amouat/create-test-cert > /dev/null 2>/dev/null

  #start a registry on localhost
  docker stop test-docker-reg &> /dev/null || true
  docker rm test-docker-reg &> /dev/null || true
  docker run -v $cert_dir:/certs -p 5000 --name test-docker-reg \
             -e REGISTRY_HTTP_ADDR=:5000 \
             -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/ca.crt \
             -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
             -d registry:2 > /dev/null

  local running_address=$(docker port test-docker-reg 5000)
  local mapped_port=${running_address##*:}
  full_reg_name=test-docker-reg:"$mapped_port"

}

function teardown {

  docker stop test-docker-reg &> /dev/null || true
  docker rm test-docker-reg &> /dev/null || true
  if [[ -n $cert_dir ]]; then
    rm -rf "$cert_dir"
  fi

}

function restart_docker_mac {

  if [[ "$(uname -s)" = "Darwin" ]]; then
    killall com.docker.osx.hyperkit.linux
    sleep 2
    run docker pull alpine:latest > /dev/null
    while [[ "$status" != 0 ]]
    do
      sleep 1
      run docker pull alpine:latest &> /dev/null
    done
    docker start test-docker-reg
    local running_address=$(docker port test-docker-reg 5000)
    local mapped_port=${running_address##*:}
    full_reg_name=test-docker-reg:"$mapped_port"
  fi
}

@test "install via file" {
  
  sudo ../reg-tool.sh install-cert --cert-file "$cert_dir"/ca.crt \
             --reg-name "$full_reg_name" \
             --add-host 0.0.0.0 test-docker-reg > /dev/null

  restart_docker_mac
  docker pull alpine:latest > /dev/null
  docker tag alpine:latest "$full_reg_name"/test-image > /dev/null
  docker push "$full_reg_name"/test-image > /dev/null

}

@test "install via URL" {

  # serve cert via nginx
  docker stop test-cert-server &> /dev/null || true
  docker rm test-cert-server &> /dev/null || true
  docker run -p 80 --name test-cert-server \
         -v "$cert_dir"/ca.crt:/usr/share/nginx/html/ca.crt -d nginx

  sudo ../reg-tool.sh install-cert \
             --cert-file http://$(docker port test-cert-server 80)/ca.crt \
             --reg-name "$full_reg_name" \
             --add-host 0.0.0.0 test-docker-reg > /dev/null
  restart_docker_mac

  docker stop test-cert-server > /dev/null
  docker rm test-cert-server > /dev/null
  docker pull alpine:latest > /dev/null
  docker tag alpine:latest "$full_reg_name"/test-image > /dev/null
  docker push "$full_reg_name"/test-image > /dev/null
}

@test "install via secret" {

  minikube start > /dev/null || true
  run kubectl cluster-info > /dev/null
  while [[ "$status" != 0 ]]
  do
    sleep 1
    run kubectl cluster-info > /dev/null
  done
  kubectl delete secret test-registry-cert &> /dev/null || true 
  kubectl create secret generic test-registry-cert --from-file="$cert_dir"/ca.crt
  sudo ../reg-tool.sh install-cert \
             --k8s-secret test-registry-cert \
             --reg-name "$full_reg_name" \
             --add-host 0.0.0.0 test-docker-reg > /dev/null
  restart_docker_mac

  docker pull alpine:latest > /dev/null
  docker tag alpine:latest "$full_reg_name"/test-image > /dev/null
  docker push "$full_reg_name"/test-image > /dev/null
}
