#!/bin/bash

while getopts ":a:b:" opt
do
    case $opt in
        a)
        echo "value ns is $OPTARG"; a=$OPTARG
        ;;
        b)
        echo "value number is $OPTARG"; b=$OPTARG
        ;;
    esac
done

# echo "value ns is $a"
# echo "value number is $b"

number=$b
ns=$a
server=10.117.233.2

export PATH=./00-kubectl-vsphere-plugin/bin:$PATH
export KUBECTL_VSPHERE_PASSWORD="Admin!23"

kubectl vsphere login --server=$server --vsphere-username administrator@vsphere.local --insecure-skip-tls-verify
kubectl config use-context $ns

# create tkg cluster
cat << EOF | kubectl apply -f -
apiVersion: run.tanzu.vmware.com/v1alpha2
kind: TanzuKubernetesCluster                   
metadata:
  name: tkgs-ubucluster-$number                   
  namespace: zyajing                   
spec:
  distribution:
    fullVersion: v1.20.8---vmware.1-tkg.2
  topology:
    controlPlane:
      replicas: 1                                 
      vmClass: guaranteed-xlarge                 
      storageClass: pacific-storage-policy
      volumes:
        - name: etcd
          mountPath: /var/lib/etcd
          capacity:
            storage: 20Gi
    nodePools:
    - name: workers
      replicas: 3
      vmClass: guaranteed-xlarge
      storageClass: pacific-storage-policy
      volumes:
        - name: containerd
          mountPath: /var/lib/containerd
          capacity:
            storage: 100Gi
  settings:
    storage:
      defaultClass: pacific-storage-policy
    network:
      proxy:
        httpProxy: http://proxy.liuqi.io:3128  #Proxy URL for HTTP connections
        httpsProxy: http://proxy.liuqi.io:3128 #Proxy URL for HTTPS connections
        noProxy: [10.244.0.0/20,10.117.233.0/26,10.117.233.64/26,192.168.0.0/16,10.0.0.0/8,127.0.0.1,localhost,.svc,.svc.cluster.local] #SVC Pod, Egress, Ingress CIDRs   
EOF

while true; do
  kubectl get tanzukubernetesclusters|grep tkgs-ubucluster-$number|grep "True    True" 
  if [[ $? == 0 ]]; then
    break
  fi
  sleep 10
  echo "Wait tkg cluster provision finish..."
done

# get ssh password
kubectl config use-context $ns
ssh_password=`kubectl get secrets tkgs-ubucluster-$number-ssh-password -o jsonpath='{.data.ssh-passwordkey}' | base64 -d`
echo $ssh_password

control_vm_ip=`kubectl describe virtualmachines tkgs-ubucluster-$number-control-plane|grep "Vm Ip"|cut -d: -f2 -|sed 's/^[ \t]*//g' -`
echo "Control Plane Node IP is "$control_vm_ip
nodes_ip=`kubectl describe virtualmachines tkgs-ubucluster-$number-workers|grep "Vm Ip"|cut -d: -f2 -|sed 's/^[ \t]*//g' -`

# patch api-server (control node)
kubectl exec jumpbox -- bash -c "\
{
ssh_password=$ssh_password
for node in ${control_vm_ip}; do
  "'#use inner variable substitution
    sshpass -p $ssh_password ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HashKnownHosts=no vmware-system-user@$node \
    '\''apiServerFile=/etc/kubernetes/manifests/kube-apiserver.yaml; \
    sudo sed -i "s,- --tls-private-key-file=/etc/kubernetes/pki/apiserver.key,- --tls-private-key-file=/etc/kubernetes/pki/apiserver.key\n\    - --service-account-issuer=kubernetes.default.svc\n\    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key," $apiServerFile '\''
  '"
done;
}"

echo "Control Plane Node is patched"

exit
