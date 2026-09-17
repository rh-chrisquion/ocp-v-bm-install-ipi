# OpenShift Virtualization

The kustomization installs OpenShift Virtualization and creates its
`HyperConverged` resource.

`disable-nested-virtualization.example.yaml` is intentionally excluded from
the kustomization. It demonstrates a MachineConfig that disables nested KVM on
master and worker nodes. This is useful when guest workloads do not require a
hypervisor inside the VM and the platform wants to reduce that exposed host
capability. Review the role selectors and rollout impact before enabling it;
MachineConfig changes drain and reboot matching nodes.
