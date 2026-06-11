# Security Policy

## This is a lab, not a production system

The Hyper-V Sandbox is intentionally insecure for ease of learning:

- The configuration file (`SDNSandbox/SDNSandbox-Config.psd1`) stores **product keys and a default password (`Password01`) in plaintext**, and that file is copied onto lab VMs during deployment.
- The lab is **not** hardened, highly available, or fault tolerant.

**Never deploy it on production networks or with real credentials/keys.**

## Reporting a vulnerability

If you find a security issue in the *scripts themselves* (e.g., something that could harm the host or leak data beyond the documented lab behavior), please report it privately:

1. Preferred: open a **GitHub Security Advisory** ("Report a vulnerability") on this repository.
2. Alternatively, open a regular issue **without** sensitive details and ask a maintainer for a private channel.

Please do not open public issues containing exploit details. We aim to acknowledge reports within a few days.
