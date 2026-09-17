# Host network examples

These NNCPs are examples and are not referenced by a kustomization. Replace
the placeholder host, interface, VLAN, address, and MTU values from verified
switch and server data before applying them.

Apply one node at a time and keep out-of-band access available. Confirm the
bond members share the same switch-side LACP bundle and VLAN permissions.
After each policy, require its corresponding `NodeNetworkConfigurationEnactment`
to report `Available` before continuing.
