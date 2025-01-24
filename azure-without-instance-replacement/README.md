# Microsoft Azure without instance replacement

This small setup can be used to provision Flatcar nodes on [Azure](https://azure.microsoft.com/) with the instance user data (Ignition config) used for reconfiguration. The advantage is to be able to keep persistent data, keep the same IP address, and to reduce the time of re-applying a configuration change.

This setup uses the `flatcar-reset` tool to clean the rootfs while preserving allowed paths.

Create a `terraform.tfvars` file that lists your preferences. Like this one:

ssh-keygen -t rsa -b 4096 -C "erwinkramer@guanchen.nl" -f $HOME/.ssh/id_rsa

```
cluster_name            = "mycluster"
machines                = ["mynode"]
ssh_keys                = ["ssh-rsa AA... me@mail.net"]
flatcar_stable_version   = "x.y.z"
```

You can resolve the latest Flatcar stable version with this shell command:

```
(source <(curl -sSfL https://stable.release.flatcar-linux.net/amd64-usr/current/version.txt); echo "${FLATCAR_VERSION_ID}")
```

The machine name listed in the `machines` variable is used to retrieve the corresponding [Container Linux Config](https://kinvolk.io/docs/flatcar-container-linux/latest/container-linux-config-transpiler/configuration/). For each machine in the list, you should have a `machine-NAME.yaml.tmpl` file with a corresponding name. An example file `machine-mynode.yaml.tmpl` for `mynode` is already provided.

First find your subscription ID, then, if wanted, create a service account for tofu and note the tenant ID, client (app) ID, client (password) secret:

```
az login
az account set --subscription <azure_subscription_id>
# You can skip the creation of the service account if you rely on az login
az ad sp create-for-rbac --name <service_principal_name> --role Contributor
{
  "appId": "...",
  "displayName": "<service_principal_name>",
  "password": "...",
  "tenant": "..."
}
```
Make sure you have AZ CLI version 2.32.0 if you get the error `Values of identifierUris property must use a verified domain of the organization or its subdomain`.
AZ CLI installation docs are [here](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-linux?pivots=apt#option-2-step-by-step-installation-instructions).

Before you run tofu, accept the image terms:

```
az vm image terms accept --urn kinvolk:flatcar-container-linux:stable:4081.2.1
```

Now run tofu as follows:

```
export ARM_SUBSCRIPTION_ID="beb880cc-af9a-4e4d-8e8e-54739967674f"
export ARM_TENANT_ID="b81eb003-1c5c-45fd-848f-90d9d3f8d016"  # skip if you used az login
tofu init
tofu apply --auto-approve
```

When tofu is done running, it will print the IP addresses of the machines created. Log in via `ssh core@IPADDRESS` (maybe add `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o NumberOfPasswordPrompts=0`).

```sh
ssh -i ~/.ssh/id_rsa core@52.170.63.201
```

When you make a change to `machine-mynode.yaml.tmpl` (e.g., `my-setting v1` to `my-setting v2` and run `tofu apply` again, the instance is just rebooted instead of recreated and the new Ignition config applied while keeping wanted data (see `KEEPPATHS` setting) and discarding the rest.

We can run this command to compare the values of `/etc/config-side-effect` and `/mydata/data` before and after the run. We should see that `/etc/config-side-effect` changes while `/mydata/data` stays the same.

```
az vm run-command invoke -g mycluster-rg -n mycluster-mynode --command-id RunShellScript --scripts "head /etc/config-side-effect /mydata/data" | jq -r '.value[0].message'
# or
ssh core@20.232.140.103 head /etc/config-side-effect /mydata/data
```

## Demo

You can watch a recording of the `vhs-demo.tape` [here](https://www.youtube.com/watch?v=1_QcY1ic7mA).
