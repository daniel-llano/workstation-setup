# Workstation Setup testing

## Automated

```powershell
.\scripts\test.ps1
```

```bash
chmod +x scripts/test.sh
./scripts/test.sh
```

- Windows: parses `dev-setup.ps1`, runs `-List`, checks docker-before-vscode_ext order, dry-runs `-Only vscode_ext -Skip docker,java_scala`, checks `dev-setup.cmd -List`
- Ubuntu: `bash -n dev-setup.sh`, `--list`, order check, `--help` profiles, dry-run `--only=vscode_ext --skip=docker,java_scala`

Dry-run a tiny slice without installing:

```bash
./dev-setup.sh -n --profile=minimal
```

```powershell
.\dev-setup.ps1 -DryRun -Profile minimal
```

Do not commit `.env`.

CI: `.github/workflows/test.yml` runs `./scripts/test.sh` (`bash -n` + `--list`).

