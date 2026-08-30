---
name: Bug report
about: Something in this lab did not work
labels: bug
---

**What did you run?**

```bash
# the exact command
```

**What happened?**

**What did you expect?**

**Environment**

- Kubernetes distribution and version: <!-- kind / minikube / EKS / GKE ... -->
- `kubectl version --short`:
- Operator version:
- Host OS and available Docker CPU/memory:

**Operator log**

The most useful single thing for almost any cluster problem:

```
kubectl -n pg-operator logs deploy/pg-operator --tail=200 | grep -i error
```

**Have you checked [docs/11-troubleshooting.md](../../docs/11-troubleshooting.md)?**
