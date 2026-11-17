# Oracle Free Instance Script

Oracle Cloud's Always Free servers are often unavailable ("Out of host capacity"),
especially the ARM machines. This script keeps asking Oracle for one at a sensible
pace and stops as soon as a server is created.

Each round it tries, in order:

1. **VM.Standard.A1.Flex** (ARM), 2 OCPU / 12 GB RAM
2. **VM.Standard.E2.1.Micro** (AMD), 1 OCPU / 1 GB RAM

The first one that succeeds wins. Change the order or sizes in the `ATTEMPTS` list in `retry.sh`.

## How it paces itself

| Oracle's answer | What the script does |
|---|---|
| Out of capacity | Waits 3–4 minutes (with randomness), then tries again |
| Too many requests (429) | Waits 10 min, then 20, 30… up to 1 hour |
| Network error / timeout | Waits 1 minute, never gives up |
| Free limit already used | Stops, because more requests cannot succeed |
| Anything else | Retries twice, then stops and logs Oracle's message |

When a server is created, its details go to `instance-<name>.json`, a desktop
notification is sent (`notify-send`), and the script exits. If it runs again
later, it sees that file and does nothing.

## Always Free limits (per account)

- 2× VM.Standard.E2.1.Micro
- A1.Flex: 4 OCPU and 24 GB RAM **in total** across all ARM servers

## Setup

1. Install and configure the [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm)
   (`oci setup config`), and make sure `oci iam region list` works.
2. Have a VCN with a public subnet (the console's "Create VM" wizard makes one), and an SSH key.
3. Copy the config and fill in your own values:

   ```bash
   cp config.example.env config.env
   $EDITOR config.env
   ```

   `config.env` is git-ignored. Never commit it.

## Usage

Run it directly, giving the server a name (letters, digits, `-`, `_`):

```bash
./retry.sh myproject
tail -f retry-myproject.log
```

Or run it as a systemd user service so it keeps going in the background and starts again after a reboot:

```bash
# Edit ExecStart in the unit if this folder is not ~/finplan-oracle-retry
cp oracle-retry@.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now oracle-retry@myproject

systemctl --user stop oracle-retry@myproject      # stop
systemctl --user disable oracle-retry@myproject   # stop starting at login
```

Each project name gets its own log (`retry-<name>.log`) and result file
(`instance-<name>.json`), so you can run it again for a second server.

## Files

| File | Purpose |
|---|---|
| `retry.sh` | The retry loop |
| `config.example.env` | Template for your account settings |
| `oracle-retry@.service` | systemd user service, one copy per project name |
| `config.env`, `*.log`, `instance-*.json` | Local only, git-ignored |
