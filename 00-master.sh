#!/usr/bin/bash
set -o nounset -o errexit

env
kubeadm init --ignore-preflight-errors=NumCPU --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=${MASTER_PRIVATE_IP} --apiserver-cert-extra-sans="${MASTER_PUBLIC_IP}"
echo "net.bridge-nf-call-iptables = 1" > /etc/sysctl.d/60-flannel.conf
kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f https://raw.githubusercontent.com/coreos/flannel/a70459be0084506e4ec919aa1c114638878db11b/Documentation/kube-flannel.yml
systemctl enable docker kubelet

# used to join nodes to the cluster
kubeadm token create --print-join-command > /tmp/kubeadm_join

# used to setup kubectl 
chown core /etc/kubernetes/admin.conf
cp /etc/kubernetes/admin.conf ~/.kube/config
