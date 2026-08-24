# Synapse deployment configuration

Per-environment configuration for `azure.synapse.tools`, in the same shape as
[`src/adf/deployment`](../../adf/deployment/README.md).

## Why `config-<env>.csv` is only a header

These files are empty on purpose. They are not stubs waiting to be filled in.

`scripts/New-DeploymentConfig.ps1` produces the file the deployment actually
consumes, `config-<env>.generated.csv`, by merging two sources:

| Source | Contains | Example |
|---|---|---|
| `config-<env>.csv` (this directory) | **Decisions** — things a human chose | a trigger's `runtimeState`, a tuned batch size |
| Terraform outputs | **Endpoints** — things the infrastructure decided | the lake DFS URL, the Key Vault URI |

The generator emits the endpoint rows itself:

```powershell
$synapseRows = @(
    @{ type='linkedService'; name='LS_ADLS_Lake'; path='typeProperties.url';     value=$tf.lakeDfsEndpoint }
    @{ type='linkedService'; name='LS_KeyVault';  path='typeProperties.baseUrl'; value=$tf.keyVaultUri }
)
```

So `LS_ADLS_Lake` and `LS_KeyVault` do **not** belong here. There is currently
nothing else to configure, which is why the files contain a header and nothing
else. Add a row when you have a genuine per-environment decision to record.

## Do not put endpoints here

These files used to carry placeholder rows like:

```
linkedService,LS_ADLS_Lake,typeProperties.url,https://REPLACED-BY-GENERATED-CONFIG.dfs.core.windows.net
```

They were harmless — the generated file overrode them on every deployment — but
they were a trap, for two reasons:

1. **They look authoritative.** Someone editing a committed CSV reasonably
   assumes it is what gets deployed. It is not; the generated file wins.
2. **A real hostname is worse than a placeholder.** Replace that placeholder
   with an actual endpoint and it stays correct right up until the workspace is
   rebuilt with a new name suffix — at which point it points at a resource that
   no longer exists, and nothing tells you, because the generated row silently
   overrides it anyway.

`New-DeploymentConfig.ps1 -Verify` fails the build if a committed row disagrees
with what Terraform reports, which is what caught these. It prints the
repo-relative path of the offending file — note that a `config-dev.csv` exists
in this directory *and* in `src/adf/deployment`.

## Adding a real decision row

```
type,name,path,value
trigger,TR_Nightly_Curate,runtimeState,Started
```

`path` is relative to the artifact's **`properties`** node, not the document
root — `typeProperties.url`, never `properties.typeProperties.url`. The wrong
form is silently ignored by default; this repo sets
`FailsWhenPathNotFound = $true` so it fails loudly instead.
