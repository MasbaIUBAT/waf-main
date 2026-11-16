# WAF on EKS: Complete Deployment Guide

A step-by-step guide to deploy an **Apache + ModSecurity WAF** on Amazon EKS, from provisioning the cluster to running a production-grade Kubernetes deployment with auto-scaling, health checks, and a load balancer.

The WAF acts as a reverse proxy in front of a client's backend server (hosted anywhere — their own EC2, VPS, Kubernetes, or data center).

---

## Table of Contents

- [1. Architecture](#1-architecture)
- [2. Prerequisites](#2-prerequisites)
- [3. Phase 1: Prepare the Bastion EC2](#3-phase-1-prepare-the-bastion-ec2)
- [4. Phase 2: IAM User and AWS CLI Setup](#4-phase-2-iam-user-and-aws-cli-setup)
- [5. Phase 3: Install CLI Tools (eksctl, kubectl, helm)](#5-phase-3-install-cli-tools-eksctl-kubectl-helm)
- [6. Phase 4: Create the EKS Cluster](#6-phase-4-create-the-eks-cluster)
- [7. Phase 5: Build the WAF Docker Image](#7-phase-5-build-the-waf-docker-image)
- [8. Phase 6: Deploy to Kubernetes](#8-phase-6-deploy-to-kubernetes)
- [9. Phase 7: Install Ingress Controller and Load Balancer](#9-phase-7-install-ingress-controller-and-load-balancer)
- [10. Phase 8: Auto-Scaling (HPA and Cluster Autoscaler)](#10-phase-8-auto-scaling-hpa-and-cluster-autoscaler)
- [11. Phase 9: Verify and Test](#11-phase-9-verify-and-test)
- [12. Teardown](#12-teardown)

---

## 1. Architecture

```
                   Internet
                       │
                       ▼
          ┌────────────────────────┐
          │   AWS Load Balancer     │  ◄── Created by Ingress
          │   (NLB or ALB)          │
          └───────────┬─────────────┘
                      │
                      ▼
          ┌────────────────────────┐
          │   Ingress Controller    │  (NGINX Ingress / AWS LB Controller)
          └───────────┬─────────────┘
                      │
                      ▼
          ┌────────────────────────┐
          │   Service (ClusterIP)   │
          └───────────┬─────────────┘
                      │
          ┌───────────┼───────────┐
          ▼           ▼           ▼
       ┌─────┐     ┌─────┐     ┌─────┐
       │ Pod │     │ Pod │     │ Pod │  ◄── Managed by Deployment + ReplicaSet
       │ WAF │     │ WAF │     │ WAF │     (Apache + ModSecurity + CRS)
       └──┬──┘     └──┬──┘     └──┬──┘
          │           │           │
          └───────────┼───────────┘
                      │
                      ▼
          ┌────────────────────────┐
          │   Client's Backend      │  ◄── Their EC2 / K8s / VPS
          │   (Public IP or Domain) │     (Not managed by us)
          └────────────────────────┘
```

**Each Pod contains:**
- Apache 2.4 (reverse proxy)
- ModSecurity v2 (WAF engine)
- OWASP CRS (rule set)

**Kubernetes resources we'll create:**
- `Deployment` — manages the WAF pods
- `ReplicaSet` — ensures 5 pods are always running (handled by Deployment)
- `Service` — internal network address for the pods
- `Ingress` + `IngressController` — routes external traffic to the Service
- `LoadBalancer` — AWS-managed, created automatically by the Ingress
- `ConfigMap` — stores Apache and ModSecurity configuration
- `Secret` — stores sensitive values (TLS certs, passwords)
- `HPA` (HorizontalPodAutoscaler) — scales pods based on CPU/memory
- `Cluster Autoscaler` — scales EC2 worker nodes based on demand
- `Liveness Probe` — restarts unhealthy pods
- `Readiness Probe` — holds traffic until pod is ready

---

## 2. Prerequisites

- An AWS account
- Billing enabled (EKS control plane costs ~$0.10/hour, NAT Gateway ~$0.045/hour)
- Basic Linux command-line knowledge
- A Docker Hub or ECR account to store your WAF image

---

## 3. Phase 1: Prepare the Bastion EC2

The bastion is a small EC2 instance you'll use to run all the `eksctl`, `kubectl`, and `aws` commands from.

### Step 1: Launch the bastion EC2

- **AMI:** Ubuntu 22.04 LTS
- **Instance type:** `t3.small` (2 vCPU, 2 GB RAM)
- **Storage:** 20 GB gp3
- **Security group:** Allow SSH (port 22) from your IP only
- **Key pair:** Create or reuse one

### Step 2: SSH into the bastion

```bash
ssh -i your-key.pem ubuntu@<bastion-public-ip>
```

### Step 3: Update the system

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl unzip git tmux jq
```

### Step 4: Switch to root (avoids permission issues)

```bash
sudo su -
cd /root
```

> ⚠️ **Important:** Never download or extract binaries in `/tmp` — it's a small RAM disk that fills up and corrupts installs. Always work from `/root`.

---

## 4. Phase 2: IAM User and AWS CLI Setup

### Step 1: Create an IAM user in AWS Console

1. Go to **IAM → Users → Create user**
2. Name: `eks-admin`
3. Attach these policies (for lab/learning — in production, use least privilege):
   - `AmazonEKSClusterPolicy`
   - `AmazonEKSWorkerNodePolicy`
   - `AmazonEC2FullAccess`
   - `IAMFullAccess`
   - `AWSCloudFormationFullAccess`
   - `AmazonVPCFullAccess`
4. Go to **Security credentials → Create access key → CLI**
5. Save the **Access Key ID** and **Secret Access Key**

### Step 2: Install AWS CLI v2 on the bastion

```bash
cd /root
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws/

aws --version
# Expected: aws-cli/2.x.x
```

### Step 3: Configure AWS CLI with your IAM credentials

```bash
aws configure
```

Enter:
- **AWS Access Key ID:** (from Step 1)
- **AWS Secret Access Key:** (from Step 1)
- **Default region:** `ap-south-1` (or your preferred region)
- **Default output format:** `json`

### Step 4: Verify

```bash
aws sts get-caller-identity
```

You should see your IAM user's ARN.

---

## 5. Phase 3: Install CLI Tools (eksctl, kubectl, helm)

### Step 1: Install eksctl

```bash
cd /root
ARCH=amd64
PLATFORM=$(uname -s)_$ARCH
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
tar -xzf eksctl_$PLATFORM.tar.gz -C /usr/local/bin
rm -f eksctl_$PLATFORM.tar.gz

eksctl version
```

### Step 2: Install kubectl

```bash
cd /root
KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl

kubectl version --client
```

### Step 3: Install Helm (for installing the Ingress Controller later)

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm -f get_helm.sh

helm version
```

---

## 6. Phase 4: Create the EKS Cluster

Behind the scenes, `eksctl` uses **CloudFormation** to build the VPC, subnets, IAM roles, control plane, and worker nodes.

### Step 1: Start a tmux session (so disconnects don't kill the build)

```bash
tmux new -s eks
```

### Step 2: Create the cluster

```bash
eksctl create cluster \
  --name waf-cluster \
  --region ap-south-1 \
  --nodegroup-name waf-workers \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 5 \
  --managed \
  --with-oidc
```

**Flag meaning:**
- `--with-oidc` — enables IAM roles for service accounts (needed for autoscaler)
- `--nodes-max 5` — allows the cluster autoscaler to add nodes later
- `--managed` — uses AWS-managed node groups

This takes **15–20 minutes**. Reattach with `tmux attach -t eks` if your SSH disconnects.

### Step 3: Verify

```bash
kubectl get nodes
```

Expected:

```
NAME                                           STATUS   ROLES    AGE   VERSION
ip-192-168-1-10.ap-south-1.compute.internal    Ready    <none>   5m    v1.34.x
ip-192-168-2-20.ap-south-1.compute.internal    Ready    <none>   5m    v1.34.x
```

---

## 7. Phase 5: Build the WAF Docker Image

### Step 1: Install Docker on the bastion

```bash
apt install -y docker.io
systemctl enable --now docker
docker --version
```

### Step 2: Create the WAF project folder

```bash
mkdir -p /root/waf-docker && cd /root/waf-docker
```

### Step 3: Create the Dockerfile

```bash
cat > Dockerfile <<'EOF'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y \
    apache2 \
    libapache2-mod-security2 \
    curl \
    wget \
    git \
    && rm -rf /var/lib/apt/lists/*

# Enable required Apache modules
RUN a2enmod security2 proxy proxy_http headers rewrite ssl

# Download OWASP CRS
RUN git clone --depth 1 -b v4.0/main https://github.com/coreruleset/coreruleset.git /etc/modsecurity/crs \
    && cp /etc/modsecurity/crs/crs-setup.conf.example /etc/modsecurity/crs/crs-setup.conf

# Copy our configs (we'll mount these as ConfigMaps in K8s)
COPY modsecurity.conf /etc/modsecurity/modsecurity.conf
COPY waf-vhost.conf /etc/apache2/sites-available/000-default.conf

EXPOSE 80

CMD ["apache2ctl", "-D", "FOREGROUND"]
EOF
```

### Step 4: Create the ModSecurity config

```bash
cat > modsecurity.conf <<'EOF'
SecRuleEngine DetectionOnly
SecRequestBodyAccess On
SecResponseBodyAccess Off
SecAuditEngine RelevantOnly
SecAuditLogFormat JSON
SecAuditLog /var/log/apache2/modsec_audit.log
SecAuditLogParts ABIJDEFHZ

Include /etc/modsecurity/crs/crs-setup.conf
Include /etc/modsecurity/crs/rules/*.conf
EOF
```

### Step 5: Create the Apache vhost (reverse proxy)

```bash
cat > waf-vhost.conf <<'EOF'
<VirtualHost *:80>
    ServerName waf.local

    # ModSecurity on
    SecRuleEngine On

    # Reverse proxy to client backend
    # Replace BACKEND_URL with the actual backend address
    ProxyPreserveHost On
    ProxyPass        / http://BACKEND_URL/
    ProxyPassReverse / http://BACKEND_URL/

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
```

### Step 6: Build and push the image

```bash
# Replace <your-dockerhub-username>
docker build -t <your-dockerhub-username>/waf-apache:v1 .

docker login
docker push <your-dockerhub-username>/waf-apache:v1
```

---

## 8. Phase 6: Deploy to Kubernetes

Now we create the Kubernetes resources. Each one goes in its own YAML file for clarity.

### Step 1: Create a namespace

```bash
kubectl create namespace waf
```

### Step 2: ConfigMap (Apache + ModSecurity config)

```yaml
# configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: waf-config
  namespace: waf
data:
  BACKEND_URL: "client-backend.example.com"
  PARANOIA_LEVEL: "1"
  ANOMALY_THRESHOLD: "5"
```

```bash
kubectl apply -f configmap.yaml
```

### Step 3: Secret (for TLS certs, API keys, etc.)

```yaml
# secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: waf-secrets
  namespace: waf
type: Opaque
stringData:
  BACKEND_API_KEY: "replace-with-real-key"
```

```bash
kubectl apply -f secret.yaml
```

### Step 4: Deployment (manages pods + ReplicaSet)

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: waf-deployment
  namespace: waf
  labels:
    app: waf
spec:
  replicas: 5                 # ReplicaSet keeps 5 pods running
  selector:
    matchLabels:
      app: waf
  template:
    metadata:
      labels:
        app: waf
    spec:
      containers:
        - name: waf-apache
          image: <your-dockerhub-username>/waf-apache:v1
          ports:
            - containerPort: 80
          envFrom:
            - configMapRef:
                name: waf-config
            - secretRef:
                name: waf-secrets
          resources:
            requests:
              cpu: "200m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"

          # Liveness Probe — restarts pod if Apache dies
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 15
            periodSeconds: 20
            failureThreshold: 3

          # Readiness Probe — holds traffic until Apache is ready
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
```

```bash
kubectl apply -f deployment.yaml
kubectl get pods -n waf
```

You should see 5 `waf-deployment-xxxx` pods, all `Running`.

### Step 5: Service (internal network address for the pods)

```yaml
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: waf-service
  namespace: waf
spec:
  type: ClusterIP
  selector:
    app: waf
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
```

```bash
kubectl apply -f service.yaml
kubectl get svc -n waf
```

---

## 9. Phase 7: Install Ingress Controller and Load Balancer

The **Ingress** is the rule ("route traffic for `waf.example.com` to the WAF service"). The **Ingress Controller** is the engine that reads the rule and actually does the routing. On EKS, the controller provisions an AWS Load Balancer automatically.

### Step 1: Install NGINX Ingress Controller via Helm

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb"
```

This creates an **AWS Network Load Balancer (NLB)** automatically.

### Step 2: Create the Ingress resource

```yaml
# ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: waf-ingress
  namespace: waf
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: waf.example.com         # Replace with your domain
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: waf-service
                port:
                  number: 80
```

```bash
kubectl apply -f ingress.yaml
```

### Step 3: Get the Load Balancer address

```bash
kubectl get svc -n ingress-nginx
```

Copy the `EXTERNAL-IP` (it's a long AWS NLB hostname). Point your domain's DNS A/CNAME record to this address.

---

## 10. Phase 8: Auto-Scaling (HPA and Cluster Autoscaler)

### Step 1: Install Metrics Server (required by HPA)

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Wait a minute, then check:

```bash
kubectl top nodes
kubectl top pods -n waf
```

### Step 2: Create HPA (Horizontal Pod Autoscaler)

```yaml
# hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: waf-hpa
  namespace: waf
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: waf-deployment
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
```

```bash
kubectl apply -f hpa.yaml
kubectl get hpa -n waf
```

The HPA scales pods between 2 and 10 based on CPU/memory load.

### Step 3: Install Cluster Autoscaler (scales EC2 nodes)

```bash
# Allow eksctl to create an IAM policy for autoscaler
eksctl create iamserviceaccount \
  --cluster=waf-cluster \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --attach-policy-arn=arn:aws:iam::aws:policy/AutoScalingFullAccess \
  --override-existing-serviceaccounts \
  --approve \
  --region ap-south-1

# Install the autoscaler
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/master/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml

# Edit the deployment to add cluster name
kubectl -n kube-system edit deployment cluster-autoscaler
# Add this flag under command:
#   - --node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled,k8s.io/cluster-autoscaler/waf-cluster
```

Now if all nodes are full and HPA needs more pods, the cluster autoscaler automatically adds more EC2 worker nodes (up to the `--nodes-max 5` set earlier).

---

## 11. Phase 9: Verify and Test

### Step 1: Check everything is running

```bash
kubectl get all -n waf
```

You should see:
- 5+ Pods (`Running`)
- 1 Deployment
- 1 ReplicaSet
- 1 Service
- 1 HPA

### Step 2: Test a normal request (should pass)

```bash
curl -i http://waf.example.com/
```

Expected: `200 OK` with your backend's response.

### Step 3: Test an attack (should be blocked)

```bash
curl -i "http://waf.example.com/?id=1' OR 1=1--"
```

Expected: `403 Forbidden`

### Step 4: Check WAF logs

```bash
# Pick any pod
POD=$(kubectl get pods -n waf -o jsonpath='{.items[0].metadata.name}')

# View audit log
kubectl exec -n waf $POD -- cat /var/log/apache2/modsec_audit.log | jq .

# View error log
kubectl exec -n waf $POD -- tail -f /var/log/apache2/error.log
```

### Step 5: Test auto-scaling

Generate load and watch pods scale:

```bash
# In one terminal
kubectl run -it --rm load-generator --image=busybox -- /bin/sh
# Inside the pod:
while true; do wget -q -O- http://waf-service.waf.svc.cluster.local/; done

# In another terminal, watch pods multiply
kubectl get hpa -n waf -w
kubectl get pods -n waf -w
```

---

## 12. Teardown

> ⚠️ Always clean up at the end of each practice session — EKS and NAT Gateway cost money while they exist.

```bash
# 1. Delete the Ingress (removes the AWS Load Balancer)
kubectl delete ingress waf-ingress -n waf

# 2. Uninstall the Ingress Controller
helm uninstall ingress-nginx -n ingress-nginx

# 3. Delete the namespace (removes all WAF resources)
kubectl delete namespace waf

# 4. Delete the entire cluster
eksctl delete cluster --name waf-cluster --region ap-south-1
```

Verify nothing remains:

```bash
aws cloudformation list-stacks \
  --region ap-south-1 \
  --stack-status-filter CREATE_COMPLETE \
  --query "StackSummaries[?starts_with(StackName, 'eksctl-')].StackName" \
  --output table
```

An empty result means you're clean.

---

## Quick Reference

| Task | Command |
|---|---|
| Create cluster | `eksctl create cluster --name waf-cluster ...` |
| Apply all YAMLs | `kubectl apply -f .` |
| Check pods | `kubectl get pods -n waf` |
| View logs | `kubectl logs -n waf <pod-name>` |
| Shell into pod | `kubectl exec -it -n waf <pod-name> -- bash` |
| Scale manually | `kubectl scale deployment waf-deployment -n waf --replicas=10` |
| Watch HPA | `kubectl get hpa -n waf -w` |
| Delete cluster | `eksctl delete cluster --name waf-cluster --region ap-south-1` |

---

## Component Summary

| Component | Purpose |
|---|---|
| **EC2 Bastion** | Runs AWS CLI, eksctl, kubectl commands |
| **IAM User** | Authenticates CLI to AWS |
| **CloudFormation** | Builds VPC, subnets, IAM, and EKS control plane (via eksctl) |
| **EKS Cluster** | Managed Kubernetes control plane |
| **Pod** | Smallest unit — contains the Apache + ModSecurity container |
| **Deployment** | Declares what to run and how many replicas |
| **ReplicaSet** | Keeps the declared number of pods running (managed by Deployment) |
| **Service** | Internal DNS/IP for the pods |
| **Ingress + Controller** | Routes external HTTP traffic to the Service |
| **AWS Load Balancer** | Public entry point (created by Ingress Controller) |
| **ConfigMap** | Non-sensitive config (backend URL, rule paths) |
| **Secret** | Sensitive config (TLS certs, API keys) |
| **HPA** | Scales pods based on CPU/memory |
| **Cluster Autoscaler** | Scales EC2 worker nodes based on pod demand |
| **Liveness Probe** | Restarts pod if Apache crashes |
| **Readiness Probe** | Holds traffic until pod is healthy |

---

## Author

**Masba Uddin Rumi**
Senior System Administrator | Infrastructure & Security Engineer
[GitHub](https://github.com/MasbaIUBAT) · [LinkedIn](https://linkedin.com/in/masba-uddin-rumi)
