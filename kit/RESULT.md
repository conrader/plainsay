# Plainsay mini-m4 setup review
VERDICT: PASS for offline review. Keep the nightly paused until the rollout checks in KIT.md pass.
P0: No findings.
P1: Verify both site publishers use the shared rsync receiver before enabling the nightly. Archive mode can mask shared write access.
P2: Confirm PAT repository selection, Contents/Actions grants and ref rules in GitHub. The two API push flags report account access.
P2: Check OVH's observed Tailscale source and the Mac's Keychain and copied LaunchAgent during rollout. No production services were exercised.
Tests: 12/12 kit sandbox tests and 21/21 existing release sandbox tests. Bash syntax and ShellCheck passed for 8/8 kit scripts.
Entry points: kit/KIT.md, kit/{ovh,mini}-{provision,reverse}.sh, kit/test-kit.sh.
Runtime paths: ~/.ssh/plainsay_deploy (0600), ~/.ssh/plainsay_deploy_known_hosts, ~/.ssh/plainsay-release-gh/, /var/backups/plainsay-deploy/.
Base: e0e0c857220d578df131a700341a29880a87bf6d.
Kit: 6907988e2ee8d0cf114c6cc69ed74af99f9fb00c on ops/mini-m4-release-setup.
Commit location: /tmp/plainsay-kit-ops-20261119, because the source checkout's .git mount is read-only.
