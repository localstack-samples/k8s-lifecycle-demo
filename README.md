# Kubernetes Deployment Lifecycle — EKS on LocalStack

A self-contained demo that makes all **7 steps** of the Kubernetes Deployment Lifecycle **visible in real time**, using a locally emulated EKS cluster powered by [LocalStack](https://localstack.cloud).

```
kubectl apply
     │
     ▼
┌─────────────┐   ┌──────────────────┐   ┌───────────┐   ┌─────────┐
│  API Server │──▶│ Controller Mgr   │──▶│ Scheduler │──▶│ Kubelet │
│  (etcd)     │   │ Deployment+RS    │   │ Node pick │   │ + CRI   │
└─────────────┘   └──────────────────┘   └───────────┘   └─────────┘
                                                               │
                                                               ▼
                                                    ┌──────────────────┐
                                                    │ Pending→Running  │
                                                    │ Readiness probe  │
                                                    │ → Ready+Endpoint │
                                                    └──────────────────┘
```

---

## What's in this repo

```
k8s-lifecycle-demo/
├── app/
│   ├── app.py            # Flask counter service (GET /, GET /health)
│   ├── requirements.txt
│   └── Dockerfile
├── k8s/
│   └── deployment.yaml   # Namespace + Deployment (2 replicas) + NodePort Service
├── docker-compose.yml    # LocalStack Pro container
├── setup.sh              # One-time cluster setup (run before the talk)
├── demo.sh               # 7-step live demo script
└── README.md
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Docker Desktop | ≥ 4.x | https://docs.docker.com/get-docker/ |
| kubectl | ≥ 1.28 | https://kubernetes.io/docs/tasks/tools/ |
| AWS CLI v2 | ≥ 2.x | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| awslocal | latest | `pip install awscli-local` |
| LocalStack CLI | latest | `pip install localstack` |
| k3d | ≥ 5.x | https://k3d.io/#installation |
| Python 3.11+ | (for the app build) | https://python.org |

> **LocalStack Pro is required** for EKS emulation.
> Get a free trial auth token at https://localstack.cloud.

---

## Quick start

### 1. Set your LocalStack auth token

```bash
export LOCALSTACK_AUTH_TOKEN=<your-token>
```

Add it to your shell profile so it persists across sessions.

### 2. Run setup (do this before the talk)

```bash
chmod +x setup.sh demo.sh
./setup.sh
```

`setup.sh` will:
1. Start LocalStack via Docker Compose
2. Create an EKS cluster called `lifecycle-demo`
3. Configure `kubectl` to point at it
4. Build the `counter-app:latest` Docker image
5. Load the image into the cluster nodes (via k3d)

### 3. Run the demo

```bash
./demo.sh
```

Press **ENTER** to advance between each step.

For a fully-automatic run (e.g. recording):

```bash
AUTO=1 STEP_DELAY=6 ./demo.sh
```

---

## The 7 steps

| # | Component | What you'll see |
|---|-----------|-----------------|
| 1 | **API Server** | `kubectl apply` → HTTP 201, object stored in etcd |
| 2 | **Controller Manager** | Deployment + ReplicaSet reconciliation, Pod objects appear |
| 3 | **Scheduler** | Pods assigned to nodes; `kubectl describe pod | grep Node:` |
| 4 | **Kubelet** | Image pull events, container start events |
| 5 | **Pod phase** | `kubectl get pods -w` → `Pending → Running` |
| 6 | **Readiness probe** | `Running → Ready`; Service Endpoints populated |
| 7 | **Self-healing** | Pod deleted → replacement races through lifecycle again |

---

## The app

The counter service exposes two endpoints:

```
GET /       → {"hits": 42, "pod": "counter-app-xxx", "node": "k3d-..."}
GET /health → {"status": "ok", "pod": "counter-app-xxx"}
```

Because each replica keeps its own in-memory counter, repeated `curl` calls to the
NodePort will hit different pods — making **pod identity** and **load balancing**
visible to the audience.

```bash
# NodePort is 30080 on each node
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl http://${NODE_IP}:30080/
```

---

## Customisation

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLUSTER_NAME` | `lifecycle-demo` | EKS / k3d cluster name |
| `AWS_DEFAULT_REGION` | `us-east-1` | LocalStack region |
| `AUTO` | `0` | `1` = skip ENTER prompts |
| `STEP_DELAY` | `4` | Seconds to pause in AUTO mode |

Pass them as environment variables:

```bash
CLUSTER_NAME=my-cluster AUTO=1 ./demo.sh
```

---

## Cleanup

```bash
# Remove demo namespace
kubectl delete namespace demo

# Tear down the whole cluster
awslocal eks delete-cluster --name lifecycle-demo

# Stop LocalStack
docker compose down -v
```

---

## Troubleshooting

**Pods stay in `Pending`**
The image wasn't loaded into the cluster nodes. Re-run `./setup.sh` or manually:
```bash
k3d image import counter-app:latest --cluster lifecycle-demo
```

**`imagePullBackOff`**
Same cause. The manifest uses `imagePullPolicy: Never` — the image must be
pre-loaded; it will never be pulled from a registry.

**`kubectl` shows the wrong cluster**
```bash
kubectl config use-context lifecycle-demo
```

**LocalStack EKS not available**
EKS is a Pro feature. Confirm your `LOCALSTACK_AUTH_TOKEN` is set and that the
container started cleanly:
```bash
docker logs localstack | grep -i eks
```

**k3d not found**
`setup.sh` falls back to `docker exec + ctr images import`. Install k3d for a
smoother experience: https://k3d.io/#installation
