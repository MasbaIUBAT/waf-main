**Terraform - Infrastructure Provisioning**

**Overview**

Terraform was used as an Infrastructure as Code (IaC) tool to provision and manage the complete AWS infrastructure required for a secure, multi-tier Web Application Firewall (WAF) architecture.

The goal of this phase was to establish a secure, scalable, and logically segmented cloud environment before introducing configuration management and container orchestration.

Terraform enabled:

- Automated infrastructure provisioning
- Reproducible environments
- Version-controlled infrastructure
- Modular and maintainable cloud architecture
- Clear separation between network, compute, and security layers

**Architectural Design (Pre-EKS)**

The infrastructure was designed following security best practices, including:

- Network segmentation (Public / Private subnets)
- Principle of least privilege
- Controlled administrative access
- Defense-in-depth strategy

**AWS Infrastructure Components**

**1\. Virtual Private Cloud (VPC)**

A dedicated VPC was provisioned to isolate the environment from other workloads.  
The VPC served as the foundational network boundary for all deployed components.

Key design principles:

- Logical isolation
- Custom CIDR allocation
- Subnet segmentation for security control

**2\. Subnet Architecture**

The infrastructure was divided into:

**Public Subnets**

Used for internet-facing components:

- Bastion Host
- Nginx Reverse Proxy
- Apache + ModSecurity (WAF)

Public subnets were associated with:

- Internet Gateway (IGW)
- Public route table

**Private Subnets**

Used for internal services:

- Frontend Application Server
- Backend API Server
- Machine Learning + MongoDB Server

Private subnets were associated with:

- NAT Gateway (for outbound internet access only)
- Restricted route tables

This separation ensured backend services were not directly exposed to the internet.

**Six EC2 Instance Architecture**

Terraform provisioned six EC2 instances, each serving a dedicated role in the security pipeline.

**1\. Bastion Host (Public Subnet)**

- Controlled administrative access
- SSH entry point to private resources
- Restricted inbound security group rules

**2\. Nginx Reverse Proxy (Public Subnet)**

- First point of contact for external traffic
- SSL/TLS termination
- Reverse proxy forwarding to WAF layer
- Access logging

**3\. Apache + ModSecurity (WAF) (Public Subnet)**

- Web Application Firewall enforcement
- OWASP Core Rule Set (CRS) integration
- HTTP inspection and threat filtering
- Audit logging and IP blocking capabilities

**4\. Frontend Server (Private Subnet)**

- Application UI layer
- Accessible only via WAF/proxy layer

**5\. Backend API Server (Private Subnet)**

- Core business logic
- Internal-only communication
- No direct public exposure

**6\. Machine Learning + MongoDB Server (Private Subnet)**

- Centralized logging storage (MongoDB)
- ML-based log analysis and anomaly detection
- Fully isolated from public internet

**Traffic Flow (Pre-Container Architecture)**

The infrastructure was designed with layered security controls:

Internet  
→ Nginx (TLS Termination & Reverse Proxy)  
→ Apache + ModSecurity (WAF Filtering)  
→ Backend Services (Private Subnet)

This layered model ensured:

- SSL offloading at entry
- Application-layer filtering before reaching backend
- Internal service protection
- Detailed security logging

**Networking Components**

Terraform provisioned:

- Internet Gateway (IGW) for public access
- NAT Gateway for private outbound communication
- Route tables for controlled traffic flow
- Security Groups with least-privilege rules

Security groups were tightly scoped:

- SSH allowed only to Bastion
- HTTP/HTTPS exposed only to proxy/WAF
- Backend ports restricted to internal CIDR ranges

**Security Design Principles**

The Terraform architecture followed:

**Defense-in-Depth**

Multiple layers of inspection and access control.

**Network Segmentation**

Public-facing services separated from internal workloads.

**Controlled Administrative Access**

Bastion-based access model instead of direct SSH exposure.

**Logging & Observability Ready**

Infrastructure prepared for centralized log shipping to MongoDB and ML processing.

**Immutable Infrastructure Philosophy**

Infrastructure defined declaratively and version-controlled
